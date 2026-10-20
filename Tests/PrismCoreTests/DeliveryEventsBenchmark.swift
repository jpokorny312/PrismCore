import Testing
import Foundation
import AVFoundation
import os
@testable import PrismCore
import Libavformat

/// What the delivery events cost, and how the numbers they carry relate to what
/// AVPlayer's access log says about the same playback. Opt-in, like the other
/// harnesses: `PRISMCORE_EVENTS_BENCH=1 swift test --filter DeliveryEventsBenchmark`.
///
/// Prints, asserts almost nothing: these are measurements to read, and a
/// threshold on a timing is how a suite becomes flaky. The one thing it does
/// assert is that the harness itself saw what it was meant to see (a player
/// that never became ready measures nothing).
///
/// The origin is `RangeFixtureServer`, whose one bandwidth schedule is shared by
/// every connection: its configured rate is a ceiling the session cannot exceed,
/// which is the ground truth the reported numbers are held against. Over HTTP, on
/// purpose — see AGENTS.md *Measuring*.
@Suite(
    "Delivery events benchmark",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_EVENTS_BENCH"] != nil),
    .serialized
)
struct DeliveryEventsBenchmark {

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    // MARK: Cost

    /// The producer-side price of handing one event to the stream, in the four
    /// states a session can be in. Nanoseconds per `yield`, the best of several
    /// batches (the minimum is the least disturbed one) beside the median.
    @Test("What one yield costs, by state of the stream")
    func costOfOneYield() async throws {
        let event = PlaybackEvent.segmentServed(
            path: "audio1/seg00123.m4s", index: 123, bytes: 1_234_567, waited: .milliseconds(3), transferred: .milliseconds(1)
        )
        let batch = 200_000

        func nanosecondsPerYield(_ sink: PlaybackEventSink) -> Double {
            let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<batch { sink.yield(event) }
            return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / Double(batch)
        }
        func measure(_ sink: PlaybackEventSink) -> [Double] {
            _ = nanosecondsPerYield(sink)  // warm
            return (0..<9).map { _ in nanosecondsPerYield(sink) }
        }

        let unobserved = PlaybackEventSink()

        let troubleOnly = PlaybackEventSink()
        let (_, troubleContinuation) = AsyncStream<PlaybackEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        troubleOnly.replace(with: troubleContinuation, delivery: false)

        let undrained = PlaybackEventSink()
        let (_, undrainedContinuation) = AsyncStream<PlaybackEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        undrained.replace(with: undrainedContinuation, delivery: true)

        let drained = PlaybackEventSink()
        let (drainedStream, drainedContinuation) = AsyncStream<PlaybackEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        drained.replace(with: drainedContinuation, delivery: true)
        let counted = OSAllocatedUnfairLock(initialState: 0)
        let reader = Task { for await _ in drainedStream { counted.withLock { $0 += 1 } } }

        var lines = ["", "yield() per event, ns (median of 9 batches of \(batch); min–max)"]
        for (name, sink) in [
            ("nobody registered                 ", unobserved),
            ("registered, trouble only (filtered)", troubleOnly),
            ("delivery, never read (drops oldest)", undrained),
            ("delivery, drained by a task       ", drained),
        ] {
            let samples = measure(sink)
            lines.append(String(format: "  %@  %7.1f   (%.1f–%.1f)", name as NSString,
                                Self.median(samples), samples.min() ?? 0, samples.max() ?? 0))
        }
        drained.replace(with: nil)
        await reader.value
        lines.append("  (the draining task saw \(counted.withLock { $0 }) of the yields; the rest were dropped oldest-first, as designed)")
        print(lines.joined(separator: "\n"))
    }

