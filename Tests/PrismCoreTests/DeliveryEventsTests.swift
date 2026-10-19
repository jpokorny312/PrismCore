import Testing
import Foundation
import os
import Network
@testable import PrismCore
@testable import prismcore_cli
import Libavformat

// The delivery half of `playbackEvents()`: what was served to the player and
// what the source delivered to the producer. The trouble half is in
// `PlaybackEventsTests`.

// MARK: - The meter

@Suite("Source read meter")
struct SourceReadMeterTests {

    @Test("A window closes once the reads add up to its length, and carries its own bytes and seconds")
    func windowClosesAtItsLength() {
        var meter = SourceReadMeter(window: 1)
        // Powers of two, so the sum is exactly one second and no rounding
        // decides whether the window closed.
        #expect(meter.record(bytes: 100, seconds: 0.25) == nil)
        #expect(meter.record(bytes: 200, seconds: 0.25) == nil)
        #expect(meter.record(bytes: 300, seconds: 0.25) == nil)
        let reading = meter.record(bytes: 400, seconds: 0.25)
        #expect(reading == SourceReadMeter.Reading(bytes: 1000, seconds: 1))
        #expect(reading?.bytesPerSecond == 1000)
    }

    @Test("The rate is over the time spent reading: a slow read lowers it, nothing else does")
    func rateIsOverReadingTime() {
        var meter = SourceReadMeter(window: 1)
        // 1 MB in half a second, then 1 MB in a second and a half: 2 MB in 2 s.
        #expect(meter.record(bytes: 1_000_000, seconds: 0.5) == nil)
        let reading = meter.record(bytes: 1_000_000, seconds: 1.5)
        #expect(reading?.bytesPerSecond == 1_000_000)
    }

    @Test("A window that has closed starts the next from nothing")
    func nextWindowStartsEmpty() {
        var meter = SourceReadMeter(window: 1)
        _ = meter.record(bytes: 5_000, seconds: 1)
        #expect(meter.record(bytes: 10, seconds: 0.5) == nil)
        #expect(meter.record(bytes: 10, seconds: 0.5) == SourceReadMeter.Reading(bytes: 20, seconds: 1))
    }

    @Test("One read longer than the window is a reading of its own length")
    func oneLongReadIsOneLongReading() {
        var meter = SourceReadMeter(window: 1)
        // A link that dried up: 40 KB in a 30 s read. The window says so.
        let reading = meter.record(bytes: 40_000, seconds: 30)
        #expect(reading?.seconds == 30)
        #expect(reading?.bytesPerSecond ?? 0 < 1_400)
    }

    @Test("Negative bytes or time count as nothing")
    func negativeInputsAreIgnored() {
        var meter = SourceReadMeter(window: 1)
        // A byte counter that started over (an I/O context replaced under the
        // demuxer) and a clock that stepped back.
        #expect(meter.record(bytes: -5_000_000, seconds: 0.5) == nil)
        #expect(meter.record(bytes: 700, seconds: -3) == nil)
        #expect(meter.record(bytes: 300, seconds: 0.5) == SourceReadMeter.Reading(bytes: 1000, seconds: 1))
    }

    @Test("A zero-length window does not divide by zero")
    func zeroSecondsIsZeroRate() {
        var meter = SourceReadMeter(window: 0)
        #expect(meter.record(bytes: 10, seconds: 0)?.bytesPerSecond == 0)
    }
}

// MARK: - The terminal

@Suite("Delivery events in the CLI")
struct DeliveryCLITests {

    @Test("`prismcore-cli serve --delivery` says what was served and what the source delivers")
    func describesDeliveryEvents() {
        let served = ServeCommand.describe(.segmentServed(
            path: "audio1/seg00012.m4s", index: 12, bytes: 1_500_000, waited: .milliseconds(250), transferred: .milliseconds(3)
        ))
        #expect(served == "served audio1/seg00012.m4s (#12, 1.50 MB), waited 0.250s, transferred in 0.003s")

        let source = ServeCommand.describe(.sourceThroughput(
            bytesPerSecond: 2_500_000, bytes: 2_600_000, readTime: .milliseconds(1040)
        ))
        #expect(source == "source delivers 2.50 MB/s (20.00 Mbit/s): 2.60 MB in 1.04s of reading")
    }
}

