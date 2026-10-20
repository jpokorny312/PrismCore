import Testing
import Foundation
import os
@testable import PrismCore

// Shared by the delivery-event tests and their opt-in benchmark
// (`DeliveryEventsBenchmark`).

/// A sink wired to a stream that is drained into an array as events arrive —
/// what a host's `for await` loop does, with the array to look at.
final class DeliveryEventProbe: @unchecked Sendable {
    let sink = PlaybackEventSink()
    private let seen = OSAllocatedUnfairLock(initialState: [PlaybackEvent]())
    private let drain: Task<Void, Never>

    init(delivery: Bool, buffering: Int = 64) {
        let (stream, continuation) = AsyncStream<PlaybackEvent>.makeStream(bufferingPolicy: .bufferingNewest(buffering))
        sink.replace(with: continuation, delivery: delivery)
        let seen = self.seen
        drain = Task { for await event in stream { seen.withLock { $0.append(event) } } }
    }

    var events: [PlaybackEvent] { seen.withLock { $0 } }

    /// The first event matching `predicate`, or `nil` once `timeout` has passed.
    /// Polled: an event is yielded a moment AFTER the client has the last byte,
    /// so a test that looks the instant its request returns would race the server.
    func firstEvent(timeout: Duration = .seconds(5), where predicate: (PlaybackEvent) -> Bool) async -> PlaybackEvent? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let match = events.first(where: predicate) { return match }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Whether `count` events matching `predicate` have arrived, waiting up to
    /// `timeout` for them.
    func waitForCount(_ count: Int, timeout: Duration = .seconds(5), where predicate: (PlaybackEvent) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if events.filter(predicate).count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return events.filter(predicate).count >= count
    }

    /// What arrived, after the stream is finished — the way `stop()` ends it.
    func finish() async -> [PlaybackEvent] {
        sink.replace(with: nil)
        await drain.value
        return events
    }
}

/// Segments and playlists by path; a `delay` makes every payload a `.pending`
/// that lands that much later, which is what a segment the producer is still
/// cutting looks like to the server.
struct DeliveryStubProvider: SegmentProvider {
    let files: [String: Data]
    var delay: Duration = .zero

    func data(forPath path: String) async -> ProviderResult {
        guard let body = files[path] else { return .notFound }
        let type = LoopbackHTTPServer.contentType(for: URL(fileURLWithPath: path))
        guard delay > .zero else { return .data(body, contentType: type) }
        let delay = self.delay
        return .pending(PendingResult {
            try? await Task.sleep(for: delay)
            return .data(body, contentType: type)
        })
    }
}

/// A host input that delivers at a fixed rate: each read takes as long as the
/// bytes it returns would take on a link of `bytesPerSecond`. The link IS the
/// sleep, so what it delivers is known without asking the meter under test.
///
/// The nominal rate is a ceiling, not the truth: a sleep overshoots by a
/// millisecond or so, which on 16 KB at 1.5 MB/s is a tenth of the read. The
/// input therefore keeps its own account of the time spent inside `read`, and
/// `effectiveRate` is what it really delivered.
final class PacedInput: PrismCoreInput, @unchecked Sendable {
    private let bytes: Data
    private let bytesPerSecond: Double
    private let lock = NSLock()
    private var position = 0
    private var delivered = 0
    private var busy: TimeInterval = 0

    init(data: Data, bytesPerSecond: Double) {
        bytes = data
        self.bytesPerSecond = bytesPerSecond
    }

    var length: Int64? { Int64(bytes.count) }
    var deliveredBytes: Int { lock.withLock { delivered } }
    /// Bytes per second of the time spent inside `read`, over everything delivered.
    var effectiveRate: Double { lock.withLock { busy > 0 ? Double(delivered) / busy : 0 } }

    func seek(to offset: Int64) throws {
        lock.withLock { position = Int(max(0, min(offset, Int64(bytes.count)))) }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let (start, count) = lock.withLock { (position, min(buffer.count, 16 * 1024, bytes.count - position)) }
        guard count > 0 else { return 0 }
        let entered = ProcessInfo.processInfo.systemUptime
        if bytesPerSecond.isFinite { Thread.sleep(forTimeInterval: Double(count) / bytesPerSecond) }
        bytes.withUnsafeBytes {
            buffer.baseAddress!.copyMemory(from: $0.baseAddress!.advanced(by: start), byteCount: count)
        }
        let spent = ProcessInfo.processInfo.systemUptime - entered
        lock.withLock {
            position = start + count
            delivered += count
            busy += spent
        }
        return count
    }
}

func deliveryFixture(_ name: String, _ ext: String = "mkv") throws -> Data {
    try Data(contentsOf: try #require(
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    ))
}

func deliveryAbsentURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/prismcore-tests-no-such-directory/\(name)")
}

