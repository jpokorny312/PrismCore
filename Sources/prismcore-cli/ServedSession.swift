#if os(macOS)
import Foundation
import PrismCore

/// Probe, route, and start a remux session the way a host does — the probed
/// context is handed to the session, never re-opened — then run `body` with
/// the playlist URL and stop the session on every way out.
///
/// `stop` reaches every phase, not only `body`: the probe and `start()` are
/// where a starved origin parks the process for a whole budget, and a
/// Ctrl-C there has to end it now (exit 130) rather than when the budget
/// runs out. Neither of them observes task cancellation — the probe is a
/// blocking open on its own thread, `start()` waits on the producer — so
/// each is raced against `stop` with `untilStopped`, and the session is
/// stopped under a `start()` that lost the race.
///
/// `afterProbe` runs between the two, and exists for the tests: it is the
/// one moment a test can make the origin stall `start()` without stalling
/// the probe too.
func withServedSession<T>(
    _ options: SourceOptions,
    stop: StopSignal,
    afterProbe: () -> Void = {},
    _ body: (URL) async throws -> T
) async throws -> T {
    let (probed, decision) = try await untilStopped(stop) { try await probeAndRoute(options) }
    afterProbe()
    guard decision.engine == .remux else {
        throw CLIFailure(
            code: .notRemuxable,
            message: "routes to the \(decision.engine.rawValue) path, not remux — nothing to serve (\(decision.reason))"
        )
    }
    // A stop that landed while the probe was finishing: starting a session
    // only to tear it down would spin up a producer and a listener for
    // nothing.
    if let reason = stop.reason { throw CLIFailure.interrupted(reason) }
    let session = try PrismCoreSession(
        url: probed.url,
        httpHeaders: options.headers,
        display: options.display,
        probed: probed,
        coordinatedHTTP: options.coordinatedHTTP
    )
    let playlist: URL
    do {
        playlist = try await untilStopped(stop) { try await session.start() }
    } catch let failure as CLIFailure {
        // Interrupted mid-start. `stop()` is what ends the abandoned
        // `start()` too: it cancels the producer, and `start()` returns as
        // soon as it sees the producer finished.
        await session.stop()
        throw failure
    } catch {
        await session.stop()
        throw CLIFailure(code: .checkFailed, message: "session failed to start: \(error)")
    }
    do {
        let result = try await body(playlist)
        await session.stop()
        return result
    } catch {
        await session.stop()
        throw error
    }
}

/// The probe plus `PrismCoreEngine.decide`, with both failures mapped to
/// the exit code that says which of the two it was.
///
/// Detached: the open blocks for up to its budget, and on the cooperative
/// pool that would also hold the thread the stop race needs to answer on.
func probeAndRoute(
    _ options: SourceOptions,
    structure: SourceStructureExport = .none
) async throws -> (ProbedSource, PrismCoreEngine.Decision) {
    let probed: ProbedSource
    do {
        probed = try await SourceProbe.openDetached(
            url: options.source!,
            httpHeaders: options.headers,
            budget: options.budget ?? SourceOpenTuning.probeBudget,
            coordinatedHTTP: options.coordinatedHTTP,
            structure: structure
        )
    } catch {
        throw CLIFailure(code: .probeFailed, message: "probe failed: \(PrismCoreError.classify(error))")
    }
    do {
        return (probed, try PrismCoreEngine.decide(for: probed.info))
    } catch {
        throw CLIFailure(code: .notRemuxable, message: "declined: \(error)")
    }
}

/// Fires once, on the first of: Ctrl-C, SIGTERM, Enter on stdin (when
/// watched), or a deadline. Any number of tasks may wait on it; a waiter
/// whose task is cancelled returns `nil` instead of hanging.
///
/// stdin at EOF is deliberately *not* a stop: `serve` run from a script or
/// with `< /dev/null` would otherwise tear the session down the instant it
/// came up.
final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<String?, Never>] = [:]
    private var firedReason: String?
    private var sources: [DispatchSourceSignal] = []

    init(watchStdin: Bool) {
        for number in [SIGINT, SIGTERM] {
            // Ignored at the process level so the dispatch source, not the
            // default handler, sees it — the default would exit without
            // `stop()`, leaving the session's work directory behind in tmp.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                self?.fire(number == SIGINT ? "interrupted" : "terminated")
            }
            source.resume()
            sources.append(source)
        }
        if watchStdin {
            Thread.detachNewThread { [weak self] in
                if readLine() != nil { self?.fire("Enter pressed") }
            }
        }
    }

    func fire(after delay: Duration, _ why: String) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.fire(why)
        }
    }

    /// Why it fired, or `nil` while it has not.
    var reason: String? { lock.withLock { firedReason } }

    func fire(_ why: String) {
        let released: [CheckedContinuation<String?, Never>] = lock.withLock {
            guard firedReason == nil else { return [] }
            firedReason = why
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        released.forEach { $0.resume(returning: why) }
    }

    /// The stop's reason, or `nil` when the waiting task was cancelled first.
    func wait() async -> String? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: String?? = lock.withLock {
                    if let firedReason { return .some(firedReason) }
                    if Task.isCancelled { return .some(nil) }
                    waiters[id] = continuation
                    return .none
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let waiting = lock.withLock { waiters.removeValue(forKey: id) }
            waiting?.resume(returning: nil)
        }
    }
}

/// Run `work` until it finishes or `stop` fires, whichever is first, and on
/// a stop throw `CLIFailure.interrupted` *without waiting for `work`*.
///
/// Not a task group, on purpose: a group cannot return before every child
/// has, and the work this guards — a probe blocked in a read, a `start()`
/// waiting on its producer, a validator child process — does not end on
/// cancellation. Waiting for it is exactly the hang a Ctrl-C is meant to
/// break. The work is cancelled (a URLSession fetch does end on that) and
/// left to finish on its own; the caller tears down what it started, and the
/// process exits.
func untilStopped<T: Sendable>(
    _ stop: StopSignal,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let outcome = FirstOutcome(continuation)
        let worker = Task {
            do { outcome.resolve(.success(try await work())) } catch { outcome.resolve(.failure(error)) }
        }
        let watcher = Task {
            if let reason = await stop.wait() {
                // Decide the race first: cancelled work that honours
                // cancellation throws `CancellationError` at once, and if it
                // resolved first a Ctrl-C would exit 1 instead of 130.
                outcome.resolve(.failure(CLIFailure.interrupted(reason)))
                worker.cancel()
            }
        }
        // A watcher left waiting after the work won would hold its task
        // for the rest of the process.
        outcome.whenResolved { watcher.cancel() }
    }
}

/// A continuation resumed by the first of several racers; the rest are
/// ignored.
private final class FirstOutcome<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var cleanup: (() -> Void)?

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    /// Run `action` once the race is decided (now, if it already is).
    func whenResolved(_ action: @escaping () -> Void) {
        let decided = lock.withLock { () -> Bool in
            if continuation == nil { return true }
            cleanup = action
            return false
        }
        if decided { action() }
    }

    func resolve(_ result: Result<T, any Error>) {
        let (continuation, cleanup) = lock.withLock { () -> (CheckedContinuation<T, any Error>?, (() -> Void)?) in
            defer { self.continuation = nil; self.cleanup = nil }
            return (self.continuation, self.cleanup)
        }
        guard let continuation else { return }
        cleanup?()
        continuation.resume(with: result)
    }
}

extension CLIFailure {
    static func interrupted(_ reason: String) -> CLIFailure {
        CLIFailure(code: .interrupted, message: reason)
    }
}
#endif
