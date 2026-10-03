import Foundation
import Libavcodec
import Libavutil

/// Repairs the three timestamp faults that make the mp4 muxer refuse a packet
/// or write a sample table AVPlayer misplays. One instance per output stream,
/// fed packets already rescaled onto that stream's time base.
///
/// Why it exists: a stream copy hands the muxer whatever the demuxer produced,
/// and real sources do not always produce something a muxer accepts — an MKV
/// cut, a concatenated TS, a stream with packed B-frames, H.264 in Matroska
/// whose DTS libavformat had to guess. libavformat's generic mux layer rejects
/// a DTS that does not strictly increase, and a PTS below its DTS, with
/// `EINVAL`, and that one packet fails the whole remux (`remuxFailure`) on a
/// file every software player opens. The repairs are deliberately local — one
/// packet at a time, never a GOP rewrite — because moving decode times further
/// than a tick is what would start costing A/V sync.
struct TimestampSanitizer {

    /// Which repairs one packet needed. A packet can need more than one: a
    /// bumped DTS is exactly what pushes a B-frame's PTS below it.
    struct Repairs: OptionSet, Equatable {
        let rawValue: Int
        static let missingDTSFilled = Repairs(rawValue: 1 << 0)
        static let nonMonotonicDTSBumped = Repairs(rawValue: 1 << 1)
        static let ptsRaisedToDTS = Repairs(rawValue: 1 << 2)
    }

    /// Whether the stream decodes out of presentation order (B-frames). There a
    /// first packet's PTS is no stand-in for its DTS: it can sit frames ahead
    /// of the decode times that follow, and every one of them would then be
    /// clamped up behind it.
    let reordersFrames: Bool
    private var lastDTS: Int64?

    init(reordersFrames: Bool) {
        self.reordersFrames = reordersFrames
    }

    /// Repair `pts`/`dts` in place (`nopts` marks an unset value).
    mutating func repair(
        pts: inout Int64,
        dts: inout Int64,
        duration: Int64,
        nopts: Int64 = swift_AV_NOPTS_VALUE()
    ) -> Repairs {
        var repairs: Repairs = []
        if dts == nopts {
            // Left unset, movenc invents a decode time of its own and the
            // monotonic check below never sees it. The previous packet's
            // end is the one decode time that needs no knowledge of reorder;
            // PTS stands in only where decode and presentation order agree.
            if let lastDTS, duration > 0 {
                dts = lastDTS + duration
                repairs.insert(.missingDTSFilled)
            } else if pts != nopts, !reordersFrames {
                dts = pts
                repairs.insert(.missingDTSFilled)
            }
        }
        if dts != nopts {
            if let lastDTS, dts <= lastDTS {
                // One tick, not the packet's duration: the next packet's own
                // DTS is usually right again, and the smallest step is the one
                // least likely to push into it and cascade.
                dts = lastDTS + 1
                repairs.insert(.nonMonotonicDTSBumped)
            }
            lastDTS = dts
        }
        if pts != nopts, dts != nopts, pts < dts {
            // Repaired, not dropped: a dropped packet is a frame the decoder
            // never gets, which for a reference frame smears every frame that
            // predicts from it. A picture shown a few ticks late is invisible.
            pts = dts
            repairs.insert(.ptsRaisedToDTS)
        }
        return repairs
    }

    /// Repair the packet's own timestamps and tally what was done.
    mutating func sanitize(
        _ packet: UnsafeMutablePointer<AVPacket>,
        recordingInto ledger: TimestampRepairLedger?
    ) {
        let repairs = repair(
            pts: &packet.pointee.pts,
            dts: &packet.pointee.dts,
            duration: packet.pointee.duration
        )
        if !repairs.isEmpty { ledger?.record(repairs) }
    }
}

/// What the timestamp sanitizer had to repair over a session's remux.
///
/// Non-zero counts mean the source's timestamps were not muxable as they came:
/// before this existed, any of them failed the remux outright (or, for a PTS
/// below its DTS, could). Worth a host's log line when chasing a stutter
/// report, because every repair moves one packet by the smallest amount that
/// makes it legal, and that is not always what the encoder meant.
public struct TimestampRepairStats: Sendable, Equatable {
    /// Packets that arrived with no DTS and were given one.
    public let missingDTSFilled: Int
    /// Packets whose DTS did not move past the previous packet's and was
    /// raised to one tick after it.
    public let nonMonotonicDTSBumped: Int
    /// Packets presented before they would be decoded, whose PTS was raised to
    /// their DTS.
    public let ptsRaisedToDTS: Int

    public init(missingDTSFilled: Int, nonMonotonicDTSBumped: Int, ptsRaisedToDTS: Int) {
        self.missingDTSFilled = missingDTSFilled
        self.nonMonotonicDTSBumped = nonMonotonicDTSBumped
        self.ptsRaisedToDTS = ptsRaisedToDTS
    }

    /// Repairs of any kind — a packet that needed two counts twice.
    public var total: Int { missingDTSFilled + nonMonotonicDTSBumped + ptsRaisedToDTS }
}

/// The session-wide tally every writer's sanitizers report into. Writers are
/// rebuilt on each re-anchor (and each rendition has its own), so the counts
/// have to outlive them; the lock is because the host reads from wherever it
/// likes while the producer thread writes, and it is only taken on a repair.
final class TimestampRepairLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var missingDTSFilled = 0
    private var nonMonotonicDTSBumped = 0
    private var ptsRaisedToDTS = 0

    func record(_ repairs: TimestampSanitizer.Repairs) {
        lock.withLock {
            if repairs.contains(.missingDTSFilled) { missingDTSFilled += 1 }
            if repairs.contains(.nonMonotonicDTSBumped) { nonMonotonicDTSBumped += 1 }
            if repairs.contains(.ptsRaisedToDTS) { ptsRaisedToDTS += 1 }
        }
    }

    /// `nil` until something was repaired, so a clean source reads as "nothing
    /// to report" rather than a row of zeros a host has to inspect.
    var stats: TimestampRepairStats? {
        lock.withLock {
            guard missingDTSFilled + nonMonotonicDTSBumped + ptsRaisedToDTS > 0 else { return nil }
            return TimestampRepairStats(
                missingDTSFilled: missingDTSFilled,
                nonMonotonicDTSBumped: nonMonotonicDTSBumped,
                ptsRaisedToDTS: ptsRaisedToDTS
            )
        }
    }
}
