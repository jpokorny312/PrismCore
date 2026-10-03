import Foundation
import Libavformat
import Libavutil

/// Optional seekable HTTP file input. A bounded range buffer lets all seeks,
/// probe reads and playback reads use the same per-origin admission policy.
/// This is for finite files, not nested HLS playlists or unbounded live feeds.
final class HTTPRangeInput {
    private var url: URL
    private var headers: [String: String]
    private let interrupted: () -> Bool
    static let blockSize = 1 << 20
    private var position: Int64 = 0
    private var length: Int64?
    private var validator: String?

    /// How large the FIRST fill may be, when a caller's sizing hint says the
    /// metadata region is bigger than one block.
    ///
    /// Only ever **upward**, and only for the first fill. A header of three
    /// megabytes costs three requests at the fixed block size, and against a
    /// proxy that fetches each forwarded window whole before writing a byte
    /// those are three full waits; asking for the region in one request is the
    /// entire sizing win the hint exists for. Downward it is deliberately
    /// inert: this reader's first read is already a bounded
    /// `bytes=0-1048575`, not the open-ended request the design's first
    /// measurement is about, and shrinking it below a block would only turn
    /// one round trip into several on any file whose analysis reads past its
    /// header — which is most of them.
    private var firstFillSize: Int?

    /// The validator a caller stated it expects, and what the origin actually
    /// reported on the first response. Compared once, before any byte has been
    /// delivered, and never fatal: a hint that cannot be bound to the
    /// representation is a hint that is not used, not a play that fails.
    private let expectedValidator: String?
    private var firstResponseSeen = false
    private var observation: ValidatorObservation = .notObserved

    enum ValidatorObservation: Equatable {
        /// No response has arrived yet.
        case notObserved
        /// The origin reported none — no `ETag`, no `Last-Modified`.
        case unavailable
        case satisfied(String)
        case mismatched(reported: String)
        /// A validator was reported and the caller stated no expectation.
        case unchecked(String)
    }

    /// What the first response said, once it has arrived. Locked for the same
    /// reason `lastOriginFailure` is: the open site reads it from the thread
    /// that ran the blocking open, and nothing guarantees the reader thread is
    /// finished with it.
    var validatorObservation: ValidatorObservation {
        failureLock.withLock { observation }
    }

    /// Recently fetched blocks, least-recently-used first.
    ///
    /// More than one on purpose. Startup's read pattern is head → tail → head:
    /// the demuxer opens at the header, the segment plan nudges it to the
    /// container's index at the tail (a Matroska's Cues take two reads there),
    /// and the producer then starts at byte zero. With a single block that
    /// last step refetches bytes this reader already had, and it is not a
    /// cheap refetch — measured against a model of Aether's localhost range
    /// proxy, which fetches each forwarded window whole before it writes a
    /// byte: 1.35 s of a 3.0 s startup on a 60 min Matroska.
    ///
    /// Bounded by BYTES rather than by block count, because the blocks are
    /// not the same size: the two tail reads are tens of kilobytes, and
    /// counting them as equals to the 1 MB head is what evicts the head they
    /// were fetched around. The bound is per reader, and a session has more
    /// than one (the producer, a scrub preview), so it is deliberately close
    /// to the read pattern's own size rather than a cache anyone would tune.
    static let retainedBytes = 4 << 20
    private var blocks: [(start: Int64, data: Data)] = []
    private var io: UnsafeMutablePointer<AVIOContext>?
    /// What the origin last said, kept because the only thing this reader can
    /// hand libavformat is an errno: `read` returns `-EIO` and every status —
    /// 403, 429, the connection that died — arrives at the open site as
    /// "Input/output error". The open sites ask for this instead, which is the
    /// whole reason a host can tell an expired token from a full disk.
    ///
    /// Locked because the open site reads it from the thread that ran the
    /// blocking open while nothing guarantees the reader thread is done.
    private let failureLock = NSLock()
    private var latchedFailure: PrismCoreError?
    var lastOriginFailure: PrismCoreError? { failureLock.withLock { latchedFailure } }
    private func latch(_ failure: PrismCoreError?) { failureLock.withLock { latchedFailure = failure } }

    /// Where a prewarm left this source's first bytes, and what became of
    /// them. Consulted once, before the first fill; `nil` opts a reader out
    /// (tests that count requests against a cold origin).
    private let prewarmStore: SourcePrewarmStore?
    private var prewarmConsulted = false
    private var prewarmOutcome: SourcePrewarmUse = .none
    var prewarmUse: SourcePrewarmUse { failureLock.withLock { prewarmOutcome } }

