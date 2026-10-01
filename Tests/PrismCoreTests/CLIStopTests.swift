#if os(macOS)
import Testing
import Foundation
@testable import prismcore_cli
@testable import PrismCore

/// A Ctrl-C has to end `serve` / `segverify` / `validate` in every phase, and
/// the two phases that do not observe task cancellation — a probe blocked in
/// a read, a `start()` waiting on its producer — are exactly where a starved
/// origin parks them. Each test stalls one phase for good and fires the stop
/// shortly after; the bound it asserts is seconds against a budget of a
/// minute, so a pass is the stop reaching the phase, not a lucky race.
@Suite("CLI stop", .serialized)
struct CLIStopTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func options(_ source: URL) -> SourceOptions {
        var options = SourceOptions()
        options.source = source
        // Far longer than any bound below: only the stop can end the wait.
        options.budget = .seconds(60)
        return options
    }

    /// Runs `withServedSession` to its end and returns how it ended.
    private func served(
        _ options: SourceOptions, stop: StopSignal, bodyRan: Flag = Flag()
    ) async -> (failure: CLIFailure?, elapsed: Duration) {
        let clock = ContinuousClock()
        let begin = clock.now
        do {
            try await withServedSession(options, stop: stop) { _ in bodyRan.set() }
            return (nil, clock.now - begin)
        } catch {
            return (error as? CLIFailure, clock.now - begin)
        }
    }

    @Test("Ctrl-C during a stalled probe interrupts it (exit 130), not the budget")
    func stopInterruptsStalledProbe() async throws {
        let origin = try ScriptedHTTPServer { _ in .stall }
        let root = try await origin.start()
        defer { origin.stop() }
        let stop = StopSignal(watchStdin: false)
        stop.fire(after: .milliseconds(300), "interrupted")
        let bodyRan = Flag()

        let (failure, elapsed) = await served(
            options(root.appendingPathComponent("source.mkv")), stop: stop, bodyRan: bodyRan
        )
        #expect(failure?.code == .interrupted, "ended with \(String(describing: failure))")
        #expect(elapsed < .seconds(10), "the stop waited for the probe: \(elapsed)")
        #expect(!bodyRan.value)
        #expect(!origin.requests.isEmpty, "the probe never reached the origin; nothing was stalled")
    }

    /// The probe is served; everything after its first request stalls, so
    /// `start()` waits on a producer parked in a read.
    @Test("Ctrl-C during a stalled start() interrupts it (exit 130) and stops the session")
    func stopInterruptsStalledStart() async throws {
        let media = try Data(contentsOf: try fixture("h264_aac_30s.mkv"))
        let stalled = Counter()
        // Answered while the probe is running, stalled from the moment the
        // session exists: the open (with `.none` structure) never needs what
        // the remuxer's plan does.
        let sessionStarted = Flag()
        let origin = try ScriptedHTTPServer { request in
            if sessionStarted.value { _ = stalled.next(); return .stall }
            return ScriptedHTTPServer.ranged(media, for: request)
        }
        let root = try await origin.start()
        defer { origin.stop() }
        var options = options(root.appendingPathComponent("source.mkv"))
        options.coordinatedHTTP = true

        let stop = StopSignal(watchStdin: false)
        let bodyRan = Flag()
        let clock = ContinuousClock()
        let begin = clock.now
        var failure: CLIFailure?
        do {
            // The stall begins exactly when the probe has finished, and the
            // stop is armed then too, so it can only land inside `start()`.
            try await withServedSession(options, stop: stop, afterProbe: {
                sessionStarted.set()
                stop.fire(after: .milliseconds(300), "interrupted")
            }) { _ in bodyRan.set() }
        } catch {
            failure = error as? CLIFailure
        }
        let elapsed = clock.now - begin
        #expect(failure?.code == .interrupted, "ended with \(String(describing: failure))")
        #expect(elapsed < .seconds(15), "the stop waited for start(): \(elapsed)")
        #expect(!bodyRan.value, "start() returned a playlist — nothing was stalled")
        #expect(stalled.next() > 0, "start() never asked the origin for anything; nothing was stalled")
    }

    @Test("A stop already pending when the probe finishes starts no session")
    func pendingStopStartsNothing() async throws {
        let stop = StopSignal(watchStdin: false)
        let probed = Flag()
        let bodyRan = Flag()
        var failure: CLIFailure?
        do {
            try await withServedSession(options(try fixture("h264_aac_30s.mkv")), stop: stop, afterProbe: {
                probed.set()
                stop.fire("interrupted")
            }) { _ in bodyRan.set() }
        } catch {
            failure = error as? CLIFailure
        }
        #expect(probed.value)
        #expect(failure?.code == .interrupted)
        #expect(!bodyRan.value)
    }

    @Test("A stop during the body ends it as an interrupt, not as the work's own error")
    func stopDuringWorkIsInterrupt() async throws {
        let stop = StopSignal(watchStdin: false)
        stop.fire(after: .milliseconds(100), "interrupted")
        let parked = Parked()
        await #expect(throws: CLIFailure.self) {
            // Work that ignores cancellation entirely: it ends only when the
            // test releases it below, long after the stop has won.
            _ = try await untilStopped(stop) { () async -> Int in
                await withCheckedContinuation { parked.hold($0) }
                return 0
            }
        }
        // Resumed rather than dropped: a checked continuation that is never
        // resumed is reported as a leak, and the worker task would outlive
        // the test.
        parked.release()
        // And a work that wins is returned as itself.
        #expect(try await untilStopped(StopSignal(watchStdin: false)) { 7 } == 7)
    }

    @Test("A check that could not be made is exit 69, never ok; a problem outranks it")
    func unverifiedIsNotOK() {
        var report = SegmentVerifier.Report()
        #expect(SegVerifyCommand.summarize(report) == .ok)
        report.findings.append(.init(severity: .unverified, location: "v.m3u8", problem: "stream 0 (h264): no decoder"))
        #expect(SegVerifyCommand.summarize(report) == .unavailable)
        report.findings.append(.init(severity: .error, location: "v.m3u8 → s.m4s", problem: "not a keyframe"))
        #expect(SegVerifyCommand.summarize(report) == .checkFailed)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}

/// A continuation held by work that must not finish until the test says so.
/// Release before hold resumes at once, so the order of the two cannot hang.
private final class Parked: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = lock.withLock { () -> Bool in
            if released { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }
    func release() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { continuation = nil }
            return continuation
        }
        held?.resume()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}
#endif
