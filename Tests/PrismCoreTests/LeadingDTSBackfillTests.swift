import Testing
import Foundation
@testable import PrismCore
import Libavformat
import Libavcodec
import Libavutil

/// The first packets of a video stream that reorders pictures leave libavformat's
/// demuxer without a DTS after every seek; the one after them has the first real
/// one. The mux layer's own guess for the missing ones can land above it, and
/// `av_interleaved_write_frame` then refuses the packet (EINVAL) — which ended
/// the remux a buffer's length after the seek. `TimestampSanitizer` leaves those
/// packets to the muxer on purpose, so it cannot prevent this. See
/// `LeadingDTSBackfill`.
@Suite("Leading DTS backfill")
struct LeadingDTSBackfillTests {

    private typealias Backfill = LeadingDTSBackfill<Int>

    private struct Step {
        let dts: Int64?
        let pts: Int64?
        var duration: Int64 = 3690
    }

    private struct Written: Equatable {
        /// The index of the step whose packet this is.
        let packet: Int
        let dts: Int64?
    }

    private func run(_ steps: [Step], into backfill: inout Backfill) -> [[Written]] {
        steps.enumerated().map { index, step in
            backfill.admit(dts: step.dts, pts: step.pts, duration: step.duration, hold: { index }).map {
                switch $0.item {
                case .held(let held): return Written(packet: held, dts: $0.dts)
                case .current: return Written(packet: index, dts: $0.dts)
                }
            }
        }
    }

    /// What libavformat's demuxer makes of a decode-order list of PTS values: a
    /// window as deep as the reordering sorts them, and the smallest of it is the
    /// DTS — except that the window starts empty, so the first `delay` packets
    /// have none. (`compute_pkt_fields`, libavformat/demux.c.)
    static func demuxerDTS(forDecodeOrderPTS pts: [Int64], delay: Int) -> [Int64?] {
        var window = [Int64](repeating: .min, count: delay + 1)
        return pts.map { value in
            window[0] = value
            var index = 0
            while index < delay, window[index] > window[index + 1] {
                window.swapAt(index, index + 1)
                index += 1
            }
            return window[0] == .min ? nil : window[0]
        }
    }

    // MARK: - The failure that was found

    /// The first packets after the re-anchor of a 1080p Blu-ray remux (video
    /// ticks of 1/90 000): the keyframe opens an open GOP, two pictures that
    /// lead it follow in decode order, and Matroska's millisecond clock makes
    /// the spacing uneven (41 and 42 ms).
    private let openGOP: [Int64] = [
        171_369_990,   // the keyframe: third picture in display order
        171_362_430,   // leading picture
        171_366_210,   // leading picture
        171_381_240,
        171_373_770,
        171_377_550,
    ]

    @Test("The leading packets are held, then numbered backwards from the first real DTS")
    func numbersBackwardsFromTheFirstRealDTS() {
        let dts = Self.demuxerDTS(forDecodeOrderPTS: openGOP, delay: 4)
        #expect(dts.prefix(4).allSatisfy { $0 == nil }, "four packets come without a DTS")
        let first = dts[4]
        #expect(first == 171_362_430, "the fifth has the smallest PTS of the five")

        var backfill = Backfill()
        let steps = zip(dts, openGOP).map { Step(dts: $0, pts: $1) }
        let released = run(steps, into: &backfill)

        #expect(released[0..<4].allSatisfy { $0.isEmpty }, "nothing is written before the real DTS")
        let written = released[4]
        #expect(written.map(\.packet) == [0, 1, 2, 3, 4], "the held packets keep their order, the current one is last")
        // One frame (the first packet's duration) apart, ending one frame
        // before the DTS that came.
        let realDTS: Int64 = 171_362_430
        let frame: Int64 = 3690
        let expected: [Int64?] = [realDTS - 4 * frame, realDTS - 3 * frame, realDTS - 2 * frame, realDTS - frame]
        #expect(written.prefix(4).map(\.dts) == expected)
        #expect(written[4].dts == nil, "the packet that has a DTS keeps it")
        #expect(backfill.isSettled)
    }

    @Test("Numbered DTS values stay strictly increasing and never pass their own PTS")
    func orderAndBound() {
        let dts = Self.demuxerDTS(forDecodeOrderPTS: openGOP, delay: 4)
        var backfill = Backfill()
        let steps = zip(dts, openGOP).map { Step(dts: $0, pts: $1) }
        let written = run(steps, into: &backfill)[4].prefix(4)
        let numbers = written.map { $0.dts! }
        #expect(numbers == numbers.sorted())
        #expect(Set(numbers).count == numbers.count)
        for (entry, number) in zip(written, numbers) {
            #expect(number <= openGOP[entry.packet])
        }
        #expect(numbers.last! < dts[4]!)
    }