    init(
        url: URL,
        headers: [String: String],
        hints: SourceOpenHints? = nil,
        prewarmStore: SourcePrewarmStore? = .shared,
        interrupted: @escaping () -> Bool
    ) {
        self.prewarmStore = prewarmStore
        self.url = url
        self.headers = headers
        self.interrupted = interrupted
        self.expectedValidator = hints?.expectedValidator
        // Clamped to what this reader is willing to retain: a first fill it
        // would evict on its own next fill has bought nothing.
        self.firstFillSize = hints?.firstReadSizeHint.map {
            min(max($0, Self.blockSize), Self.retainedBytes)
        }
    }

    /// The size the first fill was actually bounded to, for the host's log
    /// line. `nil` until that fill has happened.
    private(set) var firstFillBytes: Int?

    func install(on context: UnsafeMutablePointer<AVFormatContext>) throws {
        guard let allocation = av_malloc(32768) else { throw Failure.allocation }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        io = avio_alloc_context(allocation.assumingMemoryBound(to: UInt8.self), 32768, 0, opaque,
            { opaque, bytes, count in
                guard let opaque, let bytes else { return swift_AVERROR(EIO) }
                return Unmanaged<HTTPRangeInput>.fromOpaque(opaque).takeUnretainedValue().read(into: bytes, count: count)
            }, nil,
            { opaque, offset, whence in
                guard let opaque else { return -1 }
                return Unmanaged<HTTPRangeInput>.fromOpaque(opaque).takeUnretainedValue().seek(offset: offset, whence: whence)
            })
        guard let io else { av_free(allocation); throw Failure.allocation }
        io.pointee.seekable = 1
        context.pointee.pb = io
        context.pointee.flags |= 0x0080 // AVFMT_FLAG_CUSTOM_IO: this owner frees AVIO.
    }

    deinit {
        if let io { av_free(io.pointee.buffer); avio_context_free(&self.io) }
    }

    private func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & 0x10000 != 0 { // AVSEEK_SIZE
            if length == nil { adoptPrewarmIfPresent() }
            if length == nil { do { try fill() } catch { return -1 } }
            return length ?? -1
        }
        let base: Int64
        switch whence & ~0x20000 {
        case SEEK_SET: base = 0
        case SEEK_CUR: base = position
        case SEEK_END: guard let length else { return -1 }; base = length
        default: return -1
        }
        let (target, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, target >= 0 else { return -1 }
        position = target
        return target
    }

