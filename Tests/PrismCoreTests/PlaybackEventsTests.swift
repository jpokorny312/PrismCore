import Testing
import Foundation
import os
@testable import PrismCore

/// A host input that parks its read once `parkAfterBytes` have been handed
/// over — a share or debrid link that stopped feeding mid-film without
/// failing. Conforming, so `stop()` can release it and join the producer.
private final class ParkingInput: CancellablePrismCoreInput, @unchecked Sendable {
    private let bytes: [UInt8]
    private let parkAfterBytes: Int
    private let lock = NSCondition()
    private var position = 0
    private var delivered = 0
    private var released = false
    private var parked = false

    struct Released: Error {}

    init(data: Data, parkAfterBytes: Int) {
        bytes = [UInt8](data)
        self.parkAfterBytes = parkAfterBytes
    }

    var length: Int64? { Int64(bytes.count) }
    var isParked: Bool { lock.withLock { parked } }

    func seek(to offset: Int64) throws {
        lock.withLock { position = Int(max(0, min(offset, Int64(bytes.count)))) }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if delivered >= parkAfterBytes {
            parked = true
            while !released { lock.wait() }
            parked = false
            throw Released()
        }
        // Small answers, like a real transport, so the park lands inside the
        // copy loop rather than inside one giant probe read.
        let count = min(buffer.count, 16 * 1024, bytes.count - position)
        guard count > 0 else { return 0 }
        bytes.withUnsafeBytes {
            buffer.baseAddress!.copyMemory(from: $0.baseAddress!.advanced(by: position), byteCount: count)
        }
        position += count
        delivered += count
        return count
    }

    func cancelInFlightOperation() {
        lock.withLock {
            released = true
            lock.broadcast()
        }
    }
}

