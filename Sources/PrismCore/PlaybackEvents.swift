import Foundation

/// Something the running session noticed that a host can explain to a viewer.
///
/// Before these existed, every runtime trouble reached the host the same way:
/// a generic AVPlayer error some seconds later, with the cause — an origin
/// shedding load, a producer parked inside a read nobody answers — known only
/// to the engine's own log. Report-only: nothing here repairs anything.
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
}

/// Where the engine's components drop `PlaybackEvent`s. Exists from session
/// init, so a host may register before or after `start()`; with nobody
/// registered, a yield is one lock and a nil check.
final class PlaybackEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<PlaybackEvent>.Continuation?

    var isObserved: Bool { lock.withLock { continuation != nil } }

    func yield(_ event: PlaybackEvent) {
        // Yielded outside the lock: the continuation has its own, and holding
        // ours across it would order unrelated emitters behind each other.
        lock.withLock { continuation }?.yield(event)
    }

    func replace(with next: AsyncStream<PlaybackEvent>.Continuation?) {
        let previous = lock.withLock {
            defer { continuation = next }
            return continuation
        }
        previous?.finish()
    }
}
