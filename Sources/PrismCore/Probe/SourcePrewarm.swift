import Foundation

/// What a prewarm did, for the host's log line.
///
/// A prewarm is advice to the engine, never a precondition: every status
/// other than `.stored` means the next play opens exactly as it would have
/// without one, and nothing here is an error a host has to handle.
public struct SourcePrewarmOutcome: Sendable, Equatable {

    public enum Status: Sendable, Equatable {
        /// Bytes are in memory and the next coordinated read of this URL and
        /// headers will offer them to the origin's validator.
        case stored
        /// Not an `http`/`https` URL. File and host-supplied inputs have no
        /// round trips to save.
        case notApplicable
        /// The origin reported no strong `ETag`, so nothing could bind the
        /// bytes to a representation. Refused by rule: stale bytes handed to a
        /// demuxer are a wrong parse, not a slow one. A `Last-Modified` date
        /// alone lands here too — at one-second resolution it cannot tell two
        /// versions written within the same second apart.
        case validatorUnavailable
        /// The origin refused someone within the last minute, or never had a
        /// free slot while this prewarm was willing to wait. Optional work
        /// does not queue behind playback, nor add to a throttled origin.
        case originBusy
        /// The origin answered 429 / 503 / 509. Recorded with the shared
        /// coordinator (so playback backs off too) and not retried.
        case originRefused(status: Int)
        /// No usable 206: a server that ignores Range, a redirect, a 4xx, a
        /// dropped transfer. `status` is `nil` when nothing arrived.
        case unusableResponse(status: Int?)
        /// The validator or length changed between two of this prewarm's own
        /// requests. Nothing was stored.
        case changedDuringPrewarm
        /// What was fetched is larger than the whole store. Nothing was
        /// stored; with the budget clamp this means a store configured
        /// smaller than one source.
        case exceedsCapacity
        case cancelled
    }

    public let status: Status
    /// Bytes held for this source after the prewarm; `0` unless `.stored`.
    public let storedBytes: Int
    /// Requests the prewarm sent to the origin — the number that costs time
    /// against a host proxy that fetches each forwarded window whole. A
    /// request the origin coordinator declined to admit was never sent and
    /// is not counted, so `.originBusy` from a first request reports `0`.
    public let requests: Int
    /// The strong `ETag` the origin reported, when it reported one.
    public let validator: String?
    /// Where the container's header ends, when the prewarmed head reached it.
    public let headerBytes: Int?
    /// Whether the container's tail index (Matroska Cues, a trailing `moov`)
    /// is among the stored bytes — seen there, not inferred: the Cues
    /// element ID at the SeekHead's offset, or a `moov` box header in the
    /// boxes after `mdat`.
    public let indexPrewarmed: Bool
    public let duration: Duration
}

/// What became of a prewarm when a reader opened the source, reported on
/// `ProbedSource.prewarm`.
public enum SourcePrewarmUse: Sendable, Equatable {
    /// Nothing was prewarmed for this URL and these headers, or the transport
    /// is not the coordinated HTTP reader (the only one that consults it).
    case none
    /// The origin confirmed the representation and the reader took `bytes`
    /// of prewarmed blocks into its cache instead of fetching them.
    case adopted(bytes: Int)
    /// The origin now reports a different validator or length than when the
    /// prewarm ran. The entry was discarded and the source read fresh.
    case stale
    /// The confirming request did not get an answer (refused, failed,
    /// redirected). The entry was left for a later reader; this one read the
    /// network.
    case unverified
}

extension PrismCoreEngine {

    /// The default per-source prewarm budget, and its ceiling: half the
    /// coordinated reader's 4 MB retention, so the reader can take over
    /// everything that was fetched and still have room for its own fills.
    public static let defaultPrewarmByteBudget = SourcePrewarmFetcher.maximumBudget