@Suite("Playback events")
struct PlaybackEventsTests {

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(
            Bundle.module.url(forResource: name, withExtension: "mkv", subdirectory: "Fixtures")
        ))
    }

    /// Everything the stream delivered until `stop()` finished it.
    private func drain(_ events: AsyncStream<PlaybackEvent>) -> Task<[PlaybackEvent], Never> {
        Task { var seen: [PlaybackEvent] = []; for await event in events { seen.append(event) }; return seen }
    }

    @Test("A 429 from the origin reaches the host, and so does the recovery")
    func originThrottledAndRecovered() async throws {
        let server = try RangeFixtureServer(media: fixture("h264_aac_30s"), refusals: 1, retryAfter: "1")
        let url = try await server.start()
        defer { server.stop() }
        let session = try PrismCoreSession(url: url, coordinatedHTTP: true)
        let seen = drain(await session.playbackEvents())
        do { _ = try await session.start() } catch { await session.stop(); throw error }
        await session.stop()

        let events = await seen.value
        let throttled = events.firstIndex(of: .originThrottled(retryAfter: .seconds(1)))
        let recovered = events.firstIndex(of: .originRecovered)
        #expect(throttled != nil, "no .originThrottled in \(events)")
        #expect(recovered != nil, "no .originRecovered in \(events)")
        if let throttled, let recovered { #expect(throttled < recovered) }
    }

    @Test("A request waiting on a producer parked inside a read reports the stall")
    func producerStalledWhileAServeWaits() async throws {
        let input = ParkingInput(data: try fixture("h264_aac_30s"), parkAfterBytes: 400_000)
        defer { input.cancelInFlightOperation() }
        let session = try PrismCoreSession(
            url: URL(fileURLWithPath: "/prismcore-tests-no-such-directory/stalled.mkv"),
            input: { input }
        )
        // Registered AFTER start(): the run-time feed has to work that way.
        let playlist = try await session.start()
        let events = await session.playbackEvents()
        let stalled = Task { () -> PlaybackEvent? in
            for await event in events { if case .producerStalled = event { return event } }
            return nil
        }

        let parkDeadline = ContinuousClock.now + .seconds(20)
        while !input.isParked, ContinuousClock.now < parkDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(input.isParked, "the producer never reached the parked read")

        // The last planned segment is far past where the producer stopped, so
        // this request goes pending on production that cannot happen.
        let (master, _) = try await URLSession.uncached.data(from: playlist)
        var variant = playlist
        if let uri = PrismCoreSession.playlistURIs(inMaster: String(decoding: master, as: UTF8.self)).last {
            variant = playlist.deletingLastPathComponent().appendingPathComponent(uri)
        }
        let (media, _) = try await URLSession.uncached.data(from: variant)
        let last = try #require(String(decoding: media, as: UTF8.self)
            .split(separator: "\n").last { $0.hasSuffix(".m4s") })
        let fetch = Task {
            _ = try? await URLSession.uncached.data(from: variant.deletingLastPathComponent().appendingPathComponent(String(last)))
        }

        let event = await withTimeout(.seconds(12)) { await stalled.value }
        fetch.cancel()
        await session.stop()

        guard case .producerStalled(let since, let lastPTS)?? = event else {
            Issue.record("no .producerStalled within 12 s: \(String(describing: event))")
            return
        }
        #expect(since >= .seconds(5))
        // The producer did read packets before it parked; the event says where.
        #expect((lastPTS ?? 0) > 0)
    }

    @Test("A 429 and a 206 that cross never leave the host on a throttle")
    func crossedRefusalAndSuccessEndRecovered() {
        let coordinator = HTTPOriginCoordinator()
        let origin = "http://race.invalid:80"
        let last = OSAllocatedUnfairLock<PlaybackEvent?>(initialState: nil)
        let observation = coordinator.observe(origin) { event in last.withLock { $0 = event } }
        defer { withExtendedLifetime(observation) {} }

        // The two fills of one origin, answered at the same moment. Many
        // rounds, because the bad interleaving is a narrow window.
        for round in 0..<5_000 {
            DispatchQueue.concurrentPerform(iterations: 2) { slot in
                if slot == 0 { coordinator.refuse(origin, retryAfter: nil) } else { coordinator.succeeded(origin) }
            }
            // The origin is healthy from here on.
            coordinator.succeeded(origin)
            let final = last.withLock { $0 }
            if final != nil, final != .originRecovered {
                Issue.record("round \(round): host left on \(String(describing: final))")
                return
            }
        }
    }

    /// A provider with no producer behind it, so every planned miss can only
    /// run out — plus the feed its events go to.
    private func orphanProvider(root: URL, timeout: Duration) -> (PlanSegmentProvider, PlaybackEventSink, AsyncStream<PlaybackEvent>) {
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<4).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        ))
        let sink = PlaybackEventSink()
        let (stream, continuation) = AsyncStream<PlaybackEvent>.makeStream()
        sink.replace(with: continuation)
        var provider = PlanSegmentProvider(root: root, coordinator: coordinator)
        provider.events = sink
        provider.productionTimeout = timeout
        return (provider, sink, stream)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCore-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func finish(_ sink: PlaybackEventSink, _ stream: AsyncStream<PlaybackEvent>) async -> [PlaybackEvent] {
        sink.replace(with: nil)
        var events: [PlaybackEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("A serve the producer never satisfies reports its timeout")
    func serveTimedOut() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (provider, sink, stream) = orphanProvider(root: root, timeout: .milliseconds(300))

        guard case .pending(let pending) = await provider.data(forPath: "seg00003.m4s") else {
            Issue.record("a missing planned segment must go pending")
            return
        }
        guard case .notFound = await pending.resolve() else {
            Issue.record("the timed-out serve must answer the miss")
            return
        }
        #expect(await finish(sink, stream) == [.serveTimedOut(path: "seg00003.m4s")])
    }

    @Test("A wait whose request went away reports no timeout")
    func cancelledWaitIsSilent() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (provider, sink, stream) = orphanProvider(root: root, timeout: .milliseconds(600))

        guard case .pending(let pending) = await provider.data(forPath: "seg00003.m4s") else {
            Issue.record("a missing planned segment must go pending")
            return
        }
        // What a seek does to the old request: the server cancels its wait.
        let wait = Task { await pending.resolve() }
        try await Task.sleep(for: .milliseconds(100))
        wait.cancel()
        _ = await wait.value
        // Past the window the wait would have timed out in.
        try await Task.sleep(for: .milliseconds(800))
        #expect(await finish(sink, stream) == [])
    }

    @Test("A HEAD answered during a slow serve reports no timeout")
    func answeredHeadIsSilent() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (provider, sink, stream) = orphanProvider(root: root, timeout: .seconds(1))
        let server = LoopbackHTTPServer(
            provider: provider, limits: .init(slowServeThreshold: .milliseconds(200)), events: sink
        )
        let base = try await server.start()

        var request = URLRequest(url: base.appendingPathComponent("seg00003.m4s"))
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.uncached.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        // Past the production window the orphaned wait used to run out.
        try await Task.sleep(for: .milliseconds(1_500))
        await server.stop()
        #expect(await finish(sink, stream) == [])
    }
}