// MARK: - Registration

@Suite("Delivery events: who gets them")
struct DeliveryRegistrationTests {

    private let served = PlaybackEvent.segmentServed(
        path: "seg00001.m4s", index: 1, bytes: 10, waited: .zero, transferred: .zero
    )
    private let throughput = PlaybackEvent.sourceThroughput(
        bytesPerSecond: 1_000, bytes: 1_000, readTime: .seconds(1)
    )

    @Test("A stream that did not ask for delivery events never sees them, and still sees trouble")
    func defaultStreamIsTroubleOnly() async {
        let probe = DeliveryEventProbe(delivery: false)
        probe.sink.yield(.slowServe(path: "seg00001.m4s", waited: .seconds(3)))
        probe.sink.yield(served)
        probe.sink.yield(throughput)
        probe.sink.yield(.originRecovered)
        #expect(await probe.finish() == [.slowServe(path: "seg00001.m4s", waited: .seconds(3)), .originRecovered])
    }

    @Test("A stream that asked gets both kinds, in the order they happened")
    func deliveryStreamGetsEverything() async {
        let probe = DeliveryEventProbe(delivery: true)
        probe.sink.yield(served)
        probe.sink.yield(.originThrottled(retryAfter: nil))
        probe.sink.yield(throughput)
        #expect(await probe.finish() == [served, .originThrottled(retryAfter: nil), throughput])
    }

    @Test("Whether anyone wants delivery events is known before one is built")
    func observationFlags() async {
        let sink = PlaybackEventSink()
        #expect(!sink.isObserved && !sink.isObservingDelivery)

        let (_, plain) = AsyncStream<PlaybackEvent>.makeStream()
        sink.replace(with: plain)
        #expect(sink.isObserved && !sink.isObservingDelivery)

        let (_, wanting) = AsyncStream<PlaybackEvent>.makeStream()
        sink.replace(with: wanting, delivery: true)
        #expect(sink.isObserved && sink.isObservingDelivery)

        sink.replace(with: nil)
        #expect(!sink.isObserved && !sink.isObservingDelivery)
    }

    /// Through the stream the SESSION hands out, so that a policy change there —
    /// an unbounded buffer, a different count — fails this test; a stream the test
    /// builds itself would only test the standard library.
    @Test("A host that registers and never reads keeps the newest 64 however many arrive")
    func neverReadingStaysBounded() async throws {
        let session = try PrismCoreSession(url: deliveryAbsentURL("never-started.mkv"))
        let stream = await session.playbackEvents(delivery: true)
        for index in 0..<10_000 {
            session.events.yield(.segmentServed(path: "seg\(index).m4s", index: index, bytes: 1, waited: .zero, transferred: .zero))
        }
        await session.stop()
        var kept: [Int] = []
        for await event in stream {
            if case .segmentServed(_, let index, _, _, _) = event { kept.append(index) }
        }
        #expect(kept == Array(9_936..<10_000))
    }

