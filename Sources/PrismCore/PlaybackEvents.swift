import Foundation

/// Something the running session noticed that a host can explain to a viewer.
///
/// Before these existed, every runtime trouble reached the host the same way:
/// a generic AVPlayer error some seconds later, with the cause — an origin
/// shedding load, a producer parked inside a read nobody answers — known only
/// to the engine's own log. Report-only: nothing here repairs anything.
///
/// Two kinds. The first five cases are **trouble**. `.segmentServed` and
/// `.sourceThroughput` are **delivery** events — what the session does when
/// nothing is wrong — and reach only a stream registered with
/// `playbackEvents(delivery: true)`.
///
/// The set grows: switch over it with a `default`.
public enum PlaybackEvent: Sendable, Equatable {
    /// A served file took longer than the server's slow-serve threshold
    /// (2 s) to be ready, and was then delivered. `waited` is the whole wait.
    case slowServe(path: String, waited: Duration)

    /// A served file never landed within the production window, and the
    /// request was answered with the miss (an aborted transfer for media, an
    /// empty WebVTT for subtitles). AVPlayer usually reports an error next.
    case serveTimedOut(path: String)

    /// A request is waiting on the producer and the producer has not read a
    /// packet for `since`. `lastPTS` is the newest packet timestamp it did
    /// read, in seconds on the source's timeline (`nil` before the first).
    ///
    /// Measured only while a serve is pending, and never while the producer
    /// is deliberately parked, so a paused player does not look stalled.
    case producerStalled(since: Duration, lastPTS: Double?)

    /// The source origin answered 429/503/509. `retryAfter` is what its
    /// `Retry-After` header asked for, when it sent one.
    ///
    /// Origin admission is shared by every session reading the same origin,
    /// so **every session on that origin sees this**, including one whose own
    /// requests were never refused — they are all held back by it.
    case originThrottled(retryAfter: Duration?)

    /// The first good response from a throttled origin. Shared like
    /// `originThrottled`.
    case originRecovered

    // MARK: Delivery events
    //
    // Routine, not trouble: they say what the session is doing when nothing is
    // wrong, and they come with every segment served and every second of reading.
    // They reach only a stream that asked for them
    // (`playbackEvents(delivery: true)`), so a host that listens for trouble hears
    // exactly what it always heard.

    /// A segment — media or subtitle, of any rendition — was handed to the
    /// loopback connection in full. Not sent for a playlist or an init segment,
    /// for a `HEAD`, for a miss, or when the connection failed before it had
    /// taken the payload.
    ///
    /// **Handed to the connection is not read by the player.** The event is sent
    /// when the connection has accepted the payload's last byte. A payload that
    /// fits the socket buffers (up to about a megabyte on loopback, measured; it
    /// varies with the kernel) is accepted at once, so it is reported even if the
    /// player drops the connection without reading a byte of it. A larger one is
    /// reported only once the player has drained enough of it.
    ///
    /// `path` is the one `slowServe` reports (root-relative, no session token),
    /// `index` the number in its name, `bytes` the size of the payload.
    ///
    /// - `waited`: how long the request waited for the segment to exist — about
    ///   nothing for one already on disk, the producer's time for one it was still
    ///   cutting. The part of a late segment that belongs to the source and the
    ///   producer.
    /// - `transferred`: from the payload being in hand until the connection had
    ///   accepted its last byte. For a payload within the socket buffers that is
    ///   the time to copy it into the kernel and says nothing about the player;
    ///   only a larger one makes it follow how fast the player drains the socket.
    ///   It never says anything about the source.
    ///
    /// A fetch that is also trouble is reported as both: a slow serve is a served
    /// segment (`.slowServe` first, as before), and so is the 8-byte empty WebVTT
    /// that answers a subtitle segment which did not land — `.serveTimedOut`, then
    /// `.slowServe` (it waited past the slow-serve threshold), then this.
    case segmentServed(path: String, index: Int, bytes: Int, waited: Duration, transferred: Duration)