    private func read(into destination: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32 {
        guard count > 0 else { return 0 }
        if interrupted() { return swift_AVERROR_EXIT() }
        if let length, position >= length { return swift_AVERROR_EOF() }
        do {
            if blockIndex(containing: position) == nil { adoptPrewarmIfPresent() }
            if blockIndex(containing: position) == nil { try fill() }
            guard let index = blockIndex(containing: position) else { return swift_AVERROR_EOF() }
            // Touched blocks become the most recent, so a reader alternating
            // between two regions keeps both rather than thrashing one out.
            let block = blocks.remove(at: index)
            blocks.append(block)
            let offset = Int(position - block.start)
            let copied = min(Int(count), block.data.count - offset)
            block.data.copyBytes(to: destination, from: offset..<(offset + copied))
            position += Int64(copied)
            return Int32(copied)
        } catch { return interrupted() ? swift_AVERROR_EXIT() : swift_AVERROR(EIO) }
    }

    /// Drained per fill because the reader runs on threads that never drain
    /// one themselves — the producer's and the probe's `ProducerThread`s are
    /// plain `Thread`s parked in FFmpeg for a whole film. Everything URL
    /// loading autoreleases on the caller's side (responses, header strings,
    /// the task) otherwise stays until the thread exits: with a session per
    /// fill that was ~1.13 MB per 1 MiB block in 3.2.1, and a 4K play on an
    /// Apple TV grew to 1.56 GB in under nine minutes and was killed by Jetsam.
    private func fill() throws {
        try autoreleasepool { try fillUnpooled() }
    }

    private func fillUnpooled() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        let cancelled = { [self] in interrupted() || ProcessInfo.processInfo.systemUptime >= deadline }
        for _ in 0..<8 {
            guard !cancelled() else { throw Failure.request }
            let origin = HTTPOriginCoordinator.origin(url)
            guard HTTPOriginCoordinator.shared.acquire(origin, cancelled: cancelled) else { throw Failure.request }
            let requestSize = firstFillSize ?? Self.blockSize
            let response: RangeResponse
            do {
                var requestHeaders = headers
                if let validator { requestHeaders["If-Range"] = validator }
                response = try RangeResponse.fetch(url: url, headers: requestHeaders, start: position,
                    size: requestSize, cancelled: cancelled)
            } catch { HTTPOriginCoordinator.shared.release(origin); throw error }
            let status = response.response?.statusCode ?? 0
            if response.error != nil && (status == 0 || status == 206) {
                // No status, even when the origin answered 206 first. The two
                // are about different things: the status describes a *response*
                // that succeeded, the error describes a *transfer* that did
                // not, and only the second one failed. Carrying the 206 here
                // made `retryability` read "non-nil status below 500" as
                // `.permanent` and tell hosts not to retry a dropped socket on
                // a healthy origin. Fixed at the recording site rather than by
                // teaching `retryability` about success codes, because a
                // failure carrying a success status is a state that should not
                // exist — the transfer error is the whole evidence, and it
                // rides along in `underlying`.
                latch(.originUnreachable(status: nil, url: url, underlying: response.error))
                HTTPOriginCoordinator.shared.refuse(origin, retryAfter: "0.25", throttled: false)
                HTTPOriginCoordinator.shared.release(origin)
                continue
            }
            if [429, 503, 509].contains(status) {
                let retryAfter = response.response?.value(forHTTPHeaderField: "Retry-After")
                latch(.originRateLimited(status: status,
                    retryAfter: HTTPOriginCoordinator.retryDelay(retryAfter), url: url))
                HTTPOriginCoordinator.shared.refuse(origin, retryAfter: retryAfter)
                HTTPOriginCoordinator.shared.release(origin)
                continue
            }
            HTTPOriginCoordinator.shared.release(origin)
            if [301, 302, 303, 307, 308].contains(status),
               let location = response.response?.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: url)?.absoluteURL,
               ["http", "https"].contains(next.scheme?.lowercased() ?? "") {
                guard !(url.scheme == "https" && next.scheme == "http") else { throw Failure.request }
                if HTTPOriginCoordinator.origin(next) != origin {
                    // Custom authentication header names are unknowable: no
                    // caller headers cross an origin boundary automatically.
                    headers.removeAll()
                }
                url = next
                continue
            }
            // Only 4xx/5xx: a bare 200 here means a server that ignored the
            // Range header and had its body cancelled, which is a capability
            // problem, not a refusal — naming it one would send a host off
            // re-authenticating against an origin that is answering fine.
            if status >= 400 {
                latch([401, 403, 407].contains(status)
                    ? .originRefused(status: status, url: url)
                    : .originUnreachable(status: status, url: url, underlying: nil))
            }
            guard status == 206, response.error == nil,
                  let raw = response.response?.value(forHTTPHeaderField: "Content-Range"),
                  let range = Self.contentRange(raw), range.start == position,
                  range.end - range.start + 1 == Int64(response.data.count),
                  response.data.count <= requestSize else { throw Failure.request }
            if let length, length != range.total { throw Failure.request }
            let currentValidator = Self.validator(of: response.response)
            if let validator, let currentValidator, validator != currentValidator { throw Failure.request }
            if validator == nil { validator = currentValidator }
            // The caller's expectation, judged once and only on the FIRST real
            // response — before a byte of it has been delivered anywhere.
            // Deliberately not a throw: a representation that is not the one
            // the hints describe is a reason to stop trusting the hints, and
            // the bytes arriving here are a perfectly good current version to
            // open unhinted. The mid-session case is the line above, which
            // does throw, because there the old version's headers, blocks and
            // plan are already built and mixing versions fails invisibly.
            observeFirstResponse(reporting: currentValidator)
            // One fill only: every later read is an ordinary block.
            if firstFillSize != nil {
                firstFillBytes = requestSize
                firstFillSize = nil
            }
            length = range.total
            blocks.append((start: position, data: response.data))
            // Never drops the block just fetched: it is the one the read that
            // triggered this fill is about to use.
            var retained = blocks.reduce(0) { $0 + $1.data.count }
            while blocks.count > 1, retained > Self.retainedBytes {
                retained -= blocks.removeFirst().data.count
            }
            // A refusal the retry loop rode out must not outlive it: a session
            // that was throttled at minute one and dies of something else at
            // minute forty would otherwise be reported as rate-limited.
            latch(nil)
            HTTPOriginCoordinator.shared.succeeded(origin)
            return
        }
        throw Failure.request
    }

    /// The validator a response binds its bytes to: a strong `ETag`, else
    /// `Last-Modified`. A weak `ETag` promises semantic equivalence, not the
    /// same bytes, and byte ranges from two "equivalent" versions do not make
    /// one file.
    static func validator(of response: HTTPURLResponse?) -> String? {
        strongETag(of: response) ?? response?.value(forHTTPHeaderField: "Last-Modified")
    }

    /// The strong `ETag` alone — the only validator a prewarm binds bytes to.
    ///
    /// `Last-Modified` is enough for `If-Range` on a live read, where the
    /// bytes arrive in the same response the date came with. It is not
    /// enough to vouch for bytes fetched minutes earlier: it has one-second
    /// resolution, so a file replaced within the second it was last written
    /// keeps its date, and when the length and the first byte survive too
    /// (a re-mux, a re-tag) every check the adoption makes passes on stale
    /// bytes.
    static func strongETag(of response: HTTPURLResponse?) -> String? {
        response?.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
    }

    private func observeFirstResponse(reporting currentValidator: String?) {
        guard !firstResponseSeen else { return }
        firstResponseSeen = true
        let verdict: ValidatorObservation
        switch (expectedValidator, currentValidator) {
        case (nil, let reported?): verdict = .unchecked(reported)
        case (nil, nil): verdict = .unavailable
        case (_?, nil): verdict = .unavailable
        case (let expected?, let reported?):
            verdict = expected == reported ? .satisfied(reported) : .mismatched(reported: reported)
        }
        failureLock.withLock { observation = verdict }
    }

    /// Take over a prewarm of this URL and these headers — once, before
    /// anything has been fetched, and only after the origin has confirmed it
    /// still serves the bytes the prewarm saw.
    ///
    /// The confirmation is one request for one byte. It is the same trust
    /// rule the 3.2.0 hints follow, applied where the stakes are higher: a
    /// stale sizing hint costs a read, stale *bytes* are a wrong parse. So
    /// the strong ETag and the length must both match, and the one byte must
    /// be the byte the prewarm stored at that offset. Against a host proxy
    /// that fetches each window whole, a one-byte window is a round trip and
    /// nothing more, which is the whole saving: the reads it replaces are a
    /// full bite each.
    ///
    /// Every way this can fail is "read the network, as if nobody had
    /// prewarmed" — never a failed open. A mismatch discards the entry (it
    /// describes a representation the origin no longer serves); an answer
    /// that did not arrive leaves it for a later reader.
    private func adoptPrewarmIfPresent() {
        guard !prewarmConsulted else { return }
        prewarmConsulted = true
        guard let store = prewarmStore, blocks.isEmpty, length == nil else { return }
        let key = SourcePrewarmStore.Key(url: url, headers: headers)
        guard let entry = store.entry(for: key) else { return }
        autoreleasepool {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            let cancelled = { [self] in interrupted() || ProcessInfo.processInfo.systemUptime >= deadline }
            let origin = HTTPOriginCoordinator.origin(url)
            // Full-priority admission: this request is on the path of a play
            // the user is waiting for, unlike the prewarm that filled the
            // entry.
            guard HTTPOriginCoordinator.shared.acquire(origin, cancelled: cancelled) else {
                failureLock.withLock { prewarmOutcome = .unverified }
                return
            }
            let response = try? RangeResponse.fetch(url: url, headers: headers, start: 0, size: 1,
                                                    cancelled: cancelled)
            let status = response?.response?.statusCode ?? 0
            if [429, 503, 509].contains(status) {
                // Recorded so the fill that follows waits the refusal out
                // rather than walking straight into it.
                HTTPOriginCoordinator.shared.refuse(
                    origin, retryAfter: response?.response?.value(forHTTPHeaderField: "Retry-After"))
            }
            HTTPOriginCoordinator.shared.release(origin)
            guard let response, status == 206, response.error == nil,
                  let raw = response.response?.value(forHTTPHeaderField: "Content-Range"),
                  let range = Self.contentRange(raw), range.start == 0, response.data.count == 1
            else {
                failureLock.withLock { prewarmOutcome = .unverified }
                return
            }
            let reported = Self.validator(of: response.response)
            // This is the first response this reader has seen, whatever
            // happens next, and the hints' validator check is judged on it.
            observeFirstResponse(reporting: reported)
            validator = reported
            length = range.total
            // Judged on the strong ETag only, whatever the entry says: an
            // origin that has since dropped its ETag in favour of a date can
            // no longer vouch for these bytes (see `strongETag(of:)`).
            guard let tag = Self.strongETag(of: response.response), tag == entry.validator,
                  range.total == entry.length,
                  let head = entry.blocks.first, head.start == 0, head.data.first == response.data.first
            else {
                store.remove(key)
                failureLock.withLock { prewarmOutcome = .stale }
                return
            }
            // Head first: it is the region read first and read again after
            // the excursion to the tail, so it is the one retention keeps if
            // an entry ever outgrows it.
            //
            // Split to block size on the way in, so the reader's own eviction
            // drops a block at a time as it does for fetched ones — an entry
            // taken as one large block is lost whole to the first fill that
            // needs room, header included.
            var taken = 0
            for block in entry.blocks where taken + block.data.count <= Self.retainedBytes {
                var offset = 0
                while offset < block.data.count {
                    let end = min(offset + Self.blockSize, block.data.count)
                    let piece = block.data.startIndex + offset..<block.data.startIndex + end
                    blocks.append((start: block.start + Int64(offset), data: Data(block.data[piece])))
                    offset = end
                }
                taken += block.data.count
            }
            // The region a sizing hint would have sized is already here; the
            // next fill is an ordinary block past it.
            firstFillSize = nil
            failureLock.withLock { prewarmOutcome = .adopted(bytes: taken) }
        }
    }

    private func blockIndex(containing offset: Int64) -> Int? {
        blocks.lastIndex { offset >= $0.start && offset < $0.start + Int64($0.data.count) }
    }

    static func contentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let components = value.dropFirst(6).split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "/" })
        guard components.count == 3, let start = Int64(components[0]), let end = Int64(components[1]),
              let total = Int64(components[2]), start >= 0, end >= start, total > end else { return nil }
        return (start, end, total)
    }

    enum Failure: Error { case allocation, request }
}