    /// The price of sharing the buffer, stated as a test so it cannot drift
    /// unnoticed: routine events push trouble out of a stream nobody drains. It
    /// is why delivery events are opt-in, and why the opt-in is documented as
    /// "drain as you go".
    @Test("Delivery events can push trouble out of an undrained stream — which is why they are opt-in")
    func deliveryEvictsTroubleFromAnUndrainedStream() async throws {
        let session = try PrismCoreSession(url: deliveryAbsentURL("never-started.mkv"))
        let stream = await session.playbackEvents(delivery: true)
        session.events.yield(.originThrottled(retryAfter: nil))
        for index in 0..<64 {
            session.events.yield(.segmentServed(path: "s", index: index, bytes: 1, waited: .zero, transferred: .zero))
        }
        await session.stop()
        var troubleKept = false
        for await event in stream { if case .originThrottled = event { troubleKept = true } }
        #expect(!troubleKept)

        // The same trouble event on a stream that did not ask is never pushed out
        // by what that stream never receives.
        let plain = try PrismCoreSession(url: deliveryAbsentURL("never-started.mkv"))
        let troubleOnly = await plain.playbackEvents()
        plain.events.yield(.originThrottled(retryAfter: nil))
        for index in 0..<1_000 {
            plain.events.yield(.segmentServed(path: "s", index: index, bytes: 1, waited: .zero, transferred: .zero))
        }
        await plain.stop()
        var kept: [PlaybackEvent] = []
        for await event in troubleOnly { kept.append(event) }
        #expect(kept == [.originThrottled(retryAfter: nil)])
    }
}

// MARK: - Served segments

@Suite("Segment served events", .serialized)
struct SegmentServedTests {

    private func serve(
        _ files: [String: Data], delay: Duration = .zero, threshold: Duration = .seconds(2), probe: DeliveryEventProbe
    ) async throws -> (server: LoopbackHTTPServer, base: URL) {
        let server = LoopbackHTTPServer(
            provider: DeliveryStubProvider(files: files, delay: delay),
            limits: .init(slowServeThreshold: threshold),
            events: probe.sink
        )
        return (server, try await server.start())
    }

    @Test("A segment on disk is reported with its index, its size and nothing waited")
    func hit() async throws {
        let probe = DeliveryEventProbe(delivery: true)
        let payload = Data(repeating: 7, count: 100_000)
        let (server, base) = try await serve(["seg00007.m4s": payload], probe: probe)
        defer { Task { await server.stop() } }

        let (body, _) = try await URLSession.uncached.data(from: base.appendingPathComponent("seg00007.m4s"))
        #expect(body.count == 100_000)

        let event = await probe.firstEvent { if case .segmentServed = $0 { true } else { false } }
        guard case .segmentServed(let path, let index, let bytes, let waited, let transferred)? = event else {
            Issue.record("no .segmentServed: \(probe.events)")
            return
        }
        #expect(path == "seg00007.m4s")
        #expect(index == 7)
        #expect(bytes == 100_000)
        #expect(waited < .milliseconds(1_500), "a file in hand waited \(waited)")
        #expect(transferred < .seconds(2))
        // One segment, one event: not one per chunk or per poll. Looked at again
        // after a moment, so that a late duplicate would be in the list.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await probe.finish().filter { $0.isDelivery }.count == 1)
    }

