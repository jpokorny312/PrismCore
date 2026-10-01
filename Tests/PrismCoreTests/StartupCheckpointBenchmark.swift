import Testing
import Foundation
@testable import PrismCore

/// The field log's startup line, reproduced on the bench.
///
/// `StartupCostBenchmark` measures the pieces a host cannot see (a second
/// open, the readiness gate); this measures the line a host actually prints —
/// probe phases, then `start()`'s checkpoints — so a device report and a
/// bench run can be compared term by term instead of by intuition. The
/// 2026-09-19 report that started this work read
/// `probe 10583ms (open 10560 …) … plan 7344ms (builtFromSource, 591 seg)`,
/// and nothing in the suite produced a number of the same shape.
///
/// Opt-in: `PRISMCORE_BENCH` is a path or an `http://` URL. Use HTTP — see
/// AGENTS.md *Measuring*.
@Suite(
    "Startup checkpoints",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_BENCH"] != nil),
    .serialized
)
struct StartupCheckpointBenchmark {

    private var mediaURL: URL {
        let raw = ProcessInfo.processInfo.environment["PRISMCORE_BENCH"]!
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw)! }
        return URL(fileURLWithPath: raw)
    }

    @Test("probe phases then start() checkpoints")
    func checkpointLine() async throws {
        // The integrating host's own network budget, so a bench run fails
        // where a device would rather than where PrismCore's smaller default
        // would.
        let budget = ProcessInfo.processInfo.environment["PRISMCORE_BENCH_PROBE_BUDGET_SECONDS"]
            .flatMap(Int.init) ?? 20
        // The transport is the variable this bench exists to compare, so it
        // is a knob rather than the default: FFmpeg's native HTTP asks for
        // `bytes=N-` and lets the origin stream, the coordinated reader asks
        // for bounded blocks.
        let coordinatedHTTP =
            ProcessInfo.processInfo.environment["PRISMCORE_BENCH_COORDINATED_HTTP"] == "1"
        // A prewarm ahead of the probe, timed on its own line: it is work a
        // host does while the user is still choosing, so it must not be
        // folded into the startup it is meant to shorten. Only the
        // coordinated reader consults the prewarm store.
        let prewarm = ProcessInfo.processInfo.environment["PRISMCORE_BENCH_PREWARM"] == "1"
        // The measurement and the line live in `StartupCheckpointRun` so that
        // `prismcore-cli bench` prints exactly this, not a lookalike.
        let run = try await StartupCheckpointRun.measure(
            url: mediaURL,
            budget: .seconds(budget),
            coordinatedHTTP: coordinatedHTTP,
            keyframeIndexCacheDirectory: ProcessInfo.processInfo
                .environment["PRISMCORE_BENCH_KEYFRAME_CACHE"].map(URL.init(fileURLWithPath:)),
            prewarm: prewarm
        )
        print("\n\(run.rendered)\n")
    }
}
