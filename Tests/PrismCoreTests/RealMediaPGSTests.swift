import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PrismCore

/// Opt-in verification of the bitmap subtitle pipelines against real PGS media —
/// no FFmpeg build can *encode* PGS, so no committed fixture can carry it.
///
///     PRISMCORE_PGS_MEDIA=/path/to/remux.mkv swift test --filter RealMediaPGS
///
/// Plays the session's own serving path end to end: master declares the PGS
/// renditions, the producer demuxes, the decoder composites, Vision reads, and
/// the cues land in served `.vtt` segments. The second test takes the other
/// delivery: the same track as pictures for a host that draws (`BitmapCue`).
///
/// The hermetic suites (`BitmapCue…Tests`) run the same code on PGS packets
/// assembled by hand; what only a disc's own stream can show — cropped
/// objects, objects split over packets, palette-only updates, fades — is
/// what this file is for.
@Suite(
    "Real media: PGS renditions",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_PGS_MEDIA"] != nil)
)
struct RealMediaPGSTests {

    @Test("A PGS track is served as a rendition whose segments carry recognized cues")
    func pgsBecomesReadableRendition() async throws {
        let path = ProcessInfo.processInfo.environment["PRISMCORE_PGS_MEDIA"] ?? ""
        let info = try SourceProbe.probe(url: URL(fileURLWithPath: path))
        let pgsTracks = info.subtitleTracks.filter { $0.codecName.contains("pgs") }
        try #require(!pgsTracks.isEmpty, "media has no PGS track")

        let session = try PrismCoreSession(url: URL(fileURLWithPath: path))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        // The master must declare at least as many subtitle renditions as
        // there are text + PGS tracks.
        let master = try String(contentsOf: playlist, encoding: .utf8)
        try #require(master.contains("#EXT-X-STREAM-INF"), "expected a master playlist")
        let subtitleLines = master.split(separator: "\n").filter { $0.contains("TYPE=SUBTITLES") }
        #expect(
            subtitleLines.count >= pgsTracks.count,
            "master declares \(subtitleLines.count) subtitle renditions for \(pgsTracks.count) PGS tracks"
        )