    /// Fetch the bytes a play of `url` will read first — the container header
    /// and, for a Matroska, the Cues at its tail with the last cluster before
    /// them — so a later open over the
    /// coordinated HTTP reader (`coordinatedHTTP: true`) starts from memory.
    ///
    /// For a host that knows what is likely next: the following episode, the
    /// item under the cursor, a detail page. Safe to call speculatively and to
    /// ignore: the result is advisory, and a prewarm nobody plays is dropped
    /// by the store's budget or the first memory warning.
    ///
    /// **What makes it safe to use.** Before the first prewarmed byte is
    /// delivered, the reader asks the origin once more (a one-byte range) and
    /// takes the blocks only if the strong `ETag` and the length are what
    /// they were. An origin that reports no strong `ETag` — including one
    /// that reports only `Last-Modified` — cannot be prewarmed at all; see
    /// `SourcePrewarmOutcome.Status.validatorUnavailable`.
    ///
    /// **What it costs the origin.** Every request goes through the same
    /// per-origin admission as playback, at lower priority: never while
    /// another request to the origin is in flight, and not at all within a
    /// minute of a refusal. A 429 / 503 is recorded, not retried.
    ///
    /// - Parameters:
    ///   - httpHeaders: the headers the play will send. Part of the identity:
    ///     a prewarm under one token is not offered to a play under another.
    ///   - byteBudget: the most this prewarm may hold. Clamped to
    ///     `defaultPrewarmByteBudget`, which is all a reader can retain.
    @discardableResult
    public static func prewarm(
        url: URL,
        httpHeaders: [String: String] = [:],
        byteBudget: Int = defaultPrewarmByteBudget
    ) async -> SourcePrewarmOutcome {
        await SourcePrewarmFetcher.prewarm(
            url: url, headers: httpHeaders, byteBudget: byteBudget, store: .shared
        )
    }

    /// Drop every prewarmed source — for a host that knows the user left the
    /// screen the prewarms were for, or that wants the memory back first.
    public static func discardPrewarmedSources() {
        SourcePrewarmStore.shared.removeAll()
    }
}

/// The fetch half of the prewarm: at most two bounded range requests, the
/// two regions a cold start reads before its first segment.
///
/// 1. The head, one reader block. Enough for the scanner to find the SeekHead
///    (and with it the Cues offset) on any Matroska, and for stream analysis
///    on the files measured so far.
/// 2. The tail around the index — see below.
///
/// Few requests rather than few bytes, because against the host proxy the
/// number that costs is requests × bite (see AGENTS.md *Measuring*).
///
/// A head extension with any leftover budget was tried and dropped: on the
/// measured file stream analysis never read past the first megabyte, so the
/// extension was a 4 s bite of prewarm that bought nothing — and it filled
/// the reader's whole retention, so the producer's first fill evicted the
/// header and fetched it again (warm `start()` 2.1 s against 0.8 s cold).
enum SourcePrewarmFetcher {

    /// Half the reader's retention. The other half is the reader's own: its
    /// first fills after the prewarmed regions must not evict the header the
    /// producer comes back to.
    static let maximumBudget = HTTPRangeInput.retainedBytes / 2
    private static let headRequestBytes = HTTPRangeInput.blockSize