    /// The price of one served segment through the real server, with and
    /// without the events. A 1 MB segment through loopback HTTP takes about a
    /// millisecond; an event is nanoseconds to a microsecond, so this does not
    /// try to resolve the difference — it bounds it by the noise, which is the
    /// honest statement. Rounds interleave the four configurations so that drift
    /// in the machine does not look like a difference between them.
    @Test("What a segment costs to serve, with and without events")
    func costPerSegmentThroughTheServer() async throws {
        let payload = Data(repeating: 9, count: 1_000_000)
        let provider = DeliveryStubProvider(files: ["seg00001.m4s": payload])

        let drained = DeliveryEventProbe(delivery: true)
        let troubleOnly = DeliveryEventProbe(delivery: false)
        let undrained = PlaybackEventSink()
        let (_, undrainedContinuation) = AsyncStream<PlaybackEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        undrained.replace(with: undrainedContinuation, delivery: true)

        let configurations: [(name: String, server: LoopbackHTTPServer)] = [
            ("no stream registered            ", LoopbackHTTPServer(provider: provider)),
            ("registered, trouble only        ", LoopbackHTTPServer(provider: provider, events: troubleOnly.sink)),
            ("delivery, drained               ", LoopbackHTTPServer(provider: provider, events: drained.sink)),
            ("delivery, never read            ", LoopbackHTTPServer(provider: provider, events: undrained)),
        ]
        var urls: [URL] = []
        for configuration in configurations {
            urls.append(try await configuration.server.start().appendingPathComponent("seg00001.m4s"))
        }

        let perRound = 150
        var medians = Array(repeating: [Double](), count: configurations.count)
        var all = Array(repeating: [Double](), count: configurations.count)
        for round in 0..<7 {
            // A different starting point every round.
            for offset in 0..<configurations.count {
                let index = (offset + round) % configurations.count
                var times: [Double] = []
                for request in 0..<(perRound + 20) {
                    let started = ContinuousClock.now
                    let (body, _) = try await URLSession.uncached.data(from: urls[index])
                    let elapsed = (ContinuousClock.now - started) / .seconds(1) * 1_000_000
                    #expect(body.count == 1_000_000)
                    if request >= 20 { times.append(elapsed) }  // the first few warm the connection
                }
                medians[index].append(Self.median(times))
                all[index].append(contentsOf: times)
            }
        }
        var lines = ["", "one 1 MB segment through the loopback server, µs per request (\(7 * perRound) requests each)"]
        for (index, configuration) in configurations.enumerated() {
            lines.append(String(
                format: "  %@ median %7.1f  (round medians %.1f–%.1f)  p90 %7.1f",
                configuration.name as NSString, Self.median(medians[index]),
                medians[index].min() ?? 0, medians[index].max() ?? 0, Self.percentile(all[index], 0.9)
            ))
        }
        let drainedEvents = await drained.finish().filter { $0.isDelivery }.count
        lines.append("  (the drained stream received \(drainedEvents) delivery events for \(7 * (perRound + 20)) requests)")
        print(lines.joined(separator: "\n"))
        for configuration in configurations { await configuration.server.stop() }
    }