    /// What the **source** delivered to the producer while it was being asked: the
    /// rate over the last `readTime` of reading, which is when the producer was
    /// inside a read of the source, not when it was parked, muxing or writing.
    ///
    /// The number an AVPlayer access log does not give: the player reads the
    /// loopback, and its figures describe that read — `observedBitrate` strays
    /// from the source, and the bytes over the summed transfer time follow it only
    /// up to a factor that belongs to the player (CHANGELOG has the numbers). This
    /// one is the producer's side, measured at the I/O layer — the bytes it pulled,
    /// over the time the producer waited for them — above whichever reader is
    /// under it.
    ///
    /// What that does and does not mean:
    /// - Where the producer reads continuously and the reader waits for the link
    ///   as it reads (libavformat's own HTTP, a host input that returns what has
    ///   arrived), it **tracks the link**. The CHANGELOG has what was measured.
    /// - Whatever fills while the producer is not reading is credited at no cost
    ///   when it reads again. A reader that fetches ahead and keeps what it
    ///   fetched — the coordinated reader's 1 MiB blocks, a host input with a
    ///   cache of its own — does it by design, and so, on a smaller scale, do the
    ///   socket buffers under libavformat's HTTP after the producer has parked.
    ///   Over a short session that **over-reads** (the head the probe fetched
    ///   counts as delivered at no cost), and a single window can swing either way
    ///   depending on whether it caught a fetch. Pool several over more than a
    ///   block's worth of reading, and read the number as "the link is no slower
    ///   than this" rather than as its capacity once the producer has been parked.
    /// - A source that never makes the producer wait fills windows slowly or not
    ///   at all; what it reports is how fast the reader could take bytes in, not
    ///   the capacity of the link.
    /// - A source that has stopped delivering produces no event while it is
    ///   silent, because a read that has not returned has not been measured.
    ///   `.producerStalled` reports that, but only while a request is waiting on
    ///   the producer: with the player's buffer full, silence is all there is.
    ///
    /// One event per window of reading (about a second), so it is as frequent as
    /// the producer is busy reading. A window closes at the end of the read that
    /// fills it: if the producer parked in between, its reading time is spread over
    /// a longer stretch of wall time and the event can be older than it arrives.
    /// `bytes` and `readTime` are the window's own: average several readings by
    /// weighting with them (Σbytes / ΣreadTime), not by counting events. Counts
    /// what the copy loop reads, not the probe and index reads of startup.
    case sourceThroughput(bytesPerSecond: Double, bytes: Int64, readTime: Duration)

    /// Whether this is a delivery event (see above) rather than trouble.
    var isDelivery: Bool {
        switch self {
        case .segmentServed, .sourceThroughput: return true
        case .slowServe, .serveTimedOut, .producerStalled, .originThrottled, .originRecovered: return false
        }
    }
}

/// Where the engine's components drop `PlaybackEvent`s. Exists from session
/// init, so a host may register before or after `start()`; with nobody
/// registered, a yield is one lock and a nil check.
final class PlaybackEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var registration: (continuation: AsyncStream<PlaybackEvent>.Continuation, delivery: Bool)?

    var isObserved: Bool { lock.withLock { registration != nil } }

    /// Whether the registered stream asked for delivery events. Checked before a
    /// delivery event is built, so a session nobody asked for them costs a lock
    /// and a bool per segment and per second of reading.
    var isObservingDelivery: Bool { lock.withLock { registration?.delivery == true } }

    func yield(_ event: PlaybackEvent) {
        let target = lock.withLock { registration }
        // A delivery event for a stream that did not ask is dropped here, in the
        // one place every emitter passes, so none of them has to remember to ask.
        guard let target, target.delivery || !event.isDelivery else { return }
        // Yielded outside the lock: the continuation has its own, and holding
        // ours across it would order unrelated emitters behind each other.
        target.continuation.yield(event)
    }

    func replace(with next: AsyncStream<PlaybackEvent>.Continuation?, delivery: Bool = false) {
        let previous = lock.withLock {
            defer { registration = next.map { ($0, delivery) } }
            return registration?.continuation
        }
        previous?.finish()
    }
}