    static func prewarm(
        url: URL, headers: [String: String], byteBudget: Int, store: SourcePrewarmStore
    ) async -> SourcePrewarmOutcome {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Blocking fetches, so a thread of their own rather than the
                // cooperative pool — the same reason the probe has one.
                let thread = ProducerThread(name: "cz.zmrhal.prismcore.prewarm") {
                    continuation.resume(returning: run(
                        url: url, headers: headers, byteBudget: byteBudget,
                        store: store, cancelled: { flag.isSet }
                    ))
                }
                withExtendedLifetime(thread) {}
            }
        } onCancel: {
            flag.set()
        }
    }

    static func run(
        url: URL, headers: [String: String], byteBudget: Int,
        store: SourcePrewarmStore, cancelled externallyCancelled: @escaping () -> Bool
    ) -> SourcePrewarmOutcome {
        let clock = ContinuousClock()
        let started = clock.now
        var requests = 0
        func finish(_ status: SourcePrewarmOutcome.Status, validator: String? = nil,
                    stored: Int = 0, headerBytes: Int? = nil, index: Bool = false) -> SourcePrewarmOutcome {
            SourcePrewarmOutcome(status: status, storedBytes: stored, requests: requests,
                validator: validator, headerBytes: headerBytes, indexPrewarmed: index,
                duration: clock.now - started)
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return finish(.notApplicable) }
        let budget = min(max(byteBudget, 0), maximumBudget)
        guard budget > 0 else { return finish(.exceedsCapacity) }

        // A prewarm that has not finished in this long is competing with
        // whatever the user is doing now, not preparing for what comes next.
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        let cancelled = { externallyCancelled() || ProcessInfo.processInfo.systemUptime >= deadline }
        let origin = HTTPOriginCoordinator.origin(url)

        func fetch(start: Int64, size: Int, ifRange: String?) -> Fetched {
            let fetched = Self.fetch(url: url, headers: headers, origin: origin, start: start,
                                     size: size, ifRange: ifRange, cancelled: cancelled)
            // Only what reached the origin: a declined admission sent nothing,
            // and counting it would report load on an origin the prewarm
            // deliberately left alone.
            if case .declined = fetched {} else { requests += 1 }
            return fetched
        }
        func failure(_ fetched: Fetched) -> SourcePrewarmOutcome.Status {
            switch fetched {
            case .declined: return externallyCancelled() ? .cancelled : .originBusy
            case .refused(let status): return .originRefused(status: status)
            case .unusable(let status): return externallyCancelled() ? .cancelled : .unusableResponse(status: status)
            case .ok: return .unusableResponse(status: nil)
            }
        }

        // 1. The head.
        let first = fetch(start: 0, size: min(budget, headRequestBytes), ifRange: nil)
        guard case .ok(let head, let length, let reported) = first else { return finish(failure(first)) }
        guard let validator = reported else { return finish(.validatorUnavailable) }
        let layout = scanLayout(head: head, length: length)

        // 2. The tail, when the framing says an index lives there and the
        //    head does not already hold it: a window that ENDS at the end of
        //    the file and reaches back as far as the budget allows. Not just
        //    the Cues — the segment plan's index load seeks to the duration,
        //    which lands on the last cluster, and that cluster sits just
        //    before them. Measured on a 20-minute Matroska through the proxy
        //    model: Cues-only left that read (522 KB, one whole bite) on the
        //    startup path.
        var tail: SourcePrewarmStore.Block?
        let room = budget - head.count
        if let indexOffset = layout.indexOffset, indexOffset >= Int64(head.count), indexOffset < length,
           room > 0 {
            // An index longer than the room keeps its start: its first bytes
            // are the ones the demuxer reads first.
            let start = max(Int64(head.count), min(indexOffset, length - Int64(room)))
            let size = Int(min(Int64(room), length - start))
            let fetched = fetch(start: start, size: size, ifRange: validator)
            guard case .ok(let data, let tailLength, let tailValidator) = fetched else {
                return finish(failure(fetched), validator: validator)
            }
            guard tailLength == length, tailValidator == validator else {
                return finish(.changedDuringPrewarm, validator: validator)
            }
            tail = .init(start: start, data: data)
        }

        var blocks = [SourcePrewarmStore.Block(start: 0, data: head)]
        if let tail { blocks.append(tail) }
        let entry = SourcePrewarmStore.Entry(validator: validator, length: length, blocks: blocks)
        guard !externallyCancelled() else { return finish(.cancelled, validator: validator) }
        guard store.insert(entry, for: .init(url: url, headers: headers)) else {
            return finish(.exceedsCapacity, validator: validator)
        }
        return finish(.stored, validator: validator, stored: entry.bytes,
                      headerBytes: layout.headerBytes.flatMap { $0 <= head.count ? $0 : nil },
                      index: indexLocated(at: layout.indexOffset, in: blocks))
    }

    /// Whether the index really starts inside the stored bytes.
    ///
    /// The layout's `indexOffset` is where the framing says to look, not
    /// proof of what is there: for an MP4 it is merely the first byte after
    /// a declared-length `mdat`, which may be a `free` box, a second `mdat`,
    /// or nothing the demuxer wants. Reporting the index cached on that alone
    /// would tell a host its tail was covered when the demuxer is about to
    /// fetch it. So this looks: the Cues element ID for a Matroska, a `moov`
    /// box header — walking past the boxes in front of it — for an MP4.
    static func indexLocated(at offset: Int64?, in blocks: [SourcePrewarmStore.Block]) -> Bool {
        guard let offset, let head = blocks.first else { return false }
        func bytes(_ at: Int64, _ count: Int) -> [UInt8]? {
            guard at >= 0, count > 0 else { return nil }
            for block in blocks where at >= block.start {
                let (end, overflow) = at.addingReportingOverflow(Int64(count))
                guard !overflow, end <= block.start + Int64(block.data.count) else { continue }
                let from = block.data.startIndex + Int(at - block.start)
                return [UInt8](block.data[from..<(from + count)])
            }
            return nil
        }
        let magic = [UInt8](head.data.prefix(8))
        if magic.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return bytes(offset, 4) == [0x1C, 0x53, 0xBB, 0x6B]
        }
        guard magic.count == 8, String(decoding: magic[4..<8], as: UTF8.self) == "ftyp" else { return false }
        var cursor = offset
        // A handful of boxes: what sits between `mdat` and a trailing `moov`
        // in practice is a `free` or a `uuid`, not a directory of them.
        for _ in 0..<8 {
            guard let header = bytes(cursor, 8) else { return false }
            if String(decoding: header[4..<8], as: UTF8.self) == "moov" { return true }
            var size = header[0..<4].reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            if size == 1 {
                guard let extended = bytes(cursor + 8, 8) else { return false }
                size = extended.reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            }
            // Size 0 is "to the end of the file" — nothing after it to find.
            guard size >= 8 else { return false }
            let (next, overflow) = cursor.addingReportingOverflow(size)
            guard !overflow else { return false }
            cursor = next
        }
        return false
    }

    /// The container's own framing, read from the prewarmed head only — a
    /// walk that reaches past it reads `nil` and stops, which the scanner
    /// already treats as "not known", never as a guess.
    ///
    /// Sniffed by magic rather than by libavformat's probe: opening a
    /// demuxer here would be the very reads the prewarm exists to move.
    static func scanLayout(head: Data, length: Int64) -> ContainerLayoutScanner.Layout {
        let read: ContainerLayoutScanner.Reader = { offset, count in
            guard offset >= 0, count >= 0, offset + Int64(count) <= Int64(head.count) else { return nil }
            let start = head.startIndex + Int(offset)
            return head.subdata(in: start..<(start + count))
        }
        let prefix = [UInt8](head.prefix(8))
        if prefix.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return ContainerLayoutScanner.scan(formatName: "matroska", byteSize: length, read: read)
        }
        if prefix.count == 8, String(decoding: prefix[4..<8], as: UTF8.self) == "ftyp" {
            return ContainerLayoutScanner.scan(formatName: "mp4", byteSize: length, read: read)
        }
        return .unknown
    }

    enum Fetched {
        case ok(data: Data, length: Int64, validator: String?)
        /// The coordinator did not admit the request.
        case declined
        case refused(status: Int)
        case unusable(status: Int?)
    }

    private static func fetch(
        url: URL, headers: [String: String], origin: String, start: Int64, size: Int,
        ifRange: String?, cancelled: @escaping () -> Bool
    ) -> Fetched {
        autoreleasepool {
            guard HTTPOriginCoordinator.shared.acquireYielding(origin, cancelled: cancelled) else { return .declined }
            defer { HTTPOriginCoordinator.shared.release(origin) }
            var requestHeaders = headers
            // Belt and braces with the validator comparison below: an origin
            // that honours If-Range answers a changed representation with a
            // 200, which the response refuses to buffer.
            if let ifRange { requestHeaders["If-Range"] = ifRange }
            guard let response = try? RangeResponse.fetch(url: url, headers: requestHeaders,
                start: start, size: size, cancelled: cancelled) else { return .unusable(status: nil) }
            let status = response.response?.statusCode ?? 0
            if [429, 503, 509].contains(status) {
                HTTPOriginCoordinator.shared.refuse(
                    origin, retryAfter: response.response?.value(forHTTPHeaderField: "Retry-After"))
                return .refused(status: status)
            }
            guard status == 206, response.error == nil,
                  let raw = response.response?.value(forHTTPHeaderField: "Content-Range"),
                  let range = HTTPRangeInput.contentRange(raw), range.start == start,
                  range.end - range.start + 1 == Int64(response.data.count),
                  response.data.count <= size
            else { return .unusable(status: status == 0 ? nil : status) }
            return .ok(data: response.data, length: range.total,
                       validator: HTTPRangeInput.strongETag(of: response.response))
        }
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
