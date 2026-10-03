import Testing
import Foundation
@testable import PrismCore

/// Sources whose timestamps the mp4 muxer would refuse as they come: a remux
/// of one used to die on the first such packet (`EINVAL` from the mux layer,
/// surfacing as a remux failure and segments that were listed but never
/// served).
@Suite("Timestamp repair", .serialized)
struct TimestampRepairTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    // MARK: Rules, one packet at a time

    private let nopts = Int64.min

    private func run(
        _ sanitizer: inout TimestampSanitizer,
        pts: Int64, dts: Int64, duration: Int64 = 10
    ) -> (pts: Int64, dts: Int64, repairs: TimestampSanitizer.Repairs) {
        var pts = pts, dts = dts
        let repairs = sanitizer.repair(pts: &pts, dts: &dts, duration: duration, nopts: nopts)
        return (pts, dts, repairs)
    }

    @Test("Clean, reordered timestamps pass through untouched")
    func cleanPassesThrough() {
        var sanitizer = TimestampSanitizer(reordersFrames: true)
        for (pts, dts) in [(20, 0), (50, 10), (30, 20), (40, 30), (80, 40)] as [(Int64, Int64)] {
            let out = run(&sanitizer, pts: pts, dts: dts)
            #expect(out.pts == pts && out.dts == dts && out.repairs.isEmpty)
        }
    }

    @Test("A missing DTS follows the previous packet, or its PTS when nothing reorders")
    func missingDTSIsFilled() {
        var reordering = TimestampSanitizer(reordersFrames: true)
        // A first packet of a B-frame stream has nothing safe to derive from.
        #expect(run(&reordering, pts: 20, dts: nopts) == (20, nopts, []))
        _ = run(&reordering, pts: 20, dts: 0)
        let filled = run(&reordering, pts: 50, dts: nopts, duration: 10)
        #expect(filled == (50, 10, .missingDTSFilled))

        var inOrder = TimestampSanitizer(reordersFrames: false)
        #expect(run(&inOrder, pts: 7, dts: nopts, duration: 0) == (7, 7, .missingDTSFilled))
        // Without a duration, the PTS is all there is.
        #expect(run(&inOrder, pts: 30, dts: nopts, duration: 0) == (30, 30, .missingDTSFilled))
    }

    @Test("A DTS that does not move forward is bumped one tick past the last")
    func nonMonotonicDTSIsBumped() {
        var sanitizer = TimestampSanitizer(reordersFrames: true)
        _ = run(&sanitizer, pts: 40, dts: 20)
        #expect(run(&sanitizer, pts: 60, dts: 20) == (60, 21, .nonMonotonicDTSBumped))
        #expect(run(&sanitizer, pts: 70, dts: 5) == (70, 22, .nonMonotonicDTSBumped))
        // The source's own DTS takes over again as soon as it is ahead.
        #expect(run(&sanitizer, pts: 80, dts: 30) == (80, 30, []))
    }

    @Test("A PTS below its DTS is raised to it, including after a bump")
    func ptsBelowDTSIsRaised() {
        var sanitizer = TimestampSanitizer(reordersFrames: true)
        #expect(run(&sanitizer, pts: 10, dts: 15) == (15, 15, .ptsRaisedToDTS))
        #expect(run(&sanitizer, pts: 12, dts: 15) == (16, 16, [.nonMonotonicDTSBumped, .ptsRaisedToDTS]))
    }

    @Test("The ledger is nil until a repair, then counts each kind")
    func ledgerCounts() {
        let ledger = TimestampRepairLedger()
        #expect(ledger.stats == nil)
        ledger.record([.nonMonotonicDTSBumped, .ptsRaisedToDTS])
        ledger.record(.missingDTSFilled)
        #expect(ledger.stats == TimestampRepairStats(
            missingDTSFilled: 1, nonMonotonicDTSBumped: 1, ptsRaisedToDTS: 1
        ))
        #expect(ledger.stats?.total == 3)
    }

    // MARK: A whole remux

    /// A Matroska carries no DTS, so libavformat derives one from the
    /// presentation times — and a cut that steps a presentation time back, or
    /// repeats one, derives a DTS that steps back or stalls. Every segment of
    /// such a remux decodes on its own, and every picture is still there.
    @Test("A remux of a source whose derived DTS steps back and stalls completes and verifies")
    func brokenTimestampsRemuxAndVerify() async throws {
        let source = try BrokenTimestampFixture.write(from: try fixture("h264_aac_30s.mkv"))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let session = try PrismCoreSession(url: source)
        let playlist = try await session.start()
        let report = try await SegmentVerifier.verify(playlist: playlist)
        let repairs = await session.timestampRepairs
        await session.stop()

        #expect(!report.hasErrors, "findings: \(report.findings)")
        let video = try #require(report.playlists.first { $0.videoFrames > 0 })
        // Repaired, never dropped: 30 s at 24 fps, every picture still there.
        #expect(video.videoFrames == 720)
        let stats = try #require(repairs, "nothing was repaired on a source broken on purpose")
        #expect(stats.nonMonotonicDTSBumped >= 2)
        #expect(stats.ptsRaisedToDTS >= 1)
    }

    @Test("A clean source reports no timestamp repairs")
    func cleanSourceReportsNothing() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        let report = try await SegmentVerifier.verify(playlist: playlist)
        let repairs = await session.timestampRepairs
        await session.stop()
        #expect(!report.hasErrors, "findings: \(report.findings)")
        #expect(repairs == nil)
    }
}

