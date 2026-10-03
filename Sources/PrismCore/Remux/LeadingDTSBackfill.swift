/// Gives the first packets of a video stream the decode time they come without,
/// so that none of them ends up after one that follows.
///
/// Matroska stores presentation times only. libavformat derives a decode time
/// for every packet from them with a small sorting window as deep as the
/// stream's picture reordering (`video_delay`: 4 on the Blu-ray remuxes this
/// was found on), and that window is empty after every seek. The first
/// `video_delay` packets that leave the demuxer therefore have no DTS at all,
/// and the packet after them carries the first real one — the smallest
/// presentation time of the five, which is the first picture to be shown.
///
/// A muxer cannot take a packet without a DTS, so libavformat's mux layer
/// fills the gap in with a formula of its own: the packet's PTS less
/// `video_delay` frame durations, sorted in as the packets go by. That is
/// usually the number the demuxer would have given. Usually — both read the same
/// presentation times, but the muxer assumes frames of one even length while
/// Matroska's millisecond clock rounds each of them differently. Where a
/// segment opens on an open-GOP keyframe (the pictures that lead it follow it in
/// decode order, with earlier presentation times) the muxer's number for the
/// third or fourth packet came out a couple of milliseconds *above* the real DTS
/// of the fifth, `av_interleaved_write_frame` answered EINVAL ("non monotonically
/// increasing dts") and the whole remux ended. Every re-anchor onto such a
/// keyframe did that; the stream played on until the buffer ran out.
///
/// `TimestampSanitizer` cannot close this gap, and by design: where pictures
/// are reordered it leaves a missing DTS to the muxer (a first packet's PTS is no
/// stand-in for its DTS), so it never sees the numbers the muxer then makes up
/// and has no predecessor to measure the first real DTS against.
///
/// So the gap is closed here, with the one number that is certain — the first
/// real DTS. The packets that came without are held until it arrives and then
/// numbered backwards from it, one frame duration apart, never later than their
/// own PTS. For the regular timestamps of a file's start this reproduces exactly
/// what the muxer would have made of them, so nothing changes there; where the
/// two disagreed, the packets now agree with the ones after them. This runs
/// ahead of the sanitizer, which then sees a stream that has a DTS from its
/// first packet. Nothing it does here counts as a repair: a reorder window that
/// is still empty after a seek is not a fault of the source.
///
/// Pure and independently testable: it never touches libav* state. `Held` is
/// whatever the caller needs to keep of a packet until it is released.
struct LeadingDTSBackfill<Held> {

    /// What to write next.
    struct Release {
        enum Item {
            /// A packet held earlier.
            case held(Held)
            /// The packet that was just admitted.
            case current
        }

        let item: Item
        /// The DTS to write it with. `nil` leaves the packet's own timestamps
        /// alone: a real DTS stays, and a missing one is the muxer's to estimate.
        let dts: Int64?
    }

    /// libavformat sorts at most `MAX_REORDER_DELAY` (16) pictures, so a stream
    /// that is going to have a DTS has one by its 17th packet. A stream that
    /// still has none after that is not going to get one from the demuxer, and
    /// holding on to its packets would only grow a queue.
    static var holdLimit: Int { 17 }

    private struct Entry {
        let held: Held
        let pts: Int64
        let duration: Int64
    }

    private var entries: [Entry] = []

    /// Whether the stream is past its beginning: a real DTS has come, or the
    /// attempt was given up. From then on every packet can be written as it is.
    private(set) var isSettled = false

    /// The packets to write now, in order. Empty while the packet is held back.
    ///
    /// - Parameters:
    ///   - dts: the packet's DTS, `nil` when it has none.
    ///   - pts: the packet's PTS, `nil` when it has none.
    ///   - duration: the packet's duration in the stream's ticks (0 if unknown).
    ///   - hold: makes the caller's record of the packet, asked for only when the
    ///     packet is actually held.
    mutating func admit(
        dts: Int64?,
        pts: Int64?,
        duration: Int64,
        hold: () throws -> Held
    ) rethrows -> [Release] {
        guard !isSettled else { return [Release(item: .current, dts: nil)] }

        if let dts {
            isSettled = true
            return backfill(before: dts) + [Release(item: .current, dts: nil)]
        }

        guard let pts, entries.count < Self.holdLimit else {
            // Nothing to number it from, or no number is coming: the old way.
            isSettled = true
            return drain() + [Release(item: .current, dts: nil)]
        }
        entries.append(Entry(held: try hold(), pts: pts, duration: duration))
        return []
    }

    /// Whatever is still held, to be written with the timestamps it has (the
    /// muxer estimates the missing ones): the fragment ends, or the stream does,
    /// before a real DTS came. Does not settle the stream.
    mutating func drain() -> [Release] {
        let releases = entries.map { Release(item: .held($0.held), dts: nil) }
        entries.removeAll()
        return releases
    }

    /// Numbers the held packets backwards from `firstDTS`, the DTS of the packet
    /// that just arrived.
    private mutating func backfill(before firstDTS: Int64) -> [Release] {
        guard let first = entries.first else { return [] }
        // The muxer's own choice, and the one that matches a file's start: the
        // first packet's duration for all of them.
        let step = max(1, first.duration)
        var next = firstDTS
        var numbers = [Int64](repeating: 0, count: entries.count)
        for index in entries.indices.reversed() {
            // One frame before its successor, and never after its own PTS: a
            // packet cannot be decoded after it is due on screen. Both bounds
            // are below the successor's number, so the order is strict.
            let number = min(next - step, entries[index].pts)
            numbers[index] = number
            next = number
        }
        let releases = zip(entries, numbers).map { Release(item: .held($0.held), dts: $1) }
        entries.removeAll()
        return releases
    }
}
