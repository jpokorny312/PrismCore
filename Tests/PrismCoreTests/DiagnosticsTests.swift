import Testing
import Foundation
@testable import PrismCore

/// The shared diagnostics behind `prismcore-cli` — hermetic, on fixtures, so
/// what the CLI prints is pinned by the suite rather than by whoever last ran
/// it by hand.
@Suite("Diagnostics", .serialized)
struct DiagnosticsTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    // MARK: StartupCheckpointRun

    /// The line's shape is its contract: a device log and a bench run are
    /// compared term by term, so a reworded term breaks the comparison
    /// silently. The opt-in benchmark prints this same value.
    @Test("The checkpoint line has the host log's shape")
    func checkpointLineShape() async throws {
        let run = try await StartupCheckpointRun.measure(
            url: try fixture("h264_aac_30s.mkv"), budget: .seconds(10), coordinatedHTTP: false
        )
        #expect(run.failure == nil)
        #expect(run.probeLine.wholeMatch(
            of: /probe \d+ms \(open \d+ \+ info \d+ \+ describe \d+\)/) != nil,
            "probe line: \(run.probeLine)")
        let terms = run.checkpoints.map { String($0.split(separator: " ")[0]) }
        #expect(terms == ["open", "probe", "plan", "segment", "servable"], "checkpoints: \(run.checkpoints)")
        #expect(run.checkpoints.contains { $0.wholeMatch(of: /plan \d+ms \(\w+, \d+ seg\)/) != nil })
        let lines = run.rendered.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("startup open "))
        #expect(lines[2].hasPrefix("start() returned in "))
    }

    // MARK: SegmentVerifier — playlist parsing

    @Test("A media playlist parses into its init, segments, durations and end")
    func parsesMediaPlaylist() {
        let text = """
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:6.00000,
            seg00000.m4s
            #EXTINF:2.5,
            seg00001.m4s
            #EXT-X-ENDLIST
            """
        let media = SegmentVerifier.parseMediaPlaylist(text)
        #expect(media.initURI == "init.mp4")
        #expect(media.segments.map(\.uri) == ["seg00000.m4s", "seg00001.m4s"])
        #expect(media.segments.map(\.duration) == [6, 2.5])
        #expect(media.segments.map(\.sequence) == [0, 1])
        #expect(media.segments.allSatisfy { $0.initSection == .init(uri: "init.mp4") && $0.resource.range == nil })
        #expect(media.isEnded)
        #expect(media.issues.isEmpty && media.encryption == nil)
        #expect(!SegmentVerifier.parseMediaPlaylist("#EXTM3U\n#EXTINF:6,\na.m4s\n").isEnded)
    }

    /// RFC 8216 §4.3.2.2 / §4.3.2.5: a range without `@offset` continues the
    /// previous sub-range of the same resource, a map applies until the next
    /// one, and `EXT-X-MEDIA-SEQUENCE` numbers the first segment. Getting any
    /// of these wrong fetches the wrong bytes and reports on them.
    @Test("Byte ranges, per-segment maps and the media sequence are honoured")
    func parsesByteRangesAndMaps() {
        let text = """
            #EXTM3U
            #EXT-X-MEDIA-SEQUENCE:40
            #EXT-X-MAP:URI="all.mp4",BYTERANGE="700@0"
            #EXTINF:6,
            #EXT-X-BYTERANGE:1000@700
            all.mp4
            #EXTINF:6,
            #EXT-X-BYTERANGE:500
            all.mp4
            #EXT-X-DISCONTINUITY
            #EXT-X-MAP:URI="other-init.mp4"
            #EXTINF:4,
            other.m4s
            """
        let media = SegmentVerifier.parseMediaPlaylist(text)
        #expect(media.issues.isEmpty, "\(media.issues)")
        #expect(media.segments.map(\.sequence) == [40, 41, 42])
        #expect(media.segments.map(\.resource) == [
            .init(uri: "all.mp4", range: .init(length: 1000, offset: 700)),
            .init(uri: "all.mp4", range: .init(length: 500, offset: 1700)),
            .init(uri: "other.m4s"),
        ])
        #expect(media.segments.map(\.initSection) == [
            .init(uri: "all.mp4", range: .init(length: 700, offset: 0)),
            .init(uri: "all.mp4", range: .init(length: 700, offset: 0)),
            .init(uri: "other-init.mp4"),
        ])

        // An offset-less range with nothing to continue is refused, not
        // guessed at.
        let orphan = SegmentVerifier.parseMediaPlaylist("#EXTM3U\n#EXT-X-MAP:URI=\"i.mp4\"\n#EXT-X-BYTERANGE:10\na.mp4\n")
        #expect(!orphan.issues.isEmpty)
        let encrypted = SegmentVerifier.parseMediaPlaylist("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"\n#EXTINF:6,\na.m4s\n")
        #expect(encrypted.encryption == "SAMPLE-AES")
    }

    /// Playlist integers are untrusted: a range end or a sequence number
    /// past `Int.max` used to trap the process (SIGTRAP, no diagnostic).
    /// Each must become a parse issue instead — and a value just inside the
    /// domain must still parse.
    @Test("Range ends and media sequences at Int.max are issues, not traps")
    func numericBoundariesAreIssues() {
        func parse(_ body: String) -> SegmentVerifier.MediaPlaylist {
            SegmentVerifier.parseMediaPlaylist("#EXTM3U\n#EXT-X-MAP:URI=\"i.mp4\"\n" + body)
        }
        let max = Int.max

        // Explicit segment range ending one past Int.max, and exactly at it.
        #expect(!parse("#EXTINF:6,\n#EXT-X-BYTERANGE:2@\(max - 1)\na.mp4\n").issues.isEmpty)
        let atEdge = parse("#EXTINF:6,\n#EXT-X-BYTERANGE:1@\(max - 1)\na.mp4\n")
        #expect(atEdge.issues.isEmpty, "\(atEdge.issues)")
        #expect(atEdge.segments.first?.resource.range?.end == max)
        // An implicit range continuing from an end at Int.max.
        #expect(!parse("#EXT-X-BYTERANGE:1@\(max - 1)\na.mp4\n#EXT-X-BYTERANGE:1\na.mp4\n").issues.isEmpty)
        // Map ranges: overflowing, and offset-less (no position to continue).
        let mapOverflow = SegmentVerifier.parseMediaPlaylist(
            "#EXTM3U\n#EXT-X-MAP:URI=\"i.mp4\",BYTERANGE=\"2@\(max - 1)\"\n#EXTINF:6,\na.m4s\n")
        #expect(!mapOverflow.issues.isEmpty)
        let mapNoOffset = SegmentVerifier.parseMediaPlaylist(
            "#EXTM3U\n#EXT-X-MAP:URI=\"i.mp4\",BYTERANGE=\"700\"\n#EXTINF:6,\na.m4s\n")
        #expect(!mapNoOffset.issues.isEmpty)
        // Out-of-range integers themselves.
        #expect(!parse("#EXT-X-BYTERANGE:1@99999999999999999999\na.mp4\n").issues.isEmpty)

        // Media sequence: the walk advances to `sequence + 1`, so Int.max
        // itself is out, as is a later segment's position past it.
        #expect(!parse("#EXT-X-MEDIA-SEQUENCE:\(max)\n#EXTINF:6,\na.m4s\n").issues.isEmpty)
        #expect(!parse("#EXT-X-MEDIA-SEQUENCE:\(max - 1)\n#EXTINF:6,\na.m4s\n#EXTINF:6,\nb.m4s\n").issues.isEmpty)
        let lastSupported = parse("#EXT-X-MEDIA-SEQUENCE:\(max - 1)\n#EXTINF:6,\na.m4s\n")
        #expect(lastSupported.issues.isEmpty && lastSupported.segments.map(\.sequence) == [max - 1])
        // Unparseable or negative is refused, not read as 0.
        #expect(!parse("#EXT-X-MEDIA-SEQUENCE:99999999999999999999\n#EXTINF:6,\na.m4s\n").issues.isEmpty)
        #expect(!parse("#EXT-X-MEDIA-SEQUENCE:-1\n#EXTINF:6,\na.m4s\n").issues.isEmpty)
        #expect(!parse("#EXT-X-MEDIA-SEQUENCE:abc\n#EXTINF:6,\na.m4s\n").issues.isEmpty)
    }

    /// The two playlists that trapped the CLI, end to end over HTTP: the
    /// walk must return a report with an error finding (which the CLI
    /// exits 1 on), and must not fetch media on a misread playlist.
    @Test("Overflowing playlist integers end the walk with a finding over HTTP")
    func numericBoundariesOverHTTP() async throws {
        let playlists = [
            "range.m3u8": "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n#EXT-X-MAP:URI=\"init.mp4\"\n"
                + "#EXTINF:6,\n#EXT-X-BYTERANGE:2@9223372036854775806\na.mp4\n#EXT-X-ENDLIST\n",
            "sequence.m3u8": "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n#EXT-X-MAP:URI=\"init.mp4\"\n"
                + "#EXT-X-MEDIA-SEQUENCE:9223372036854775807\n#EXTINF:6,\na.m4s\n#EXT-X-ENDLIST\n",
            "sequence2.m3u8": "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n#EXT-X-MAP:URI=\"init.mp4\"\n"
                + "#EXT-X-MEDIA-SEQUENCE:9223372036854775806\n#EXTINF:6,\na.m4s\n#EXTINF:6,\nb.m4s\n"
                + "#EXT-X-ENDLIST\n",
        ]
        let mediaRequests = Counter()
        let server = try ScriptedHTTPServer { request in
            if let text = playlists[String(request.path.dropFirst())] { return ScriptedHTTPServer.text(text) }
            _ = mediaRequests.next()
            return .respond(status: 404, body: Data())
        }
        let root = try await server.start()
        defer { server.stop() }

        for name in playlists.keys.sorted() {
            let report = try await SegmentVerifier.verify(
                playlist: root.appendingPathComponent(name), stallTimeout: .seconds(2))
            #expect(report.hasErrors, "\(name): \(report.findings)")
        }
        #expect(mediaRequests.next() == 0, "a misread playlist still fetched media")
    }

    // MARK: SegmentVerifier — over a served session

    @Test("Every segment of a served H.264 + AAC remux decodes on its own")
    func servedSegmentsVerify() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let report = try await SegmentVerifier.verify(playlist: playlist)
        #expect(!report.hasErrors, "findings: \(report.findings)")
        let video = try #require(report.playlists.first { $0.videoFrames > 0 })
        // 30 s at 24 fps, every picture decoded exactly once across segments.
        #expect(video.videoFrames == 720)
        #expect(report.playlists.contains { $0.audioFrames > 0 }, "the audio rendition was not checked")
    }

    /// The HEVC fixture is an open-GOP encode: its second segment opens on a
    /// CRA whose one leading picture references the first GOP (system
    /// ffprobe decodes 144 of its 145 packets too). That is the source's
    /// structure, which stream copy cannot change — so it must surface as a
    /// warning, not fail the check.
    @Test("An open-GOP leading picture is a warning, not a failure")
    func openGOPIsWarning() async throws {
        let session = try PrismCoreSession(url: try fixture("hevc_eac3.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let report = try await SegmentVerifier.verify(playlist: playlist)
        #expect(!report.hasErrors, "findings: \(report.findings)")
        #expect(report.findings.contains { $0.severity == .warning && $0.problem.contains("leading picture") })
    }

    // MARK: SegmentVerifier — broken bytes

    /// A real init + segment pair from a served session, for the corruption
    /// tests to break.
    private func servedPair() async throws -> (initSegment: Data, segment: Data) {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        let base = playlist.deletingLastPathComponent()
        let (master, _) = try await URLSession.uncached.data(from: playlist)
        let variant = try #require(PrismCoreSession.playlistURIs(inMaster: String(decoding: master, as: UTF8.self)).last)
        let mediaURL = base.appendingPathComponent(variant)
        let (mediaText, _) = try await URLSession.uncached.data(from: mediaURL)
        let media = SegmentVerifier.parseMediaPlaylist(String(decoding: mediaText, as: UTF8.self))
        let initURI = try #require(media.initURI)
        let segmentURI = try #require(media.segments.dropFirst().first?.uri)
        let (initSegment, _) = try await URLSession.uncached.data(
            from: mediaURL.deletingLastPathComponent().appendingPathComponent(initURI))
        let (segment, _) = try await URLSession.uncached.data(
            from: mediaURL.deletingLastPathComponent().appendingPathComponent(segmentURI))
        return (initSegment, segment)
    }

    @Test("A clean pair passes, a truncated or garbage segment fails with a reason")
    func brokenSegmentsFail() async throws {
        let (initSegment, segment) = try await servedPair()

        let clean = SegmentVerifier.verify(initSegment: initSegment, mediaSegment: segment)
        #expect(!clean.hasErrors, "\(clean.problems)")
        #expect(clean.videoFrames > 0)

        // Cut mid-mdat: the moof still promises every sample, the bytes for
        // most of them are gone.
        let truncated = SegmentVerifier.verify(
            initSegment: initSegment, mediaSegment: segment.prefix(segment.count / 3)
        )
        #expect(truncated.hasErrors, "a truncated segment passed: \(truncated.problems)")

        let garbage = SegmentVerifier.verify(
            initSegment: initSegment, mediaSegment: Data(repeating: 0xA5, count: 4096)
        )
        #expect(garbage.hasErrors, "garbage passed: \(garbage.problems)")
        #expect(garbage.videoFrames == 0)
    }

    @Test("A declared duration far from the media's is a warning")
    func durationMismatchWarns() async throws {
        let (initSegment, segment) = try await servedPair()
        let check = SegmentVerifier.verify(initSegment: initSegment, mediaSegment: segment, expectedDuration: 60)
        #expect(!check.hasErrors)
        #expect(check.problems.contains { $0.0 == .warning && $0.1.contains("#EXTINF") })
    }

    // MARK: SegmentVerifier — presentations the engine does not produce

    /// The video rendition of a served H.264 remux, as bytes: its init
    /// section and every fragment with its `#EXTINF`. The presentations
    /// below re-serve these from a scripted origin in layouts PrismCore
    /// itself never writes but `segverify --hls` must read.
    private func servedVideoRendition() async throws -> (initSegment: Data, segments: [(duration: Double, data: Data)]) {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        let base = playlist.deletingLastPathComponent()
        let (master, _) = try await URLSession.uncached.data(from: playlist)
        for variant in PrismCoreSession.playlistURIs(inMaster: String(decoding: master, as: UTF8.self)) {
            let mediaURL = base.appendingPathComponent(variant)
            let (text, _) = try await URLSession.uncached.data(from: mediaURL)
            let media = SegmentVerifier.parseMediaPlaylist(String(decoding: text, as: UTF8.self))
            guard let initURI = media.initURI else { continue }
            let directory = mediaURL.deletingLastPathComponent()
            let (initSegment, _) = try await URLSession.uncached.data(from: directory.appendingPathComponent(initURI))
            var segments: [(Double, Data)] = []
            for segment in media.segments {
                let (data, _) = try await URLSession.uncached.data(from: directory.appendingPathComponent(segment.uri))
                segments.append((segment.duration ?? 0, data))
            }
            guard let first = segments.first,
                  SegmentVerifier.verify(initSegment: initSegment, mediaSegment: first.1).videoFrames > 0
            else { continue }
            return (initSegment, segments)
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Every fragment and the init in ONE resource, addressed by
    /// `EXT-X-BYTERANGE` — the single-file layout. Fetched whole, each
    /// "segment" would decode from the file's first keyframe on and hand
    /// later fragments the references they are supposed to do without, so
    /// the frame count is the regression: 720 exactly once, not 720 per
    /// segment.
    @Test("Byte-range segments in one resource are fetched and decoded one range at a time")
    func byteRangeSegmentsVerifyIndependently() async throws {
        let (initSegment, segments) = try await servedVideoRendition()
        try #require(segments.count > 1)
        var resource = initSegment
        var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:7\n"
            + "#EXT-X-MAP:URI=\"all.mp4\",BYTERANGE=\"\(initSegment.count)@0\"\n"
        for (index, segment) in segments.enumerated() {
            // The first range carries its offset; the rest continue from it,
            // the way packagers write them.
            let range = index == 0 ? "\(segment.data.count)@\(resource.count)" : "\(segment.data.count)"
            playlist += "#EXTINF:\(segment.duration),\n#EXT-X-BYTERANGE:\(range)\nall.mp4\n"
            resource += segment.data
        }
        playlist += "#EXT-X-ENDLIST\n"
        let body = resource
        let text = playlist
        let server = try ScriptedHTTPServer { request in
            switch request.path {
            case "/media.m3u8": return ScriptedHTTPServer.text(text)
            case "/all.mp4": return ScriptedHTTPServer.ranged(body, for: request)
            default: return .respond(status: 404, body: Data())
            }
        }
        let root = try await server.start()
        defer { server.stop() }

        let report = try await SegmentVerifier.verify(playlist: root.appendingPathComponent("media.m3u8"))
        #expect(!report.hasErrors && report.isComplete, "findings: \(report.findings)")
        let checked = try #require(report.playlists.first)
        #expect(checked.segmentsChecked == segments.count)
        #expect(checked.videoFrames == 720, "each range must decode alone, not the file from its start")
        // Every fetch was a range: the init once, then one per fragment.
        let ranged = server.requests.filter { $0.path == "/all.mp4" }
        #expect(ranged.count == segments.count + 1)
        #expect(ranged.allSatisfy { $0.headers["range"] != nil })
    }

    /// A live-style window of three that advances one segment per reload
    /// before `#EXT-X-ENDLIST`. Indexing each reload by a lifetime count
    /// skips the segment that slid in (three checked, three listed, nothing
    /// "new") and then exits clean on the end tag; following the media
    /// sequence checks each exactly once.
    @Test("A sliding playlist is followed by media sequence, and a missed segment is unverified")
    func slidingWindowFollowsMediaSequence() async throws {
        let (initSegment, segments) = try await servedVideoRendition()
        try #require(segments.count > 3)
        let count = segments.count
        let fragments = segments.map(\.data)
        let durations = segments.map(\.duration)
        let initBody = initSegment

        /// A window starting at `first`, ended once it reaches the last one.
        @Sendable func window(_ first: Int, width: Int) -> String {
            let last = min(count - 1, first + width - 1)
            var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:7\n#EXT-X-MEDIA-SEQUENCE:\(first)\n"
                + "#EXT-X-MAP:URI=\"init.mp4\"\n"
            for index in first...last { text += "#EXTINF:\(durations[index]),\nseg\(index).m4s\n" }
            return text + (last == count - 1 ? "#EXT-X-ENDLIST\n" : "")
        }
        func origin(advance step: Int, width: Int) throws -> ScriptedHTTPServer {
            let reloads = Counter()
            return try ScriptedHTTPServer { request in
                switch request.path {
                case "/live.m3u8":
                    return ScriptedHTTPServer.text(window(min(count - width, reloads.next() * step), width: width))
                case "/init.mp4":
                    return .respond(status: 200, body: initBody)
                default:
                    let name = request.path.dropFirst("/seg".count).dropLast(".m4s".count)
                    guard let index = Int(name), fragments.indices.contains(index) else {
                        return .respond(status: 404, body: Data())
                    }
                    return .respond(status: 200, body: fragments[index])
                }
            }
        }

        let sliding = try origin(advance: 1, width: 3)
        let root = try await sliding.start()
        let report = try await SegmentVerifier.verify(playlist: root.appendingPathComponent("live.m3u8"))
        sliding.stop()
        #expect(!report.hasErrors && report.isComplete, "findings: \(report.findings)")
        #expect(report.playlists.first?.segmentsChecked == count)
        #expect(report.playlists.first?.videoFrames == 720)
        let fetched = sliding.requests.map(\.path).filter { $0.hasPrefix("/seg") }
        #expect(fetched == (0..<count).map { "/seg\($0).m4s" }, "each segment exactly once, in order")

        // A window that jumps past segments between reloads: what it skipped
        // was never checked, which must not read as a pass.
        let jumping = try origin(advance: 2, width: 1)
        let jumpRoot = try await jumping.start()
        let jumped = try await SegmentVerifier.verify(playlist: jumpRoot.appendingPathComponent("live.m3u8"))
        jumping.stop()
        #expect(!jumped.hasErrors)
        #expect(!jumped.isComplete)
        #expect(jumped.findings.contains {
            $0.severity == .unverified && $0.problem.contains("left the playlist window")
        }, "findings: \(jumped.findings)")
    }

    /// `-H` on `segverify --hls` is the presentation's credential, and an
    /// origin that wants a token wants it on the master, the media
    /// playlist a level down, the init and every fragment.
    @Test("Headers reach every request of the walk, nested playlists included")
    func headersReachEveryRequest() async throws {
        let (initSegment, segments) = try await servedVideoRendition()
        let fragments = segments.prefix(2).map(\.data)
        let initBody = initSegment
        var media = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:7\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for (index, segment) in segments.prefix(2).enumerated() {
            media += "#EXTINF:\(segment.duration),\nseg\(index).m4s\n"
        }
        media += "#EXT-X-ENDLIST\n"
        let mediaText = media
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS=\"avc1.640028\"\nvideo/media.m3u8\n"
        let server = try ScriptedHTTPServer { request in
            guard request.headers["authorization"] == "Bearer s3cret" else {
                return .respond(status: 401, body: Data())
            }
            switch request.path {
            case "/master.m3u8": return ScriptedHTTPServer.text(master)
            case "/video/media.m3u8": return ScriptedHTTPServer.text(mediaText)
            case "/video/init.mp4": return .respond(status: 200, body: initBody)
            case "/video/seg0.m4s": return .respond(status: 200, body: fragments[0])
            case "/video/seg1.m4s": return .respond(status: 200, body: fragments[1])
            default: return .respond(status: 404, body: Data())
            }
        }
        let root = try await server.start()
        defer { server.stop() }
        let top = root.appendingPathComponent("master.m3u8")

        let report = try await SegmentVerifier.verify(
            playlist: top, httpHeaders: ["Authorization": "Bearer s3cret"]
        )
        #expect(!report.hasErrors && report.isComplete, "findings: \(report.findings)")
        #expect(report.playlists.first?.segmentsChecked == 2)
        #expect(Set(server.requests.map(\.path)) == [
            "/master.m3u8", "/video/media.m3u8", "/video/init.mp4", "/video/seg0.m4s", "/video/seg1.m4s",
        ])
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == "Bearer s3cret" })

        // And without them the walk fails where it is refused, loudly.
        await #expect(throws: SegmentVerifier.FetchFailure.self) {
            _ = try await SegmentVerifier.verify(playlist: top)
        }
    }

    /// A stream this build cannot decode is demuxed and skipped — so a
    /// presentation could finish with no video decoded at all. That is not a
    /// corrupt segment, and it is not a pass either.
    @Test("A stream with no decoder makes the report unverified, naming it")
    func missingDecoderIsUnverified() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let report = try await SegmentVerifier.verify(playlist: playlist, unavailableDecoders: ["h264"])
        #expect(!report.hasErrors, "a missing decoder is not a media fault: \(report.findings)")
        #expect(!report.isComplete)
        #expect(report.playlists.allSatisfy { $0.videoFrames == 0 })
        let video = try #require(report.playlists.first { !$0.undecodedStreams.isEmpty })
        #expect(video.undecodedStreams.allSatisfy { $0.contains("h264") })
        #expect(report.findings.contains {
            $0.severity == .unverified && $0.location == video.uri && $0.problem.contains("h264")
        }, "findings: \(report.findings)")
    }
}

/// A thread-safe tick for a handler that must answer differently per call.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// The count before this call.
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