    @Test("At a file's start it makes exactly the numbers the muxer would have made")
    func matchesTheMuxerAtTheStartOfAFile() {
        // From the first segment of the same file, as FFmpeg's mux layer
        // numbered it: PTS 3780, 11250, 7560, 22590 → DTS -10980, -7290, -3600,
        // 90, and the demuxer's first real DTS is 3780.
        let pts: [Int64] = [3780, 11_250, 7560, 22_590, 15_030]
        let dts = Self.demuxerDTS(forDecodeOrderPTS: pts, delay: 4)
        #expect(dts[4] == 3780)

        var backfill = Backfill()
        let written = run(zip(dts, pts).map { Step(dts: $0, pts: $1) }, into: &backfill)[4]
        let expected: [Int64?] = [-10_980, -7290, -3600, 90]
        #expect(written.prefix(4).map(\.dts) == expected)
    }

    // MARK: - Streams that need nothing

    @Test("A stream that has a DTS from its first packet is never held")
    func realDTSFromTheStart() {
        var backfill = Backfill()
        let released = run([
            Step(dts: 0, pts: 0),
            Step(dts: 3750, pts: 3750),
            Step(dts: 7500, pts: 7500),
        ], into: &backfill)
        #expect(released == [
            [Written(packet: 0, dts: nil)],
            [Written(packet: 1, dts: nil)],
            [Written(packet: 2, dts: nil)],
        ])
        #expect(backfill.isSettled)
    }

    @Test("Once settled, even a packet without a DTS goes on as it is")
    func settledStreamPassesThrough() {
        var backfill = Backfill()
        let released = run([
            Step(dts: 100, pts: 100),
            Step(dts: nil, pts: 200),
            Step(dts: 300, pts: 300),
        ], into: &backfill)
        #expect(released[1] == [Written(packet: 1, dts: nil)])
        #expect(released[2] == [Written(packet: 2, dts: nil)])
    }

    // MARK: - Edges

    @Test("A held packet is never numbered later than its own PTS")
    func clampsToThePTS() {
        // The real DTS is 10 000 but the first packet is due at 9000: a frame
        // earlier than the step would put it (6310).
        var backfill = Backfill()
        let released = run([
            Step(dts: nil, pts: 9000),
            Step(dts: nil, pts: 5000),
            Step(dts: 10_000, pts: 10_000),
        ], into: &backfill)
        let numbers = released[2].prefix(2).map { $0.dts! }
        // The second is clamped to its PTS; the first goes a frame before that.
        let expected: [Int64] = [1310, 5000]
        #expect(numbers == expected)
    }

    @Test("Without a duration the packets are one tick apart")
    func unknownDuration() {
        var backfill = Backfill()
        let released = run([
            Step(dts: nil, pts: 5000, duration: 0),
            Step(dts: nil, pts: 5001, duration: 0),
            Step(dts: 5000, pts: 5002, duration: 0),
        ], into: &backfill)
        let expected: [Int64?] = [4998, 4999]
        #expect(released[2].prefix(2).map(\.dts) == expected)
    }

    @Test("A stream that never gets a DTS is let go after the most the demuxer can withhold")
    func givesUpAfterTheLimit() {
        var backfill = Backfill()
        var steps = (0..<Backfill.holdLimit).map { Step(dts: nil, pts: Int64($0) * 3750) }
        steps.append(Step(dts: nil, pts: Int64(Backfill.holdLimit) * 3750))
        let released = run(steps, into: &backfill)
        #expect(released.dropLast().allSatisfy { $0.isEmpty }, "held while there may still be a DTS to come")
        let last = released.last!
        #expect(last.count == Backfill.holdLimit + 1)
        #expect(last.allSatisfy { $0.dts == nil }, "released with what they have, for the muxer to estimate")
        #expect(last.map(\.packet) == Array(0...Backfill.holdLimit))
        #expect(backfill.isSettled)
    }

    @Test("A packet with neither DTS nor PTS cannot be numbered and ends the wait")
    func noTimestampsAtAll() {
        var backfill = Backfill()
        let released = run([
            Step(dts: nil, pts: 5000),
            Step(dts: nil, pts: nil),
        ], into: &backfill)
        #expect(released[1] == [Written(packet: 0, dts: nil), Written(packet: 1, dts: nil)])
        #expect(backfill.isSettled)
    }

    @Test("Draining hands back what is held, untouched, and keeps waiting")
    func drain() {
        var backfill = Backfill()
        _ = run([Step(dts: nil, pts: 5000), Step(dts: nil, pts: 4000)], into: &backfill)
        let drained = backfill.drain().map { release -> Written in
            guard case .held(let packet) = release.item else { return Written(packet: -1, dts: 0) }
            return Written(packet: packet, dts: release.dts)
        }
        #expect(drained == [Written(packet: 0, dts: nil), Written(packet: 1, dts: nil)])
        #expect(!backfill.isSettled, "the next fragment may still bring the first real DTS")
        #expect(backfill.drain().isEmpty)
    }

    @Test("The caller's record of a packet is made only when the packet is held")
    func holdIsLazy() {
        var backfill = Backfill()
        var holds = 0
        _ = backfill.admit(dts: nil, pts: 5000, duration: 3690, hold: { holds += 1; return 0 })
        #expect(holds == 1)
        _ = backfill.admit(dts: 4000, pts: 4000, duration: 3690, hold: { holds += 1; return 1 })
        #expect(holds == 1, "a packet with a DTS is written, not held")
    }
}