    /// What "served" means, pinned so the documentation cannot drift from it: the
    /// event comes when the connection has accepted the last byte, not when the
    /// player has read it. A payload within the socket buffers is accepted at once,
    /// whether or not anyone reads it.
    @Test("A small segment is reported once the connection has accepted it, read or not")
    func reportedOnAcceptanceNotOnReading() async throws {
        let probe = DeliveryEventProbe(delivery: true)
        let (server, base) = try await serve(["seg00001.m4s": Data(repeating: 1, count: 100_000)], probe: probe)
        defer { Task { await server.stop() } }

        // A client that sends its request and never reads the answer.
        let client = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(try #require(base.port)))!, using: .tcp
        )
        client.start(queue: .global())
        defer { client.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        client.send(content: Data("GET /seg00001.m4s HTTP/1.1\r\nHost: x\r\n\r\n".utf8), completion: .contentProcessed { _ in })

        let event = await probe.firstEvent { if case .segmentServed = $0 { true } else { false } }
        guard case .segmentServed(_, 1, 100_000, _, _)? = event else {
            Issue.record("a segment within the socket buffers was not reported although the connection took it: \(probe.events)")
            return
        }
    }

    @Test("A rendition's segment keeps its directory in the path and its own number")
    func renditionPaths() async throws {
        let probe = DeliveryEventProbe(delivery: true)
        let (server, base) = try await serve([
            "audio1/seg00012.m4s": Data(repeating: 1, count: 2_000),
            "subs0/seg00003.vtt": Data("WEBVTT\n\n".utf8),
        ], probe: probe)
        defer { Task { await server.stop() } }

        _ = try await URLSession.uncached.data(from: base.appendingPathComponent("audio1/seg00012.m4s"))
        _ = try await URLSession.uncached.data(from: base.appendingPathComponent("subs0/seg00003.vtt"))
        // Two connections: neither is guaranteed to be reported first.
        _ = await probe.waitForCount(2) { $0.isDelivery }

        let served = await probe.finish().compactMap { event -> (String, Int, Int)? in
            if case .segmentServed(let path, let index, let bytes, _, _) = event { return (path, index, bytes) }
            return nil
        }
        #expect(served.count == 2)
        #expect(served.contains { $0 == ("audio1/seg00012.m4s", 12, 2_000) })
        #expect(served.contains { $0 == ("subs0/seg00003.vtt", 3, 8) })
    }

    @Test("Playlists, init segments, misses and HEAD requests are not segments served")
    func notEverythingIsASegment() async throws {
        let probe = DeliveryEventProbe(delivery: true)
        let (server, base) = try await serve([
            "index.m3u8": Data("#EXTM3U\n".utf8),
            "init.mp4": Data(repeating: 2, count: 800),
            "seg00001.m4s": Data(repeating: 3, count: 4_000),
        ], probe: probe)
        defer { Task { await server.stop() } }

        _ = try await URLSession.uncached.data(from: base.appendingPathComponent("index.m3u8"))
        _ = try await URLSession.uncached.data(from: base.appendingPathComponent("init.mp4"))
        _ = try? await URLSession.uncached.data(from: base.appendingPathComponent("seg00009.m4s"))
        var head = URLRequest(url: base.appendingPathComponent("seg00001.m4s"))
        head.httpMethod = "HEAD"
        _ = try await URLSession.uncached.data(for: head)

        // A real segment last, so that when ITS event is in, everything before it
        // has had its chance to produce one.
        _ = try await URLSession.uncached.data(from: base.appendingPathComponent("seg00001.m4s"))
        _ = await probe.firstEvent { $0.isDelivery }
        try await Task.sleep(for: .milliseconds(200))

        let delivered = await probe.finish().filter { $0.isDelivery }
        #expect(delivered.count == 1)
        if case .segmentServed(let path, _, let bytes, _, _)? = delivered.first {
            #expect(path == "seg00001.m4s")
            #expect(bytes == 4_000)
        } else {
            Issue.record("expected the one real segment, got \(delivered)")
        }
    }

    @Test("A segment the producer was still cutting reports the wait as `waited`, and a slow serve says so too")
    func slowServe() async throws {
        let probe = DeliveryEventProbe(delivery: true)
        let (server, base) = try await serve(
            ["seg00002.m4s": Data(repeating: 4, count: 50_000)],
            delay: .seconds(1), threshold: .milliseconds(150), probe: probe
        )
        defer { Task { await server.stop() } }

        let (body, _) = try await URLSession.uncached.data(from: base.appendingPathComponent("seg00002.m4s"))
        #expect(body.count == 50_000)
        _ = await probe.firstEvent { if case .segmentServed = $0 { true } else { false } }

        let events = await probe.finish()
        guard case .segmentServed(_, 2, 50_000, let waited, _)? = events.first(where: {
            if case .segmentServed = $0 { true } else { false }
        }) else {
            Issue.record("no .segmentServed for the slow serve: \(events)")
            return
        }
        // The wait is the producer's second, give or take the scheduler.
        #expect(waited >= .milliseconds(900), "waited \(waited)")
        #expect(waited < .seconds(5))
        // The trouble event is unchanged by the new one beside it.
        #expect(events.contains { if case .slowServe(let path, _) = $0 { path == "seg00002.m4s" } else { false } })
    }

    /// The one fetch that is trouble twice over and still a served segment: a
    /// subtitle segment the producer never cut is answered with an empty WebVTT
    /// after the production window, which is `.serveTimedOut`, and — having waited
    /// past the slow-serve threshold — `.slowServe`, and then the 8 bytes that went
    /// out are a segment served. In that order, through the real provider.
    @Test("A subtitle segment that never lands is reported timed out, slow, and then served as 8 empty bytes")
    func subtitleTimeoutIsReportedThreeWays() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCore-delivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<4).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        ))
        let probe = DeliveryEventProbe(delivery: true)
        var provider = PlanSegmentProvider(root: root, coordinator: coordinator)
        provider.events = probe.sink
        provider.subtitleProductionTimeout = .seconds(1)
        let server = LoopbackHTTPServer(
            provider: provider, limits: .init(slowServeThreshold: .milliseconds(100)), events: probe.sink
        )
        let base = try await server.start()
        defer { Task { await server.stop() } }

        let (body, _) = try await URLSession.uncached.data(from: base.appendingPathComponent("subs0/seg00003.vtt"))
        #expect(body == Data("WEBVTT\n\n".utf8))
        _ = await probe.waitForCount(3) { _ in true }

        let events = await probe.finish()
        guard events.count == 3,
              case .serveTimedOut("subs0/seg00003.vtt") = events[0],
              case .slowServe("subs0/seg00003.vtt", _) = events[1],
              case .segmentServed("subs0/seg00003.vtt", 3, 8, let waited, _) = events[2]
        else {
            Issue.record("expected serveTimedOut, slowServe, segmentServed; got \(events)")
            return
        }
        #expect(waited >= .milliseconds(900), "waited \(waited)")
    }

    @Test("A segment that landed inside the slow-serve threshold still reports what it waited")
    func quickPendingServe() async throws {
        let probe = DeliveryEventProbe(delivery: true)
        let (server, base) = try await serve(
            ["seg00004.m4s": Data(repeating: 5, count: 10_000)],
            delay: .milliseconds(120), threshold: .seconds(2), probe: probe
        )
        defer { Task { await server.stop() } }

        _ = try await URLSession.uncached.data(from: base.appendingPathComponent("seg00004.m4s"))
        let event = await probe.firstEvent { if case .segmentServed = $0 { true } else { false } }
        guard case .segmentServed(_, 4, 10_000, let waited, _)? = event else {
            Issue.record("no .segmentServed: \(probe.events)")
            return
        }
        #expect(waited >= .milliseconds(100), "waited \(waited)")
        #expect(waited < .milliseconds(1_500))
        #expect(!(await probe.finish()).contains { if case .slowServe = $0 { true } else { false } })
    }

    @Test("A stream that did not ask for delivery events hears about a slow serve and nothing else")
    func troubleOnlyStreamStillGetsTrouble() async throws {
        let probe = DeliveryEventProbe(delivery: false)
        let (server, base) = try await serve(
            ["seg00001.m4s": Data(repeating: 6, count: 1_000)],
            delay: .milliseconds(800), threshold: .milliseconds(100), probe: probe
        )
        defer { Task { await server.stop() } }

        _ = try await URLSession.uncached.data(from: base.appendingPathComponent("seg00001.m4s"))
        _ = await probe.firstEvent { if case .slowServe = $0 { true } else { false } }
        try await Task.sleep(for: .milliseconds(200))

        let events = await probe.finish()
        #expect(events.count == 1)
        #expect(events.allSatisfy { !$0.isDelivery })
    }
}