/// Moves two video presentation times in a clean Matroska by rewriting block
/// timecodes in place. By hand rather than through a muxer, because the mux
/// layer refuses the very timestamps this is meant to produce downstream —
/// and the bytes are what a badly cut file actually looks like.
enum BrokenTimestampFixture {

    private struct Block {
        /// Offset of the block's signed 16-bit cluster-relative timecode.
        let timecodeOffset: Int
        let clusterTime: Int64
        let relative: Int64
        var time: Int64 { clusterTime + relative }
    }

    static func write(from clean: URL) throws -> URL {
        var bytes = [UInt8](try Data(contentsOf: clean))
        var blocks: [Block] = []
        walk(bytes, from: 0, to: bytes.count, clusterTime: 0, into: &blocks)
        precondition(blocks.count == 720, "expected the 30 s fixture's 720 video blocks, found \(blocks.count)")

        // An edit that jumps back ten frames: the DTS libavformat derives
        // steps backwards, and the frame presents before its decode time.
        setTime(&bytes, blocks[200], blocks[190].time)
        // A repeated timestamp: the derived DTS stalls on its predecessor's.
        setTime(&bytes, blocks[400], blocks[398].time)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-broken-mkv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("broken.mkv")
        try Data(bytes).write(to: url)
        return url
    }

    private static let segment: UInt32 = 0x1853_8067
    private static let cluster: UInt32 = 0x1F43_B675
    private static let blockGroup: UInt32 = 0xA0
    private static let clusterTimecode: UInt32 = 0xE7
    private static let simpleBlock: UInt32 = 0xA3
    private static let block: UInt32 = 0xA1
    private static let videoTrack: UInt64 = 1

    /// EBML variable-length integer: the length marker kept for IDs,
    /// stripped for sizes and track numbers.
    private static func vint(_ bytes: [UInt8], at index: Int, keepMarker: Bool) -> (value: UInt64, length: Int) {
        var mask: UInt8 = 0x80
        var length = 1
        while bytes[index] & mask == 0 { mask >>= 1; length += 1 }
        var value = UInt64(keepMarker ? bytes[index] : bytes[index] & (mask - 1))
        for offset in 1..<length { value = value << 8 | UInt64(bytes[index + offset]) }
        return (value, length)
    }

    private static func walk(
        _ bytes: [UInt8], from start: Int, to end: Int, clusterTime: Int64, into blocks: inout [Block]
    ) {
        var index = start
        var clusterTime = clusterTime
        while index < end {
            let id = vint(bytes, at: index, keepMarker: true)
            let size = vint(bytes, at: index + id.length, keepMarker: false)
            let body = index + id.length + size.length
            let bodyEnd = body + Int(size.value)
            switch UInt32(id.value) {
            case segment, cluster, blockGroup:
                walk(bytes, from: body, to: bodyEnd, clusterTime: clusterTime, into: &blocks)
            case clusterTimecode:
                clusterTime = bytes[body..<bodyEnd].reduce(0) { $0 << 8 | Int64($1) }
            case simpleBlock, block:
                let track = vint(bytes, at: body, keepMarker: false)
                guard track.value == videoTrack else { break }
                let at = body + track.length
                let relative = Int64(Int16(bitPattern: UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])))
                blocks.append(Block(timecodeOffset: at, clusterTime: clusterTime, relative: relative))
            default:
                break
            }
            index = bodyEnd
        }
    }

    private static func setTime(_ bytes: inout [UInt8], _ block: Block, _ time: Int64) {
        let relative = UInt16(bitPattern: Int16(time - block.clusterTime))
        bytes[block.timecodeOffset] = UInt8(relative >> 8)
        bytes[block.timecodeOffset + 1] = UInt8(relative & 0xFF)
    }
}
