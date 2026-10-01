import Foundation

/// One measured startup, rendered as the line a host prints: probe phases,
/// then `start()`'s checkpoints.
///
/// `package` because two callers need the *same* line — the opt-in
/// `StartupCheckpointBenchmark` and `prismcore-cli bench`. The whole point of
/// the line is that a device report and a bench run can be compared term by
/// term; two formatters would drift, and a comparison across a drifted format
/// is a comparison of formatters.
package struct StartupCheckpointRun: Sendable {
    package let probeTiming: ProbeTiming
    /// `probe Nms (open N + info N + describe N)`.
    package var probeLine: String { Self.probeLine(probeTiming) }
    /// `open Nms -> probe Nms -> plan Nms (origin, N seg) -> …`, without the
    /// `startup ` prefix.
    package let checkpoints: [String]
    /// Wall clock from `start()` being called to it returning or throwing.
    package let startDuration: Duration
    /// `start()`'s error, when it threw. The probe line is still worth
    /// printing then: a startup that fails is usually the one being chased.
    package let failure: String?
    /// The prewarm run ahead of the probe, when the caller asked for one.
    /// Timed on its own and kept off the probe line's total: it is work a
    /// host does while the user is still choosing, so folding it into the
    /// startup it is meant to shorten would hide what it bought.
    package let prewarm: SourcePrewarmOutcome?
    /// What the probe's reader made of that prewarm (`nil` when none ran).
    package let prewarmUse: SourcePrewarmUse?

    /// `prewarm Nms (status, N req, N B, index Bool)`, when a prewarm ran.
    package var prewarmLine: String? {
        prewarm.map {
            "prewarm \(Self.ms($0.duration))ms (\($0.status), \($0.requests) req, "
                + "\($0.storedBytes) B, index \($0.indexPrewarmed))"
        }
    }

    /// The three-line block both callers print — four with a prewarm, whose
    /// line comes first and whose use is appended to the probe line. Without
    /// one the block is unchanged, so a run without a prewarm still compares
    /// term by term with a device report.
    package var rendered: String {
        """
        \(prewarmLine.map { $0 + "\n" } ?? "")\(probeLine)\(prewarmUse.map { " prewarm-use \($0)" } ?? "")
        startup \(checkpoints.joined(separator: " -> "))
        start() returned in \(Self.ms(startDuration))ms\(failure.map { " — FAILED: \($0)" } ?? "")
        """
    }

    /// Probe `url`, build a session from the probed context, start it while
    /// collecting checkpoints, and stop it.
    ///
    /// The probe is handed over as a `ProbedSource`, exactly as a host does it:
    /// a second open would add a network round trip the host never pays and
    /// the line would stop describing the host. Throws only when the probe
    /// itself fails — a failed `start()` is a result, recorded in `failure`.
    ///
    /// `prewarm: true` calls `PrismCoreEngine.prewarm` with the same URL and
    /// headers before the probe, as a host would ahead of the play. Only the
    /// coordinated reader consults the prewarm store, so without
    /// `coordinatedHTTP` the use reads `none`.
    package static func measure(
        url: URL,
        httpHeaders: [String: String] = [:],
        budget: Duration,
        coordinatedHTTP: Bool,
        display: DisplayCapabilities = DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true),
        keyframeIndexCacheDirectory: URL? = nil,
        prewarm: Bool = false
    ) async throws -> StartupCheckpointRun {
        let prewarmOutcome: SourcePrewarmOutcome? = prewarm
            ? await PrismCoreEngine.prewarm(url: url, httpHeaders: httpHeaders)
            : nil
        let probed = try SourceProbe.open(
            url: url, httpHeaders: httpHeaders, budget: budget, coordinatedHTTP: coordinatedHTTP
        )
        let session = try PrismCoreSession(
            url: url,
            httpHeaders: httpHeaders,
            display: display,
            probed: probed,
            keyframeIndexCacheDirectory: keyframeIndexCacheDirectory,
            coordinatedHTTP: coordinatedHTTP
        )
        let checkpoints = try await session.startupCheckpoints()
        let collected = Collected()
        let drain = Task {
            for await mark in checkpoints { collected.append(Self.describe(mark)) }
        }
        let start = ContinuousClock.now
        var failure: String?
        do { _ = try await session.start() } catch { failure = "\(error)" }
        let elapsed = ContinuousClock.now - start
        // `start()` finishes the stream on every exit, so awaiting the drain
        // cannot hang — and it is what guarantees `.playlistServable` made it
        // into the line rather than racing a cancel.
        await drain.value
        await session.stop()

        return StartupCheckpointRun(
            probeTiming: probed.timing,
            checkpoints: collected.marks,
            startDuration: elapsed,
            failure: failure,
            prewarm: prewarmOutcome,
            prewarmUse: prewarmOutcome == nil ? nil : probed.prewarm
        )
    }

    package static func probeLine(_ timing: ProbeTiming) -> String {
        "probe \(ms(timing.total))ms"
            + " (open \(ms(timing.open))"
            + " + info \(ms(timing.streamInfo))"
            + " + describe \(ms(timing.describe)))"
    }

    package static func describe(_ mark: StartupCheckpoint) -> String {
        let at = ms(mark.elapsed)
        switch mark.phase {
        case .sourceOpened: return "open \(at)ms"
        case .streamInfoResolved: return "probe \(at)ms"
        case .segmentPlanReady(let origin, let segments):
            return "plan \(at)ms (\(origin.rawValue), \(segments) seg)"
        case .firstVideoSegmentWritten: return "segment \(at)ms"
        case .playlistServable: return "servable \(at)ms"
        }
    }

    package static func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var marks: [String] { lock.withLock { stored } }
    }
}
