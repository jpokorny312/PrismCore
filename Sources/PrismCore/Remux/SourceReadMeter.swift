import Foundation

/// Turns what the copy loop pulls from the source into rate readings: bytes the
/// source delivered per second the loop spent **inside the read** — not per
/// second of the wall clock.
///
/// The difference is the point. The producer parks when the player is far enough
/// behind it, and it also muxes, writes and waits for demand; a rate over wall
/// time falls towards zero in every one of those moments and would read a full
/// buffer as a dying link. Time inside `av_read_frame` is, in the main, the time
/// the source made the reader wait (the demuxer's own work is in it too), so
/// bytes per second of it is what the source delivered while it was being asked.
///
/// A reading is a **window**, not a packet: it closes once the loop has spent
/// `window` seconds reading, however long that took on the wall clock. One packet
/// is a few kilobytes against a link that delivers megabytes; a second of reading
/// is a number a host can act on. The window's own bytes and seconds travel with
/// the rate so a host can aggregate several readings correctly weighted — an
/// average of rates over windows of different length is not the rate over all of
/// them.
///
/// Reading time is the denominator, so a source that never makes the reader wait
/// (a local file, a link far faster than the stream) fills a window only after
/// many seconds of media and reports rarely or never, and the rate it reports is
/// how fast the reader could take bytes in, not what the link can carry. Silence
/// from this meter means that, or that a read has not returned (a starved source;
/// `.producerStalled` reports it only while a request is waiting).
///
/// Plain value, owned by the producer thread: no lock, no clock. The caller
/// measures.
struct SourceReadMeter {

    /// What one closed window measured.
    struct Reading: Sendable, Equatable {
        /// Bytes the source delivered to the reader during the window.
        let bytes: Int64
        /// Time the reader spent inside reads during the window, in seconds.
        let seconds: Double

        var bytesPerSecond: Double { seconds > 0 ? Double(bytes) / seconds : 0 }
    }

    /// One second of reading: short enough that a link that dried up is heard of
    /// within seconds of the data that shows it, long enough that one slow packet
    /// is not the whole reading.
    static let defaultWindow: Double = 1.0

    let window: Double
    private var bytes: Int64 = 0
    private var seconds: Double = 0

    init(window: Double = SourceReadMeter.defaultWindow) {
        self.window = window
    }

    /// One read: the `bytes` the source delivered inside it and the `seconds` it
    /// took. Returns the reading when this read closed a window.
    ///
    /// Negative inputs count as nothing: a clock that stepped back, or an I/O
    /// context that was replaced under the demuxer (its byte counter starts over),
    /// must not subtract from a window.
    mutating func record(bytes: Int64, seconds: Double) -> Reading? {
        self.bytes &+= max(0, bytes)
        self.seconds += max(0, seconds)
        guard self.seconds >= window else { return nil }
        defer {
            self.bytes = 0
            self.seconds = 0
        }
        return Reading(bytes: self.bytes, seconds: self.seconds)
    }
}
