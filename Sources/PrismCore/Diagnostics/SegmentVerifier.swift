import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Decodes every served fMP4 segment on its own — init segment plus that one
/// fragment, nothing before it — and reports what would not decode.
///
/// An HLS client may start at any segment (a seek, a variant switch, a
/// resume), so each one has to stand alone: begin on a keyframe, reference
/// nothing in the previous fragment, and carry packets its codec accepts. The
/// player is the only other judge of that, and on a device its verdict arrives
/// as a stall or an opaque `-12xxx` with no segment named. This names the
/// segment.
///
/// "Independently" is deliberate on two axes. The bytes are fetched over the
/// served URLs, the way a player gets them, not read off the work directory;
/// and they are demuxed and decoded by a fresh libavformat/libavcodec pair
/// that shares no state with the producer that wrote them. A check that
/// reused the producer's contexts would inherit exactly the bugs it is meant
/// to catch.
///
/// `package` so `prismcore-cli segverify` and the test target run the same
/// checks.
package enum SegmentVerifier {

    package enum Severity: String, Sendable {
        /// The segment cannot be played from a cold start.
        case error
        /// Plays, but disagrees with what the playlist told the client.
        case warning
        /// The check could not be made — a stream this FFmpeg build cannot
        /// decode, a segment that left a sliding window before it was
        /// fetched, an encrypted playlist. Nothing is known to be wrong with
        /// the media, and nothing is known to be right: a run with one of
        /// these must not read as a pass.
        case unverified
    }

    package struct Finding: Sendable, CustomStringConvertible {
        package let severity: Severity
        /// Playlist-relative URI of the segment (or the playlist itself).
        package let location: String
        package let problem: String

        package var description: String { "\(severity.rawValue): \(location): \(problem)" }
    }

    /// What decoding one init + fragment pair found.
    package struct SegmentCheck: Sendable {
        package var packets = 0
        package var videoFrames = 0
        package var audioFrames = 0
        /// Streams that were demuxed but not decoded, because this FFmpeg
        /// build has no decoder for them, as "stream N (codec)". Not an error
        /// — an absent decoder says nothing about the bytes — but the report
        /// turns it into an `.unverified` finding, because a stream nobody
        /// decoded is a stream nobody checked.
        package var undecodedStreams: [String] = []
        /// Summed packet duration of the timing stream (the first video
        /// stream, else the first audio stream), in seconds.
        package var mediaDuration: Double?
        package var problems: [(Severity, String)] = []

        package var hasErrors: Bool { problems.contains { $0.0 == .error } }
    }

    package struct PlaylistReport: Sendable {
        package let uri: String
        package var segmentsChecked = 0
        package var videoFrames = 0
        package var audioFrames = 0
        /// Streams no segment of this playlist could decode (see
        /// `SegmentCheck.undecodedStreams`), in first-seen order.
        package var undecodedStreams: [String] = []
        /// Why the playlist was not decoded at all (a subtitle rendition).
        package var skipped: String?
    }

    package struct Report: Sendable {
        package var playlists: [PlaylistReport] = []
        package var findings: [Finding] = []
        package var hasErrors: Bool { findings.contains { $0.severity == .error } }
        /// False when some check could not be made. A report without errors
        /// is a pass only when this is true as well.
        package var isComplete: Bool { !findings.contains { $0.severity == .unverified } }
    }

    /// `#EXT-X-BYTERANGE` / `BYTERANGE=`: `length` bytes from `offset`.
    ///
    /// Only constructible when the range's end is representable: the
    /// playlist is untrusted input, and `2@9223372036854775806` would
    /// otherwise trap the process on `offset + length` — in the header, the
    /// slice, or the next implicit offset — instead of becoming a finding.
    package struct ByteRange: Sendable, Hashable {
        package let length: Int
        package let offset: Int
        /// One past the last byte; never overflows, by construction.
        package let end: Int

        package init?(length: Int, offset: Int) {
            guard length > 0, offset >= 0 else { return nil }
            let (end, overflow) = offset.addingReportingOverflow(length)
            guard !overflow else { return nil }
            self.length = length
            self.offset = offset
            self.end = end
        }

        /// The HTTP `Range` value for it (inclusive end).
        var header: String { "bytes=\(offset)-\(end - 1)" }
    }

    /// A URI, or a sub-range of one.
    package struct Resource: Sendable, Hashable, CustomStringConvertible {
        package let uri: String
        package let range: ByteRange?
        package init(uri: String, range: ByteRange? = nil) {
            self.uri = uri
            self.range = range
        }
        package var description: String {
            range.map { "\(uri) [\($0.length)@\($0.offset)]" } ?? uri
        }
    }

    /// A media playlist's segments, each with the init section that applies
    /// to it.
    package struct MediaPlaylist: Sendable, Equatable {
        package struct Segment: Sendable, Equatable {
            package let resource: Resource
            /// `#EXTINF`'s value.
            package let duration: Double?
            /// The `#EXT-X-MAP` in force at this segment — HLS applies each
            /// map to the segments after it until the next one, so two maps
            /// in one playlist are two different inits.
            package let initSection: Resource?
            /// `#EXT-X-MEDIA-SEQUENCE` plus the position: the identity that
            /// survives a reload of a sliding playlist, where the position
            /// alone names a different segment every time.
            package let sequence: Int

            package var uri: String { resource.uri }
        }
        package let mediaSequence: Int
        package let segments: [Segment]
        package let isEnded: Bool
        /// A `METHOD` other than `NONE` on some `#EXT-X-KEY`: the fragments
        /// are ciphertext, and decoding them would name every one as corrupt.
        package let encryption: String?
        /// Tags this parser read but could not make sense of, each of which
        /// would otherwise have produced a wrong fetch.
        package let issues: [String]

        /// The first init section's URI, if any segment has one.
        package var initURI: String? { segments.lazy.compactMap(\.initSection).first?.uri }
    }

    package static func parseMediaPlaylist(_ text: String) -> MediaPlaylist {
        var segments: [MediaPlaylist.Segment] = []
        var issues: [String] = []
        var mediaSequence = 0
        var currentMap: Resource?
        var pendingDuration: Double?
        var pendingRange: (length: Int, offset: Int?)?
        // Where the previous sub-range of each resource ended: an
        // `#EXT-X-BYTERANGE` without `@offset` continues from there.
        var previousRange: (uri: String, end: Int)?
        var ended = false
        var encryption: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = parseAttributes(line.dropFirst("#EXT-X-MAP:".count))
                guard let uri = attributes["URI"] else {
                    issues.append("#EXT-X-MAP without a URI: \(line)")
                    continue
                }
                var range: ByteRange?
                if let value = attributes["BYTERANGE"] {
                    guard let parsed = parseByteRange(value) else {
                        issues.append("unreadable BYTERANGE in \(line)")
                        continue
                    }
                    // A map has no previous sub-range to continue, and
                    // RFC 8216 does not say an omitted offset means 0 here.
                    // Guessing would decode the wrong bytes as the init and
                    // blame every segment for it.
                    guard let offset = parsed.offset else {
                        issues.append("BYTERANGE without @offset in \(line): the init's position is unknown")
                        continue
                    }
                    guard let valid = ByteRange(length: parsed.length, offset: offset) else {
                        issues.append("BYTERANGE in \(line) ends past the largest supported offset")
                        continue
                    }
                    range = valid
                }
                currentMap = Resource(uri: uri, range: range)
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                // Not `?? 0`: a sequence misread as 0 renumbers every
                // segment, and a sliding walk then follows the wrong ones.
                let value = line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)
                    .trimmingCharacters(in: .whitespaces)
                guard let parsed = Int(value), parsed >= 0 else {
                    issues.append("unreadable or unsupported \(line) (supported: 0…\(Int.max))")
                    continue
                }
                mediaSequence = parsed
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = parseByteRange(line.dropFirst("#EXT-X-BYTERANGE:".count))
                if pendingRange == nil { issues.append("unreadable \(line)") }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = parseAttributes(line.dropFirst("#EXT-X-KEY:".count))["METHOD"] ?? "NONE"
                if method != "NONE" { encryption = method }
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first
                pendingDuration = value.flatMap { Double($0) }
            } else if line == "#EXT-X-ENDLIST" {
                ended = true
            } else if !line.isEmpty, !line.hasPrefix("#") {
                var range: ByteRange?
                if let pending = pendingRange {
                    if let offset = pending.offset ?? previousRange.flatMap({ $0.uri == line ? $0.end : nil }) {
                        range = ByteRange(length: pending.length, offset: offset)
                        if range == nil {
                            issues.append("#EXT-X-BYTERANGE for \(line) ends past the largest supported offset")
                        }
                    } else {
                        // RFC 8216 §4.3.2.2: an offset-less range continues
                        // the previous segment's sub-range of the same
                        // resource. Guessing 0 would fetch the wrong bytes
                        // and report *them*.
                        issues.append("#EXT-X-BYTERANGE without @offset for \(line), "
                            + "which does not follow a sub-range of the same resource")
                    }
                }
                previousRange = range.map { (line, $0.end) }
                // The walk advances to `sequence + 1`, so the last number a
                // segment may carry is `Int.max - 1`; past that is a finding,
                // not a trap.
                let (sequence, overflow) = mediaSequence.addingReportingOverflow(segments.count)
                guard !overflow, sequence < Int.max else {
                    issues.append("media sequence of \(line) exceeds the supported range (0…\(Int.max - 1))")
                    break
                }
                segments.append(.init(
                    resource: Resource(uri: line, range: range),
                    duration: pendingDuration,
                    initSection: currentMap,
                    sequence: sequence
                ))
                pendingDuration = nil
                pendingRange = nil
            }
        }
        return MediaPlaylist(
            mediaSequence: mediaSequence, segments: segments, isEnded: ended,
            encryption: encryption, issues: issues
        )
    }

    /// `n[@o]`, quoted or not.
    private static func parseByteRange<S: StringProtocol>(_ raw: S) -> (length: Int, offset: Int?)? {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard let length = parts.first.flatMap({ Int($0) }), length > 0, parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard let offset = Int(parts[1]), offset >= 0 else { return nil }
            return (length, offset)
        }
        return (length, nil)
    }

    /// An attribute list (`KEY=value,KEY="quoted, value"`), quotes removed.
    private static func parseAttributes<S: StringProtocol>(_ raw: S) -> [String: String] {
        var attributes: [String: String] = [:]
        var name = ""
        var value = ""
        var inName = true
        var quoted = false
        func flush() {
            let key = name.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { attributes[key] = value }
            name = ""; value = ""; inName = true
        }
        for character in raw {
            if inName {
                if character == "=" { inName = false } else { name.append(character) }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                flush()
            } else {
                value.append(character)
            }
        }
        flush()
        return attributes
    }

    // MARK: - Over HTTP

    /// Verify every segment of the HLS presentation at `playlist` (a master
    /// or a media playlist).
    ///
    /// A playlist that has not ended — PrismCore's unplanned shape grows
    /// until `#EXT-X-ENDLIST`; a live one slides — is re-fetched until it
    /// ends. Segments are followed by media sequence number, not position,
    /// so a window that advances between reloads neither re-checks nor skips
    /// one; a segment that left the window before it could be fetched is an
    /// `.unverified` finding. `stallTimeout` bounds the wait for a segment
    /// that never appears.
    ///
    /// - Parameters:
    ///   - httpHeaders: sent with every request — master, media playlists,
    ///     init sections and fragments alike. An origin that wants a token
    ///     wants it on all of them.
    ///   - limit: stop after this many segments per playlist (a film is a
    ///     thousand of them; the first few catch most splice bugs).
    ///   - unavailableDecoders: codec names to treat as absent from this
    ///     build, so the capability-gap path is testable on a build that has
    ///     every decoder.
    ///   - progress: called once per checked segment, for a live line.
    package static func verify(
        playlist: URL,
        httpHeaders: [String: String] = [:],
        limit: Int? = nil,
        stallTimeout: Duration = .seconds(60),
        unavailableDecoders: Set<String> = [],
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Report {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // A demand fetch of a not-yet-produced segment waits for the producer
        // to get there, which on a remote source is a network read away.
        configuration.timeoutIntervalForRequest = 120
        let fetcher = Fetcher(
            session: URLSession(configuration: configuration), headers: httpHeaders
        )
        defer { fetcher.session.finishTasksAndInvalidate() }

        var report = Report()
        let top = try await fetcher.text(playlist)
        let mediaURLs: [URL]
        if top.contains("#EXT-X-STREAM-INF") {
            let base = playlist.deletingLastPathComponent()
            mediaURLs = PrismCoreSession.playlistURIs(inMaster: top).map {
                URL(string: $0, relativeTo: base)?.absoluteURL ?? base.appendingPathComponent($0)
            }
        } else {
            mediaURLs = [playlist]
        }
        // A media playlist given directly was just fetched; fetching it again
        // for the first pass would, on a live one, skip past a window the
        // walk never looked at.
        var firstLoad: String? = mediaURLs == [playlist] ? top : nil

        for mediaURL in mediaURLs {
            let name = relativeName(mediaURL, to: playlist)
            var playlistReport = PlaylistReport(uri: name)
            // The media sequence number of the next segment to check; `nil`
            // until the first load says where the playlist starts.
            var nextSequence: Int?
            var lastGrowth = ContinuousClock.now
            var inits: [Resource: Data] = [:]
            let reachedLimit = { limit.map { playlistReport.segmentsChecked >= $0 } ?? false }
            reload: while true {
                let text: String
                if let loaded = firstLoad {
                    text = loaded
                    firstLoad = nil
                } else {
                    text = try await fetcher.text(mediaURL)
                }
                let media = parseMediaPlaylist(text)
                if media.initURI == nil, media.segments.contains(where: { $0.uri.hasSuffix(".vtt") }) {
                    playlistReport.skipped = "subtitle rendition (WebVTT is text, not decoded)"
                    break
                }
                if let method = media.encryption {
                    playlistReport.skipped = "encrypted (#EXT-X-KEY METHOD=\(method))"
                    report.findings.append(Finding(
                        severity: .unverified, location: name,
                        problem: "segments are encrypted (METHOD=\(method)); segverify does not decrypt"
                    ))
                    break
                }
                if !media.issues.isEmpty {
                    // A tag misread is a fetch of the wrong bytes, and a
                    // verdict on those bytes would be about nothing.
                    for issue in media.issues {
                        report.findings.append(Finding(severity: .error, location: name, problem: issue))
                    }
                    break
                }
                if media.initURI == nil, !media.segments.isEmpty {
                    report.findings.append(Finding(
                        severity: .error, location: name,
                        problem: "no #EXT-X-MAP: an fMP4 media playlist needs an init segment"
                    ))
                    break
                }
                let start = nextSequence ?? media.mediaSequence
                if media.mediaSequence > start {
                    // The window moved past segments before this walk got to
                    // them. They may have been fine; nobody will ever know.
                    let last = media.mediaSequence - 1
                    report.findings.append(Finding(
                        severity: .unverified, location: name,
                        problem: "media sequence \(start)"
                            + (last > start ? "–\(last)" : "")
                            + " left the playlist window before it was fetched"
                    ))
                }
                nextSequence = max(start, media.mediaSequence)
                for segment in media.segments where segment.sequence >= nextSequence! {
                    if reachedLimit() { break reload }
                    nextSequence = segment.sequence + 1
                    lastGrowth = .now
                    let location = "\(name) → \(segment.resource)"
                    guard let initSection = segment.initSection else {
                        playlistReport.segmentsChecked += 1
                        report.findings.append(Finding(
                            severity: .error, location: location,
                            problem: "no #EXT-X-MAP applies to this segment"
                        ))
                        continue
                    }
                    let initData: Data
                    let data: Data
                    do {
                        if let cached = inits[initSection] {
                            initData = cached
                        } else {
                            initData = try await fetcher.data(initSection, against: mediaURL)
                            inits[initSection] = initData
                        }
                        data = try await fetcher.data(segment.resource, against: mediaURL)
                    } catch {
                        // Cancellation is the caller stopping, not a finding.
                        try Task.checkCancellation()
                        if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                        // A segment the playlist promises and the server will
                        // not deliver is the most direct failure there is —
                        // recorded against that segment, and the walk goes
                        // on so one bad tail does not hide the rest.
                        playlistReport.segmentsChecked += 1
                        report.findings.append(Finding(
                            severity: .error, location: location,
                            problem: "listed but not served: \(Self.describe(error))"
                        ))
                        progress?("\(name) \(segment.resource): FAIL (not served)")
                        continue
                    }
                    let check = verify(
                        initSegment: initData, mediaSegment: data, expectedDuration: segment.duration,
                        unavailableDecoders: unavailableDecoders
                    )
                    playlistReport.segmentsChecked += 1
                    playlistReport.videoFrames += check.videoFrames
                    playlistReport.audioFrames += check.audioFrames
                    for stream in check.undecodedStreams where !playlistReport.undecodedStreams.contains(stream) {
                        playlistReport.undecodedStreams.append(stream)
                    }
                    for (severity, problem) in check.problems {
                        report.findings.append(Finding(severity: severity, location: location, problem: problem))
                    }
                    progress?("\(name) \(segment.resource): "
                        + (check.hasErrors ? "FAIL" : check.undecodedStreams.isEmpty ? "ok" : "unverified")
                        + " (\(check.packets) pkt, \(check.videoFrames) video / \(check.audioFrames) audio frames"
                        + (check.undecodedStreams.isEmpty
                            ? "" : "; not decoded: " + check.undecodedStreams.joined(separator: ", "))
                        + ")")
                }
                if reachedLimit() || media.isEnded { break }
                if ContinuousClock.now - lastGrowth > stallTimeout {
                    report.findings.append(Finding(
                        severity: .error, location: name,
                        problem: "no new segment for \(stallTimeout) and no #EXT-X-ENDLIST — "
                            + "the producer stalled or died after \(playlistReport.segmentsChecked) segment(s)"
                    ))
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            for stream in playlistReport.undecodedStreams {
                report.findings.append(Finding(
                    severity: .unverified, location: name,
                    problem: "\(stream): no decoder in this FFmpeg build — demuxed, never decoded, not verified"
                ))
            }
            report.playlists.append(playlistReport)
        }
        return report
    }

    // MARK: - One segment

    /// Demux and decode `initSegment + mediaSegment` as a standalone fMP4.
    package static func verify(
        initSegment: Data, mediaSegment: Data, expectedDuration: Double? = nil,
        unavailableDecoders: Set<String> = []
    ) -> SegmentCheck {
        var check = SegmentCheck()
        // A file rather than a custom AVIO: the mov demuxer seeks around the
        // moof/mdat pair, and a file is the seekable input it is best tested
        // against — the check should not add a reader of its own to suspect.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-segverify-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try (initSegment + mediaSegment).write(to: file)
        } catch {
            check.problems.append((.error, "could not stage the segment for decoding: \(error)"))
            return check
        }

        var context: UnsafeMutablePointer<AVFormatContext>?
        let opened = avformat_open_input(&context, file.path, nil, nil)
        guard opened >= 0, let input = context else {
            check.problems.append((.error, "init + segment does not demux as fMP4: "
                + FFmpegError(code: opened, operation: "avformat_open_input").message))
            return check
        }
        defer { avformat_close_input(&context) }
        let info = avformat_find_stream_info(input, nil)
        if info < 0 {
            check.problems.append((.error, "stream analysis failed: "
                + FFmpegError(code: info, operation: "avformat_find_stream_info").message))
            return check
        }

        var decoders: [Int32: StreamDecoder] = [:]
        defer { decoders.values.forEach { $0.close() } }
        var firstVideo: Int32?
        var firstAudio: Int32?
        for index in 0..<Int32(input.pointee.nb_streams) {
            guard let stream = input.pointee.streams[Int(index)],
                  let parameters = stream.pointee.codecpar
            else { continue }
            let type = parameters.pointee.codec_type
            guard type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO else { continue }
            if type == AVMEDIA_TYPE_VIDEO { firstVideo = firstVideo ?? index }
            else { firstAudio = firstAudio ?? index }
            switch StreamDecoder.make(stream: stream, unavailable: unavailableDecoders) {
            case .success(let decoder): decoders[index] = decoder
            case .failure(let reason):
                if case .noDecoder(let codec) = reason {
                    check.undecodedStreams.append("stream \(index) (\(codec))")
                } else {
                    check.problems.append((.error, "stream \(index): \(reason)"))
                }
            }
        }
        let timingStream = firstVideo ?? firstAudio
        if decoders.isEmpty && check.undecodedStreams.isEmpty {
            check.problems.append((.error, "no audio or video stream in init + segment"))
            return check
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return check }
        var seenFirstVideoPacket = false
        var videoPackets = 0
        var timingTicks: Int64 = 0
        var timingBase: AVRational?
        // Pictures that follow the opening keyframe in decode order but
        // precede it in presentation order: an open GOP's leading pictures.
        var openingKeyframePTS: Int64?
        var leadingPictures = 0

        while true {
            let read = av_read_frame(input, packet)
            if read == swift_AVERROR_EOF() { break }
            if read < 0 {
                check.problems.append((.error, "demux failed after \(check.packets) packet(s): "
                    + FFmpegError(code: read, operation: "av_read_frame").message))
                break
            }
            defer { av_packet_unref(packet) }
            check.packets += 1
            let index = packet.pointee.stream_index
            if index == timingStream, let stream = input.pointee.streams[Int(index)] {
                timingTicks += packet.pointee.duration
                timingBase = stream.pointee.time_base
            }
            guard let decoder = decoders[index] else { continue }
            if decoder.isVideo {
                videoPackets += 1
                if !seenFirstVideoPacket {
                    seenFirstVideoPacket = true
                    // The property a cold start depends on first: a fragment
                    // that opens on a non-key frame decodes garbage (or
                    // nothing) until the next keyframe, which may be the next
                    // segment.
                    if packet.pointee.flags & AV_PKT_FLAG_KEY == 0 {
                        check.problems.append((.error,
                            "first video packet is not a keyframe — the segment cannot start playback"))
                    } else if packet.pointee.pts != swift_AV_NOPTS_VALUE() {
                        openingKeyframePTS = packet.pointee.pts
                    }
                } else if let openingKeyframePTS, packet.pointee.pts != swift_AV_NOPTS_VALUE(),
                          packet.pointee.pts < openingKeyframePTS {
                    leadingPictures += 1
                }
            }
            decoder.decode(packet)
        }
        for decoder in decoders.values { decoder.decode(nil) }

        for (index, decoder) in decoders.sorted(by: { $0.key < $1.key }) {
            if decoder.isVideo { check.videoFrames += decoder.frames } else { check.audioFrames += decoder.frames }
            if let first = decoder.errors.first {
                check.problems.append((.error, "stream \(index) (\(decoder.codecName)): "
                    + "\(decoder.errors.count) decode error(s), first: \(first)"))
            }
            if decoder.corruptFrames > 0 {
                check.problems.append((.error, "stream \(index) (\(decoder.codecName)): "
                    + "\(decoder.corruptFrames) frame(s) decoded flagged corrupt — "
                    + "likely a reference into the previous segment"))
            }
            if decoder.isVideo, decoder.errors.isEmpty, decoder.frames < videoPackets {
                // Every video packet the remux writes is a picture; one that
                // produced no frame was dropped by the decoder, which is what a
                // missing reference looks like when it is not loud.
                let missing = videoPackets - decoder.frames
                if missing <= leadingPictures {
                    // An open GOP: the segment opens on a CRA/non-IDR I-frame
                    // whose leading pictures reference the previous GOP, and a
                    // decoder starting here skips them (HEVC RASL). Stream
                    // copy cannot change the source's GOP structure, and a
                    // cold start loses only those frames — worth knowing, not
                    // a segment that fails to play.
                    check.problems.append((.warning, "stream \(index) (\(decoder.codecName)): "
                        + "\(missing) leading picture(s) after the opening keyframe reference the "
                        + "previous segment (open GOP in the source); a cold start here skips them"))
                } else {
                    check.problems.append((.error, "stream \(index) (\(decoder.codecName)): "
                        + "\(videoPackets) packet(s) produced only \(decoder.frames) frame(s)"))
                }
            }
        }
        if check.packets == 0 {
            check.problems.append((.error, "segment carries no packets"))
        } else if videoPackets == 0, decoders.values.contains(where: \.isVideo) {
            check.problems.append((.error, "init declares video but the segment carries none"))
        }

        if let timingBase, timingTicks > 0 {
            let seconds = Double(timingTicks) * av_q2d(timingBase)
            check.mediaDuration = seconds
            // A client plans its buffer and its seek targets on #EXTINF, so a
            // segment much longer or shorter than declared plays but lands
            // seeks in the wrong place. Loose on purpose: fMP4 packet
            // durations round, and audio frames never tile a boundary exactly.
            if let expectedDuration, abs(seconds - expectedDuration) > max(0.5, expectedDuration * 0.1) {
                check.problems.append((.warning, String(
                    format: "media lasts %.3fs but #EXTINF says %.3fs", seconds, expectedDuration
                )))
            }
        }
        return check
    }

    // MARK: - Helpers

    /// Every request the walk makes, with the caller's headers on each and
    /// a byte range where the playlist names one.
    private struct Fetcher {
        let session: URLSession
        let headers: [String: String]

        func data(_ url: URL, range: ByteRange? = nil) async throws -> Data {
            var request = URLRequest(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if let range { request.setValue(range.header, forHTTPHeaderField: "Range") }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            guard (200..<300).contains(http.statusCode) else {
                throw FetchFailure(url: url, status: http.statusCode)
            }
            guard let range else { return data }
            if http.statusCode == 206 {
                // Short is a failure, not a smaller segment: decoding what
                // did arrive would report truncation as the media's fault.
                guard data.count == range.length else {
                    throw RangeFailure(url: url, range: range, received: data.count)
                }
                return data
            }
            // A 200 to a ranged request is an origin that ignores `Range` and
            // sent the whole resource; the sub-range is still in it.
            guard data.count >= range.end else {
                throw RangeFailure(url: url, range: range, received: data.count)
            }
            return data.subdata(in: range.offset..<range.end)
        }

        func data(_ resource: Resource, against playlist: URL) async throws -> Data {
            try await data(resolve(resource.uri, against: playlist), range: resource.range)
        }

        func text(_ url: URL) async throws -> String {
            String(decoding: try await data(url), as: UTF8.self)
        }
    }

    /// A URLError's one-line reason rather than its whole userInfo dump.
    private static func describe(_ error: any Error) -> String {
        if let failure = error as? FetchFailure { return failure.description }
        if let failure = error as? RangeFailure { return failure.description }
        if let urlError = error as? URLError {
            return "\(urlError.localizedDescription) (URLError \(urlError.code.rawValue))"
        }
        return "\(error)"
    }

    private static func resolve(_ uri: String, against playlist: URL) -> URL {
        URL(string: uri, relativeTo: playlist)?.absoluteURL
            ?? playlist.deletingLastPathComponent().appendingPathComponent(uri)
    }

    private static func relativeName(_ url: URL, to top: URL) -> String {
        let base = top.deletingLastPathComponent().absoluteString
        let full = url.absoluteString
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full
    }

    package struct FetchFailure: Error, CustomStringConvertible {
        package let url: URL
        package let status: Int
        package var description: String { "GET \(url.absoluteString) answered HTTP \(status)" }
    }

    package struct RangeFailure: Error, CustomStringConvertible {
        package let url: URL
        package let range: ByteRange
        package let received: Int
        package var description: String {
            "GET \(url.absoluteString) Range \(range.header) delivered \(received) of \(range.length) bytes"
        }
    }
}

/// One stream's libavcodec decoder, counting what it produced and what it
/// refused.
private final class StreamDecoder {
    enum MakeFailure: Error, CustomStringConvertible {
        case noDecoder(String)
        case openFailed(String)
        var description: String {
            switch self {
            case .noDecoder(let codec): return "no decoder for \(codec) in this build"
            case .openFailed(let message): return "decoder would not open: \(message)"
            }
        }
    }

    let isVideo: Bool
    let codecName: String
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private(set) var frames = 0
    private(set) var corruptFrames = 0
    private(set) var errors: [String] = []

    private init(context: UnsafeMutablePointer<AVCodecContext>, isVideo: Bool, codecName: String) {
        self.context = context
        self.isVideo = isVideo
        self.codecName = codecName
        self.frame = av_frame_alloc()
    }

    static func make(
        stream: UnsafeMutablePointer<AVStream>, unavailable: Set<String> = []
    ) -> Result<StreamDecoder, MakeFailure> {
        let parameters = stream.pointee.codecpar!
        let name = String(cString: avcodec_get_name(parameters.pointee.codec_id))
        guard !unavailable.contains(name), let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            return .failure(.noDecoder(name))
        }
        guard let context = avcodec_alloc_context3(codec) else {
            return .failure(.openFailed("avcodec_alloc_context3 returned nil"))
        }
        var owned: UnsafeMutablePointer<AVCodecContext>? = context
        var result = avcodec_parameters_to_context(context, parameters)
        if result >= 0 {
            // Without it the decoder has no clock for the packets' timestamps
            // (the subtitle lesson in AGENTS.md applies to every decoder).
            context.pointee.pkt_timebase = stream.pointee.time_base
            result = avcodec_open2(context, codec, nil)
        }
        guard result >= 0 else {
            avcodec_free_context(&owned)
            return .failure(.openFailed(FFmpegError(code: result, operation: "avcodec_open2").message))
        }
        return .success(StreamDecoder(
            context: context,
            isVideo: parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
            codecName: name
        ))
    }

    /// Send one packet (or `nil` to flush) and drain every frame it releases.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>?) {
        guard let context, let frame else { return }
        let sent = avcodec_send_packet(context, packet)
        if sent < 0, sent != swift_AVERROR(EAGAIN), sent != swift_AVERROR_EOF() {
            errors.append(FFmpegError(code: sent, operation: "avcodec_send_packet").message)
        }
        while true {
            let received = avcodec_receive_frame(context, frame)
            if received == swift_AVERROR(EAGAIN) || received == swift_AVERROR_EOF() { break }
            if received < 0 {
                errors.append(FFmpegError(code: received, operation: "avcodec_receive_frame").message)
                break
            }
            frames += 1
            // `AV_FRAME_FLAG_CORRUPT` is `1 << 0` — a macro Swift cannot
            // import, and the flag a decoder raises for a picture it
            // concealed rather than decoded.
            if frame.pointee.flags & (1 << 0) != 0 || frame.pointee.decode_error_flags != 0 {
                corruptFrames += 1
            }
            av_frame_unref(frame)
        }
    }

    func close() {
        av_frame_free(&frame)
        avcodec_free_context(&context)
    }
}