        // Walk the presentation like a player: media segment N (drives the
        // producer), then the first PGS rendition's segment N — until a cue
        // shows up. Films open quiet, so give it a few minutes of runtime.
        let mediaURI = try #require(PrismCoreSession.playlistURIs(inMaster: master).last)
        let mediaPlaylistURL = playlist.deletingLastPathComponent().appendingPathComponent(mediaURI)
        let mediaPlaylist = try String(contentsOf: mediaPlaylistURL, encoding: .utf8)
        let mediaSegments = mediaPlaylist.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }

        // First PGS rendition directory: text tracks are declared first, in
        // stream order — count the text tracks to find where PGS starts.
        let textCount = info.textSubtitleTracks.count
        let subsDirectory = "subs\(textCount)"

        var recognized: [String] = []
        for index in 0..<min(mediaSegments.count, 60) {
            let mediaURL = mediaPlaylistURL.deletingLastPathComponent()
                .appendingPathComponent(String(mediaSegments[index]))
            _ = try? Data(contentsOf: mediaURL)

            let vttURL = playlist.deletingLastPathComponent()
                .appendingPathComponent("\(subsDirectory)/seg\(String(format: "%05d", index)).vtt")
            guard let vtt = try? String(contentsOf: vttURL, encoding: .utf8) else { continue }
            let cueLines = vtt.split(separator: "\n")
                .filter { !$0.hasPrefix("WEBVTT") && !$0.hasPrefix("X-TIMESTAMP") && !$0.contains("-->") }
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            recognized.append(contentsOf: cueLines)
            if recognized.count >= 3 { break }
        }

        print("PGS OCR cues recognized: \(recognized.prefix(6))")
        #expect(recognized.count >= 1, "no cue recognized in the first minutes of the film")
    }

    // MARK: - Pictures

    /// The host-drawn delivery: the same PGS track, as pictures. What a real disc
    /// can show that a hand-made stream cannot — cropped objects, objects split
    /// over packets, palette-only updates, fades, anti-aliased glyphs — is the
    /// reason this exists; the invariants below hold for any of it.
    ///
    ///     PRISMCORE_PGS_MEDIA=/path/to/remux.mkv swift test --filter pgsArrivesAsPictures
    ///
    /// Writes the first cues as PNG files (with their alpha) to a temporary
    /// directory and prints the path, so a person can look at them: the checks
    /// below are about the numbers, and whether a subtitle is *right* is a
    /// matter of looking.
    @Test("A PGS track's pictures reach the host with transparency, place and frame, never stacked")
    func pgsArrivesAsPictures() async throws {
        let path = ProcessInfo.processInfo.environment["PRISMCORE_PGS_MEDIA"] ?? ""
        let info = try SourceProbe.probe(url: URL(fileURLWithPath: path))
        let track = try #require(
            info.bitmapSubtitleTracks.first { $0.codecName.contains("pgs") }, "media has no PGS track"
        )

        let session = try PrismCoreSession(url: URL(fileURLWithPath: path))
        let collector = PictureCollector()
        await session.setBitmapCueHandler { collector.append($0) }
        await session.setBitmapCueStreams([track.streamIndex])
        _ = try await session.start()
        defer { Task { await session.stop() } }

        // Nobody plays, so the producer is free to run: it needs a few minutes
        // of film to have met several subtitles. Enough is a dozen cues, or
        // three and then ten quiet seconds (a short file, or a film that opens
        // without dialogue after the first).
        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        var lastCount = 0
        var lastGrowth = ContinuousClock.now
        while ContinuousClock.now < deadline, collector.cues.count < 12 {
            try await Task.sleep(for: .milliseconds(250))
            if collector.cues.count != lastCount {
                lastCount = collector.cues.count
                lastGrowth = .now
            } else if lastCount >= 3, ContinuousClock.now - lastGrowth > .seconds(10) {
                break
            }
        }
        let cues = collector.cues
        try #require(cues.count >= 3, "fewer than three pictures in four minutes of a film")

        for cue in cues {
            #expect(cue.streamIndex == Int32(track.streamIndex))
            #expect(cue.end > cue.start, "\(cue.id)")
            #expect(cue.referenceSize.width > 0 && cue.referenceSize.height > 0)
            // The picture is the rectangle, and the rectangle lies inside the frame.
            #expect(Int(cue.frame.width) == cue.image.width && Int(cue.frame.height) == cue.image.height)
            let frame = CGRect(origin: .zero, size: cue.referenceSize)
            #expect(frame.contains(cue.frame), "\(cue.frame) outside \(cue.referenceSize)")
            // Something is drawn, and not everything: a subtitle is glyphs on air.
            let alpha = Self.alphaShare(of: cue.image)
            #expect(alpha.opaqueOrVisible > 0, "a picture with nothing in it")
        }

        // Compositions end the ones before them: of two cues, either they are
        // one composition (same times) or the first is over when the second
        // starts. Stacked subtitles — the failure the DVB time-out and the PGS
        // sentinel each caused once — fail here.
        let ordered = cues.sorted { ($0.start, $0.frame.minY) < ($1.start, $1.frame.minY) }
        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            let sameComposition = earlier.start == later.start && earlier.end == later.end
            #expect(sameComposition || earlier.end <= later.start + 0.001,
                    "\(earlier.start)–\(earlier.end) overlaps \(later.start)–\(later.end)")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCorePGSPictures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (number, cue) in ordered.prefix(8).enumerated() {
            let url = directory.appendingPathComponent(String(format: "cue-%02d-%.1fs.png", number, cue.start))
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, cue.image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        print("PGS pictures: \(cues.count) cues, first at \(ordered[0].start) s; frame \(ordered[0].referenceSize); PNGs in \(directory.path)")
    }

    /// Fraction of pixels that are visible at all, from the premultiplied BGRA bytes.
    private static func alphaShare(of image: CGImage) -> (opaqueOrVisible: Int, total: Int) {
        guard let data = image.dataProvider?.data as Data? else { return (0, 0) }
        let bytes = [UInt8](data)
        var visible = 0
        for index in stride(from: 3, to: bytes.count, by: 4) where bytes[index] > 0 { visible += 1 }
        return (visible, bytes.count / 4)
    }

    private final class PictureCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [BitmapCue] = []
        func append(_ cue: BitmapCue) { lock.withLock { stored.append(cue) } }
        var cues: [BitmapCue] { lock.withLock { stored } }
    }
}