// MARK: - What the source delivers

@Suite("Source throughput", .serialized)
struct SourceThroughputTests {

    /// The premise the whole measurement stands on: the I/O layer's own counter
    /// is what the reader delivered, through whichever reader is under it.
    @Test("AVIOContext.bytes_read is what a host input delivered, to the byte")
    func ioLayerCountsWhatTheHostInputDelivered() throws {
        let input = PacedInput(data: try deliveryFixture("h264_aac_30s"), bytesPerSecond: .infinity)
        let source = try SourceProbe.open(url: deliveryAbsentURL("fixture.mkv"), input: { input })
        // Peeked, not consumed: the source closes its own context when it goes.
        let context = try #require(source.peekContextForTesting())
        defer { withExtendedLifetime(source) {} }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var packets = 0
        while av_read_frame(context, packet) >= 0 {
            packets += 1
            av_packet_unref(packet)
        }
        let pb = try #require(context.pointee.pb)
        #expect(packets > 100)
        #expect(pb.pointee.bytes_read == Int64(input.deliveredBytes))
        // And it is the container's bytes, not the packets': framing, index and
        // headers come off the link too.
        #expect(pb.pointee.bytes_read > 0)
    }

    /// The point of dividing by reading time: a producer that spends most of its
    /// time muxing, writing or parked must not make the source look slow. The
    /// segment-landed seam holds the producer's thread for 150 ms after each cut —
    /// time that is the producer's, not the source's.
    @Test("Time the producer spends doing anything but reading is not in the rate")
    func rateIsOverReadingTimeNotWallTime() async throws {
        let rate = 1_500_000.0
        let input = PacedInput(data: try deliveryFixture("h264_aac_30s"), bytesPerSecond: rate)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreThroughput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let remuxer = HLSRemuxer(
            sourceURL: deliveryAbsentURL("fixture.mkv"), outputDirectory: directory, segmentSeconds: 3, input: { input }
        )
        let readings = OSAllocatedUnfairLock(initialState: [SourceReadMeter.Reading]())
        remuxer.sourceReadWindow = 0.1
        remuxer.onSourceThroughput = { reading in readings.withLock { $0.append(reading) } }
        remuxer.onSegmentLanded = { _ in Thread.sleep(forTimeInterval: 0.15) }

        let started = ContinuousClock.now
        let producer = ProducerThread(name: "prismcore.tests.throughput") { try remuxer.run() }
        defer { remuxer.cancel() }
        let deadline = ContinuousClock.now + .seconds(60)
        while !producer.isFinished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(producer.isFinished, "the producer never finished")
        await producer.join()
        let wall = (ContinuousClock.now - started) / .seconds(1)

        let all = readings.withLock { $0 }
        #expect(all.count >= 5, "only \(all.count) windows")
        let bytes = Double(all.reduce(0) { $0 + $1.bytes })
        let seconds = all.reduce(0) { $0 + $1.seconds }
        // Weighted by the windows' own seconds, the way a host should average.
        // Against what the input itself says it delivered per second inside its
        // reads: the meter also counts the demuxer's own time around them, so it
        // may read a little under, and never over.
        let truth = input.effectiveRate
        #expect(bytes / seconds > truth * 0.9 && bytes / seconds < truth * 1.02,
                "measured \(Int(bytes / seconds)) B/s against an input that delivered \(Int(truth)) B/s inside its reads")
        // The same bytes over the wall clock are what a naive meter would say.
        #expect(bytes / wall < truth * 0.6, "wall-clock rate \(Int(bytes / wall)) B/s: the producer was not held back")
        // Every window is the reading time of the producer, never more than the
        // whole run.
        #expect(seconds < wall)
        // And nothing delivered is invented: what the windows counted came out
        // of the input.
        #expect(bytes <= Double(input.deliveredBytes))
    }

    /// What one session reading a throttled HTTP origin reported, and what a
    /// client fetching every segment of it received.
    private struct Observed {
        var readings: [(rate: Double, bytes: Int64, seconds: Double)] = []
        var served: [(path: String, index: Int, bytes: Int)] = []
        /// Relative path → bytes, as the client saw them.
        var received: [String: Int] = [:]

        /// Σbytes over Σseconds, which is how a host should average readings.
        var pooledRate: Double {
            Double(readings.reduce(0) { $0 + $1.bytes }) / readings.reduce(0) { $0 + $1.seconds }
        }
    }

    private func observeASession(rate: Double, coordinated: Bool, minimumReadings: Int) async throws -> Observed {
        let media = try deliveryFixture("h264_aac_30s")
        let origin = try RangeFixtureServer(media: media, bytesPerSecond: rate, firstByteDelay: 0.005)
        let url = try await origin.start()
        defer { origin.stop() }

        let session = try PrismCoreSession(url: url, coordinatedHTTP: coordinated)
        // At 2.4 MB/s the copy loop reads about a megabyte in 0.4 s, so a 0.1 s
        // window left four or five readings against a minimum of three.
        await session.setSourceReadWindow(0.05)
        let events = await session.playbackEvents(delivery: true)
        let seen = OSAllocatedUnfairLock(initialState: [PlaybackEvent]())
        let drain = Task { for await event in events { seen.withLock { $0.append(event) } } }
        defer { drain.cancel() }

        let playlist: URL
        do { playlist = try await session.start() } catch { await session.stop(); throw error }

        // Fetch every segment of every playlist the way a player would, so there
        // is something to be served — and the production is demanded rather than
        // left to park. The video variant and the audio rendition both, because
        // the path in the event has to say which one it was.
        let (master, _) = try await URLSession.uncached.data(from: playlist)
        let root = playlist.deletingLastPathComponent()
        var observed = Observed()
        let playlists = PrismCoreSession.playlistURIs(inMaster: String(decoding: master, as: UTF8.self))
        #expect(playlists.count >= 2, "expected a video variant and an audio rendition: \(playlists)")
        for uri in playlists {
            let (text, _) = try await URLSession.uncached.data(from: root.appendingPathComponent(uri))
            let directory = (uri as NSString).deletingLastPathComponent
            for name in String(decoding: text, as: UTF8.self).split(separator: "\n").map(String.init) where name.hasSuffix(".m4s") {
                let path = directory.isEmpty ? name : directory + "/" + name
                let (data, _) = try await URLSession.uncached.data(from: root.appendingPathComponent(path))
                observed.received[path] = data.count
            }
        }
        #expect(observed.received.count >= 6)
        // `stop()` drops the sink first, so the last segment's event — yielded a
        // moment after the client has its bytes — has to be in before it.
        let throughputDeadline = ContinuousClock.now + .seconds(10)
        let expectedServed = observed.received.count
        while seen.withLock({ events in
            let windows = events.filter { if case .sourceThroughput = $0 { true } else { false } }.count
            let served = events.filter { if case .segmentServed = $0 { true } else { false } }.count
            return windows < minimumReadings || served < expectedServed
        }), ContinuousClock.now < throughputDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        await session.stop()
        _ = await drain.value

        for event in seen.withLock({ $0 }) {
            switch event {
            case .sourceThroughput(let rate, let bytes, let readTime):
                observed.readings.append((rate, bytes, readTime / .seconds(1)))
            case .segmentServed(let path, let index, let bytes, _, _):
                observed.served.append((path, index, bytes))
            default: break
            }
        }
        return observed
    }

    /// Every segment the client received was reported, with the size it had and
    /// the number in its name; and each reading's own rate is its bytes over its
    /// seconds. True of whichever reader was under the producer.
    private func expectConsistent(_ observed: Observed) {
        for (name, count) in observed.received {
            #expect(observed.served.contains { $0.path == name && $0.bytes == count },
                    "no .segmentServed matching \(name) (\(count) bytes)")
        }
        for served in observed.served {
            #expect(PlanSegmentProvider.segmentIndex(inPath: served.path) == served.index)
        }
        for reading in observed.readings {
            #expect(abs(reading.rate - Double(reading.bytes) / reading.seconds) < 1)
        }
    }

    /// A session reading a real HTTP origin, whose bandwidth is the one thing
    /// the test controls: the number must follow it. Two rates, a factor of four
    /// apart, so a constant offset in the measurement cannot pass for tracking.
    /// libavformat's own HTTP, which is how a plain `http` source is read.
    @Test("What the source delivers follows the origin's bandwidth, over HTTP", arguments: [600_000.0, 2_400_000.0])
    func followsTheOriginsBandwidth(rate: Double) async throws {
        let observed = try await observeASession(rate: rate, coordinated: false, minimumReadings: 3)
        #expect(observed.readings.count >= 3, "only \(observed.readings.count) throughput readings")
        // The origin is the ceiling; the reader may find it slower than its
        // schedule (a request's first byte, a seek) but never much faster.
        #expect(observed.pooledRate > rate * 0.5 && observed.pooledRate < rate * 1.25,
                "measured \(Int(observed.pooledRate)) B/s against an origin of \(Int(rate)) B/s")
        expectConsistent(observed)
    }

    /// The limit of measuring at the I/O layer, pinned so it stays in view. The
    /// coordinated reader fetches 1 MiB blocks and keeps them; the probe has
    /// already fetched the head block by the time the producer starts, so the
    /// producer's reads of it are free, and only the last 0.27 MB of this
    /// fixture is ever waited for. The bytes counted are all 1.27 MB; the time
    /// counted is one small fetch. Over a film, where whole blocks are fetched
    /// inside the loop, the pooled rate is the link's; over a short one the head
    /// start inflates it, and so does a host input with a cache of its own.
    @Test("A reader that fetched ahead delivers cached bytes for nothing, so a short session over-reads")
    func aReaderThatFetchedAheadOverReadsAtFirst() async throws {
        let rate = 600_000.0
        let observed = try await observeASession(rate: rate, coordinated: true, minimumReadings: 1)
        #expect(!observed.readings.isEmpty, "no throughput reading at all")
        #expect(observed.pooledRate > rate * 2,
                "\(Int(observed.pooledRate)) B/s against \(Int(rate)): the head block was expected to be free")
        // Everything else the events say is unaffected by how the bytes arrived.
        expectConsistent(observed)
    }

    /// Both halves, so that the quiet half cannot be vacuous: the same producer
    /// reading the same source is heard by the stream that asked and not by the one
    /// that did not. The input is slow enough (600 KB/s) that the producer is
    /// reading for seconds, and the window short enough that many close.
    @Test("A real producer's delivery events reach the stream that asked for them and no other", arguments: [false, true])
    func realSessionHonoursTheOptIn(delivery: Bool) async throws {
        let input = PacedInput(data: try deliveryFixture("h264_aac_30s"), bytesPerSecond: 600_000)
        let session = try PrismCoreSession(url: deliveryAbsentURL("fixture.mkv"), input: { input })
        await session.setSourceReadWindow(0.05)
        let events = await session.playbackEvents(delivery: delivery)
        let seen = OSAllocatedUnfairLock(initialState: [PlaybackEvent]())
        let drain = Task { for await event in events { seen.withLock { $0.append(event) } } }

        let playlist: URL
        do { playlist = try await session.start() } catch { await session.stop(); throw error }
        let (master, _) = try await URLSession.uncached.data(from: playlist)
        #expect(!master.isEmpty)

        // Long enough for the copy loop to be well into the file: startup has
        // delivered about 250 KB by the time `start()` returns, so this is
        // production, not startup.
        let deadline = ContinuousClock.now + .seconds(15)
        while input.deliveredBytes < 700_000, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let windows = seen.withLock { $0.filter { if case .sourceThroughput = $0 { true } else { false } }.count }
        await session.stop()
        _ = await drain.value

        #expect(input.deliveredBytes >= 700_000, "the producer never got into the file")
        if delivery {
            #expect(windows >= 5, "only \(windows) windows closed for a producer that read \(input.deliveredBytes) bytes")
        } else {
            #expect(seen.withLock { $0 }.allSatisfy { !$0.isDelivery })
        }
    }
}