    /// The statements the copy loop gained per packet: one more clock read, two
    /// loads of the I/O layer's byte counter, a branch on whether anyone measures,
    /// and `record`. Measured in isolation against the clock read the loop
    /// already made, written the way the loop writes them.
    @Test("What the meter adds per packet")
    func costOfTheMeterPerPacket() throws {
        let input = PacedInput(data: try deliveryFixture("h264_aac_30s"), bytesPerSecond: .infinity)
        let source = try SourceProbe.open(url: deliveryAbsentURL("fixture.mkv"), input: { input })
        let context = try #require(source.peekContextForTesting())
        defer { withExtendedLifetime(source) {} }

        let iterations = 5_000_000
        func timed(_ body: () -> Int64) -> Double {
            var best = Double.infinity
            for _ in 0..<7 {
                let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let sink = body()
                let elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / Double(iterations)
                best = min(best, elapsed)
                if sink == .min { print("") }  // keeps the result alive
            }
            return best
        }

        let before = timed {
            var sink: Int64 = 0
            for _ in 0..<iterations { sink &+= Int64(ProcessInfo.processInfo.systemUptime * 1_000) }
            return sink
        }
        var meter = SourceReadMeter(window: 1)
        // Not a constant the optimizer can fold away: the loop reads it once, from
        // a property, and branches on it per packet.
        let metering = ProcessInfo.processInfo.environment["PRISMCORE_EVENTS_BENCH"] != nil
        let after = timed {
            var sink: Int64 = 0
            for _ in 0..<iterations {
                let started = metering ? ProcessInfo.processInfo.systemUptime : 0
                let pulledBefore = metering ? context.pointee.pb?.pointee.bytes_read : nil
                let ended = ProcessInfo.processInfo.systemUptime
                if metering, let pulledBefore, let pulledAfter = context.pointee.pb?.pointee.bytes_read,
                   let reading = meter.record(bytes: pulledAfter - pulledBefore, seconds: ended - started) {
                    sink &+= reading.bytes
                }
                sink &+= Int64(ended * 1_000)
            }
            return sink
        }
        print(String(
            format: "\nper packet: the loop's own clock read %.1f ns; with the meter's statements %.1f ns; added %.1f ns"
                + " (a 4K remux at 300 packets/s: %.2f µs per second of media, one core is 1 000 000)",
            before, after, after - before, (after - before) * 300 / 1_000
        ))
    }

    // MARK: Truth

    private struct Run {
        var rate: Double
        var windows: [(bytes: Int64, seconds: Double)] = []
        var served: [(path: String, bytes: Int, waited: Double, transferred: Double)] = []
        var log: [(uri: String, requests: Int, bytes: Int64, transfer: Double, observed: Double, indicated: Double, stalls: Int)] = []
        var playedSeconds = 0.0
        var startupSeconds = 0.0
    }