final class RangeResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var response: HTTPURLResponse?
    var data = Data()
    var error: Error?
    let limit: Int
    private let completed = DispatchSemaphore(value: 0)

    init(limit: Int) { self.limit = limit }

    /// One session for every reader in the process, each fetch its own task
    /// with its own delegate.
    ///
    /// 3.2.1 built an ephemeral session per fill — a session, its delegate
    /// queue and its connection state for every 1 MiB — and that, on a thread
    /// with no autorelease pool, was the Jetsam: ~1.13 MB kept per fill,
    /// linear in bytes played. Measured on the same loop (1000 fills of 1 MiB
    /// on a pool-less `Thread`, loopback origin): 1132.7 MB with a session per
    /// fill, 25.1 MB flat with this one shared session, 17.0 MB with the
    /// per-fill pool added as well.
    ///
    /// Shared rather than per reader because nothing about a fetch belongs to
    /// the session any more: admission is `HTTPOriginCoordinator`'s (at most
    /// two per origin, well under the per-host connection limit, so tasks
    /// never queue behind each other here and eat their own timeouts),
    /// redirects are refused per task, and the ephemeral per-fill sessions
    /// never kept state between fills — so this one is told not to either.
    /// Without that, the ephemeral configuration's in-memory cookie jar and
    /// cache would start carrying one reader's `Set-Cookie` into another's
    /// requests, which a session per fill could never do.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    static func fetch(url: URL, headers: [String: String], start: Int64, size: Int,
                      cancelled: () -> Bool) throws -> RangeResponse {
        let result = RangeResponse(limit: size)
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (end, overflow) = start.addingReportingOverflow(Int64(size) - 1)
        request.setValue("bytes=\(start)-\(overflow ? Int64.max : end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        // A per-task delegate (tvOS 15+) gets the same data-task callbacks the
        // session delegate used to, and is released with the task.
        task.delegate = result
        task.resume()
        while result.completed.wait(timeout: .now() + 0.05) == .timedOut {
            if cancelled() { task.cancel(); throw HTTPRangeInput.Failure.request }
        }
        return result
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        // A server ignoring Range must not download a movie into this buffer.
        completionHandler(self.response?.statusCode == 206 && response.expectedContentLength <= Int64(limit) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.data.count + data.count <= limit else { dataTask.cancel(); return }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.error = error
        completed.signal()
    }
}