/// The same failure against the real mux layer: the writer is given the
/// packets above (pointing at a muxer that, unaided, refuses the fifth) and
/// must take all of them.
@Suite("FMP4SegmentWriter first packets")
struct FMP4SegmentWriterFirstPacketTests {

    private func fixture(_ name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return try #require(
            Bundle.module.url(forResource: "Fixtures/\(base)", withExtension: ext),
            "fixture \(name) missing"
        )
    }

    /// One sample of a fragment, as the `trun` box describes it.
    private struct Sample {
        let duration: Int64
        let compositionOffset: Int64
        let size: Int
    }

    private struct Fragment {
        let baseDecodeTime: Int64
        let samples: [Sample]
    }

    /// The first `traf` of a media segment: `tfdt` plus the `trun` sample table.
    private func parseFragment(_ data: Data) throws -> Fragment {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        func u64(_ at: Int) -> Int64 { Int64(u32(at)) << 32 | Int64(u32(at + 4)) }
        func children(_ start: Int, _ end: Int) -> [(type: String, body: Int, end: Int)] {
            var result: [(String, Int, Int)] = []
            var offset = start
            while offset + 8 <= end {
                let size = u32(offset)
                let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
                guard size >= 8 else { break }
                result.append((type, offset + 8, min(offset + size, end)))
                offset += size
            }
            return result
        }
        let moof = try #require(children(0, bytes.count).first { $0.type == "moof" })
        let traf = try #require(children(moof.body, moof.end).first { $0.type == "traf" })
        var base: Int64 = 0
        var samples: [Sample] = []
        var defaultDuration = 0
        for box in children(traf.body, traf.end) {
            switch box.type {
            case "tfhd":
                let flags = u32(box.body) & 0xFFFFFF
                var at = box.body + 8
                if flags & 0x1 != 0 { at += 8 }
                if flags & 0x2 != 0 { at += 4 }
                if flags & 0x8 != 0 { defaultDuration = u32(at) }
            case "tfdt":
                base = bytes[box.body] == 1 ? u64(box.body + 4) : Int64(u32(box.body + 4))
            case "trun":
                let version = Int(bytes[box.body])
                let flags = u32(box.body) & 0xFFFFFF
                let count = u32(box.body + 4)
                var at = box.body + 8
                if flags & 0x1 != 0 { at += 4 }
                if flags & 0x4 != 0 { at += 4 }
                for _ in 0..<count {
                    var duration = defaultDuration, size = 0, offset = 0
                    if flags & 0x100 != 0 { duration = u32(at); at += 4 }
                    if flags & 0x200 != 0 { size = u32(at); at += 4 }
                    if flags & 0x400 != 0 { at += 4 }
                    if flags & 0x800 != 0 {
                        offset = version == 1 ? Int(Int32(truncatingIfNeeded: u32(at))) : u32(at)
                        at += 4
                    }
                    samples.append(Sample(duration: Int64(duration), compositionOffset: Int64(offset), size: size))
                }
            default:
                break
            }
        }
        return Fragment(baseDecodeTime: base, samples: samples)
    }

    @Test("Packets that open a re-anchored stream without a DTS are taken by the muxer, in order and on time")
    func reanchoredStartIsAccepted() throws {
        let url = try fixture("h264_aac.mkv")
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, url.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        let videoIndex = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        try #require(videoIndex >= 0)

        let writer = FMP4SegmentWriter()
        let ledger = TimestampRepairLedger()
        writer.timestampRepairs = ledger
        _ = try writer.open(
            input: context,
            plan: [FMP4SegmentWriter.StreamPlan(inputIndex: videoIndex) { stream in
                try FFmpegError.check(
                    avcodec_parameters_copy(
                        stream.pointee.codecpar,
                        context.pointee.streams[Int(videoIndex)]!.pointee.codecpar
                    ),
                    "avcodec_parameters_copy"
                )
                stream.pointee.codecpar.pointee.codec_tag = 0
                stream.pointee.codecpar.pointee.video_delay = 4
                stream.pointee.time_base = AVRational(num: 1, den: 90_000)
            }],
            restart: true
        )
        let output = try #require(writer.context)
        let timeBase = output.pointee.streams[0]!.pointee.time_base
        func ticks(_ value: Int64) -> Int64 {
            av_rescale_q(value, AVRational(num: 1, den: 90_000), timeBase)
        }

        // Decode order of an open GOP with uneven, millisecond-rounded spacing:
        // the keyframe is the third picture in display order.
        let display: [Int64] = [
            171_362_430, 171_366_210, 171_369_990, 171_373_770, 171_377_550, 171_381_240,
            171_385_020, 171_388_800, 171_392_490, 171_396_270,
        ]
        let decodeOrder = [display[2], display[0], display[1], display[5], display[3], display[4],
                           display[8], display[6], display[7], display[9]]
        let dts = LeadingDTSBackfillTests.demuxerDTS(forDecodeOrderPTS: decodeOrder, delay: 4)

        for (index, pts) in decodeOrder.enumerated() {
            var packet = av_packet_alloc()
            defer { av_packet_free(&packet) }
            let allocated = try #require(packet)
            try FFmpegError.check(av_new_packet(allocated, 2000 + Int32(index)), "av_new_packet")
            allocated.pointee.stream_index = 0
            allocated.pointee.pts = ticks(pts)
            allocated.pointee.dts = dts[index].map(ticks) ?? swift_AV_NOPTS_VALUE()
            allocated.pointee.duration = ticks(3690)
            allocated.pointee.flags = index == 0 ? AV_PKT_FLAG_KEY : 0
            try writer.write(allocated)
        }

        let (initSegment, media) = try writer.cutSegment()
        #expect(initSegment?.isEmpty == false)
        // A reorder window that is still empty after a seek is not a fault of
        // the source: none of this is a repair.
        #expect(ledger.stats == nil)

        let fragment = try parseFragment(media)
        #expect(fragment.samples.count == decodeOrder.count, "no packet was lost to the wait")
        #expect(fragment.samples.map(\.size) == (0..<decodeOrder.count).map { 2000 + $0 }, "the samples are in decode order")
        // Positive durations (the last sample's comes from its packet) and no
        // picture decoded after it is due.
        #expect(fragment.samples.dropLast().allSatisfy { $0.duration > 0 })
        #expect(fragment.samples.allSatisfy { $0.compositionOffset >= 0 })
        // Where the fragment sits on the timeline is the muxer's business (it
        // places the first packet); what must hold is the spacing: every sample
        // is presented exactly as long after the first as its packet was.
        var decodeTime = fragment.baseDecodeTime
        var presentation: [Int64] = []
        for sample in fragment.samples {
            presentation.append(decodeTime + sample.compositionOffset)
            decodeTime += sample.duration
        }
        #expect(presentation.map { $0 - presentation[0] } == decodeOrder.map { ticks($0) - ticks(decodeOrder[0]) })
        _ = try writer.finish()
    }

    @Test("Packets still waiting when the fragment is cut are written, not dropped")
    func heldPacketsSurviveTheCut() throws {
        let url = try fixture("h264_aac.mkv")
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, url.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        let videoIndex = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        try #require(videoIndex >= 0)

        let writer = FMP4SegmentWriter()
        _ = try writer.open(
            input: context,
            plan: [FMP4SegmentWriter.StreamPlan(inputIndex: videoIndex) { stream in
                try FFmpegError.check(
                    avcodec_parameters_copy(
                        stream.pointee.codecpar,
                        context.pointee.streams[Int(videoIndex)]!.pointee.codecpar
                    ),
                    "avcodec_parameters_copy"
                )
                stream.pointee.codecpar.pointee.codec_tag = 0
                stream.pointee.codecpar.pointee.video_delay = 2
            }],
            restart: true
        )
        let timeBase = try #require(writer.context).pointee.streams[0]!.pointee.time_base

        // Three packets, none with a DTS: the stream ends before one comes.
        for index in 0..<3 {
            var packet = av_packet_alloc()
            defer { av_packet_free(&packet) }
            let allocated = try #require(packet)
            try FFmpegError.check(av_new_packet(allocated, 1000 + Int32(index)), "av_new_packet")
            allocated.pointee.stream_index = 0
            allocated.pointee.pts = av_rescale_q(Int64(index) * 3750, AVRational(num: 1, den: 90_000), timeBase)
            allocated.pointee.dts = swift_AV_NOPTS_VALUE()
            allocated.pointee.duration = av_rescale_q(3750, AVRational(num: 1, den: 90_000), timeBase)
            allocated.pointee.flags = index == 0 ? AV_PKT_FLAG_KEY : 0
            try writer.write(allocated)
        }
        let (_, media) = try writer.cutSegment()
        let fragment = try parseFragment(media)
        #expect(fragment.samples.map(\.size) == [1000, 1001, 1002])
        _ = try writer.finish()
    }
}