    /// One playback by a real AVPlayer of a session reading `rate` bytes a second
    /// from its origin, for `seconds` after `play()`.
    private func play(rate: Double, seconds: Double, window: Double, coordinated: Bool) async throws -> Run {
        let media = try deliveryFixture("h264_aac_30s")
        let origin = try RangeFixtureServer(media: media, bytesPerSecond: rate, firstByteDelay: 0.02)
        let url = try await origin.start()
        defer { origin.stop() }

        var run = Run(rate: rate)
        let session = try PrismCoreSession(url: url, coordinatedHTTP: coordinated)
        await session.setSourceReadWindow(window)
        let events = await session.playbackEvents(delivery: true)
        let seen = OSAllocatedUnfairLock(initialState: [PlaybackEvent]())
        let drain = Task { for await event in events { seen.withLock { $0.append(event) } } }

        let begun = ContinuousClock.now
        let playlist: URL
        do { playlist = try await session.start(startupTimeout: .seconds(120)) } catch { await session.stop(); throw error }

        let item = AVPlayerItem(url: playlist)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let readyDeadline = ContinuousClock.now + .seconds(120)
        while item.status != .readyToPlay {
            if item.status == .failed || ContinuousClock.now >= readyDeadline {
                await session.stop()
                Issue.record("the item never became ready (\(String(describing: item.error)))")
                return run
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        run.startupSeconds = (ContinuousClock.now - begun) / .seconds(1)
        player.play()
        try await Task.sleep(for: .seconds(seconds))
        run.playedSeconds = player.currentTime().seconds

        for event in item.accessLog()?.events ?? [] {
            run.log.append((
                uri: event.uri.map { URL(string: $0)?.lastPathComponent ?? $0 } ?? "?",
                requests: event.numberOfMediaRequests, bytes: event.numberOfBytesTransferred,
                transfer: event.transferDuration, observed: event.observedBitrate,
                indicated: event.indicatedBitrate, stalls: event.numberOfStalls
            ))
        }
        player.pause()
        await session.stop()
        _ = await drain.value

        for event in seen.withLock({ $0 }) {
            switch event {
            case .sourceThroughput(_, let bytes, let readTime): run.windows.append((bytes, readTime / .seconds(1)))
            case .segmentServed(let path, _, let bytes, let waited, let transferred):
                run.served.append((path, bytes, waited / .seconds(1), transferred / .seconds(1)))
            default: break
            }
        }
        return run
    }

    @Test("What the stream says against what the access log says, over HTTP")
    func relationToTheAccessLog() async throws {
        let environment = ProcessInfo.processInfo.environment
        let window = environment["PRISMCORE_EVENTS_BENCH_WINDOW"].flatMap(Double.init) ?? 0.25
        let repetitions = environment["PRISMCORE_EVENTS_BENCH_REPEAT"].flatMap(Int.init) ?? 1
        let coordinated = environment["PRISMCORE_EVENTS_BENCH_COORDINATED"] == "1"
        let seconds = environment["PRISMCORE_EVENTS_BENCH_SECONDS"].flatMap(Double.init) ?? 12
        let rates = environment["PRISMCORE_EVENTS_BENCH_RATES"]
            .map { $0.split(separator: ",").compactMap { Double($0) } } ?? [30_000, 120_000, 600_000, 3_000_000]

        func kilobytes(_ value: Double) -> String { value.isFinite ? String(format: "%9.1f", value / 1_000) : "        -" }

        var lines = [
            "",
            "origin ceiling vs. the stream's source throughput vs. AVPlayer's access log (KB/s; \(Int(seconds)) s of playback, window \(window) s, "
                + (coordinated ? "coordinated reader" : "libavformat HTTP") + ")",
            "  origin | stream: Σbytes/Σreading (windows, per-window mean ± sd) | log: largest event observedBitrate, bytes/transferDuration | stalls | segments: n, waited max, transferred max (s) | startup, played",
        ]
        for rate in rates {
            for _ in 0..<repetitions {
                let run = try await play(rate: rate, seconds: seconds, window: window, coordinated: coordinated)
                let totalBytes = Double(run.windows.reduce(0) { $0 + $1.bytes })
                let totalSeconds = run.windows.reduce(0) { $0 + $1.seconds }
                let pooled = totalSeconds > 0 ? totalBytes / totalSeconds : .nan
                let perWindow = run.windows.map { $0.seconds > 0 ? Double($0.bytes) / $0.seconds : 0 }
                let mean = perWindow.isEmpty ? Double.nan : perWindow.reduce(0, +) / Double(perWindow.count)
                let deviation = perWindow.count > 1
                    ? (perWindow.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(perWindow.count - 1)).squareRoot()
                    : Double.nan
                let largest = run.log.max { $0.bytes < $1.bytes }
                let logObserved = (largest?.observed ?? .nan) / 8
                let logRate = largest.map { $0.transfer > 0 ? Double($0.bytes) / $0.transfer : .nan } ?? .nan
                let stalls = run.log.reduce(0) { $0 + $1.stalls }
                lines.append(String(
                    format: "  %@ | %@ (%d windows, %@ ± %@) | %@, %@ | %d | %d, %.2f, %.3f | %.1f s, %.1f s",
                    kilobytes(rate) as NSString, kilobytes(pooled) as NSString, run.windows.count,
                    kilobytes(mean) as NSString, kilobytes(deviation) as NSString,
                    kilobytes(logObserved) as NSString, kilobytes(logRate) as NSString, stalls,
                    run.served.count, run.served.map(\.waited).max() ?? 0, run.served.map(\.transferred).max() ?? 0,
                    run.startupSeconds, run.playedSeconds
                ))
                for entry in run.log {
                    lines.append(String(
                        format: "      log %@: %d requests, %lld bytes in %.3f s, observed %@, indicated %@",
                        entry.uri as NSString, entry.requests, entry.bytes, entry.transfer,
                        kilobytes(entry.observed / 8) as NSString, kilobytes(entry.indicated / 8) as NSString
                    ))
                }
                #expect(run.playedSeconds > 0 || run.windows.count > 0 || !run.served.isEmpty, "the run observed nothing")
            }
        }
        print(lines.joined(separator: "\n"))
    }
}
