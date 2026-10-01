#if os(macOS)
import Foundation
import PrismCore

// MARK: - probe

enum ProbeCommand {
    static func run(_ arguments: [String]) async throws -> ExitCode {
        var structure = SourceStructureExport.layout
        var reader = ArgumentReader(arguments)
        try reader.parse { flag, reader in
            guard flag == "--structure" else { return false }
            switch try reader.value(for: flag) {
            case "none": structure = .none
            case "layout": structure = .layout
            case "full": structure = .full
            case let other: throw reader.usage("--structure takes none, layout or full, not \"\(other)\"")
            }
            return true
        }
        let options = reader.options

        let probed: ProbedSource
        do {
            probed = try SourceProbe.open(
                url: options.source!,
                httpHeaders: options.headers,
                budget: options.budget ?? SourceOpenTuning.probeBudget,
                coordinatedHTTP: options.coordinatedHTTP,
                structure: structure
            )
        } catch {
            throw CLIFailure(code: .probeFailed, message: "probe failed: \(PrismCoreError.classify(error))")
        }
        print(render(probed.info))
        print(render(probed.structure))
        print(StartupCheckpointRun.probeLine(probed.timing))
        print("audio bridge (EAC3 encoder) in this build: \(PrismCoreEngine.isAudioBridgeAvailable ? "yes" : "no")")
        // The verdict is the answer a probe exists for, so a decline is
        // printed as a verdict and exits 0 — the probe itself worked.
        do {
            let decision = try PrismCoreEngine.decide(for: probed.info)
            print("verdict: \(decision.engine.rawValue) — \(decision.reason)")
        } catch {
            print("verdict: decline — \(error)")
        }
        return .ok
    }

    static func render(_ info: SourceInfo) -> String {
        var lines = ["source: \(info.formatName)"
            + (info.duration.map { String(format: ", %.3fs", $0) } ?? ", duration unknown")
            + ", native readiness \(info.nativeReadiness.rawValue)"]
        if let video = info.video {
            var parts = ["#\(video.streamIndex) \(video.codecName)"]
            if let profile = video.profileName { parts.append(profile) }
            parts.append("\(video.width)x\(video.height)")
            if let sar = video.sampleAspectRatio, sar.numerator != sar.denominator {
                parts.append("SAR \(sar.numerator):\(sar.denominator)")
            }
            if let depth = video.bitDepth { parts.append("\(depth)-bit") }
            if let rate = video.frameRate { parts.append(String(format: "%.3f fps", rate)) }
            parts.append(video.dynamicRange.rawValue)
            if let dv = video.dolbyVision { parts.append("Dolby Vision \(dv.profileName)") }
            if video.fieldOrder != .progressive { parts.append("field order \(video.fieldOrder.rawValue)") }
            parts.append(video.copyability.rawValue)
            lines.append("video: " + parts.joined(separator: ", "))
        } else {
            lines.append("video: none")
        }
        for audio in info.audioTracks {
            var parts = ["#\(audio.streamIndex) \(audio.codecName)"]
            if let profile = audio.profileName { parts.append(profile) }
            parts.append(audio.channelLayoutDescription ?? "\(audio.channelCount) ch")
            parts.append("\(audio.sampleRate) Hz")
            if audio.isObjectAudio { parts.append("object audio (JOC)") }
            if let language = audio.language { parts.append(language) }
            if let title = audio.title { parts.append("\"\(title)\"") }
            parts.append(audio.copyability.rawValue)
            lines.append("audio: " + parts.joined(separator: ", "))
        }
        for subtitle in info.subtitleTracks {
            var parts = ["#\(subtitle.streamIndex) \(subtitle.codecName)", subtitle.kind.rawValue]
            if let language = subtitle.language { parts.append(language) }
            if subtitle.isDefault { parts.append("default") }
            if subtitle.isForced { parts.append("forced") }
            if subtitle.isHearingImpaired { parts.append("SDH") }
            lines.append("subtitle: " + parts.joined(separator: ", "))
        }
        if !info.chapters.isEmpty { lines.append("chapters: \(info.chapters.count)") }
        return lines.joined(separator: "\n")
    }

    static func render(_ structure: SourceStructure) -> String {
        func show<T>(_ value: T?) -> String { value.map { "\($0)" } ?? "unknown" }
        var line = "structure: header \(show(structure.headerBytes)) B"
            + ", first media element @ \(show(structure.firstClusterOffset))"
            + ", size \(show(structure.byteSize)) B"
            + ", index \(structure.indexLocation.rawValue)"
        if let index = structure.index {
            line += " (\(index.entryCount) entries, \(index.completeness.rawValue), from \(index.source.rawValue))"
        }
        return line
    }
}

// MARK: - serve

enum ServeCommand {
    static func run(_ arguments: [String]) async throws -> ExitCode {
        var duration: Duration?
        var reader = ArgumentReader(arguments)
        try reader.parse { flag, reader in
            guard flag == "--for" else { return false }
            duration = .seconds(try reader.number(for: flag))
            return true
        }
        // Armed before the probe: a Ctrl-C during a slow open should still
        // reach `stop()` rather than the default handler.
        // Once the URL is out, Ctrl-C is how a serve is *meant* to end, so it
        // exits 0; before that it interrupted a startup, and exits 130.
        let stop = StopSignal(watchStdin: true)
        return try await withServedSession(reader.options, stop: stop) { playlist in
            print("serving: \(playlist.absoluteString)")
            print("open it in Safari or QuickTime Player; Enter or Ctrl-C stops the session")
            // Timed stops count from the URL being out, not from launch.
            if let duration { stop.fire(after: duration, "--for elapsed") }
            print("stopping (\(await stop.wait() ?? "cancelled"))")
            return .ok
        }
    }
}

// MARK: - bench

enum BenchCommand {
    static func run(_ arguments: [String]) async throws -> ExitCode {
        var runs = 1
        var keyframeCache: URL?
        var reader = ArgumentReader(arguments)
        try reader.parse { flag, reader in
            switch flag {
            case "--runs": runs = try reader.number(for: flag)
            case "--keyframe-cache":
                keyframeCache = URL(fileURLWithPath: (try reader.value(for: flag) as NSString).expandingTildeInPath)
            default: return false
            }
            return true
        }
        let options = reader.options
        var probeTotals: [Int] = []
        var startTotals: [Int] = []
        var failed = false
        for index in 1...runs {
            let run: StartupCheckpointRun
            do {
                run = try await StartupCheckpointRun.measure(
                    url: options.source!,
                    httpHeaders: options.headers,
                    // The integrating host's network budget rather than the
                    // engine's default, as in `StartupCheckpointBenchmark`, so
                    // a bench fails where a device would.
                    budget: options.budget ?? .seconds(20),
                    coordinatedHTTP: options.coordinatedHTTP,
                    display: options.display,
                    keyframeIndexCacheDirectory: keyframeCache
                )
            } catch {
                throw CLIFailure(code: .probeFailed, message: "probe failed: \(PrismCoreError.classify(error))")
            }
            if runs > 1 { print("run \(index)/\(runs)") }
            print(run.rendered)
            if runs > 1 { print("") }
            probeTotals.append(StartupCheckpointRun.ms(run.probeTiming.total))
            startTotals.append(StartupCheckpointRun.ms(run.startDuration))
            failed = failed || run.failure != nil
        }
        if runs > 1 {
            // One number hides the variance a transport comparison turns on —
            // AGENTS.md *Measuring* asks for the spread.
            print("probe   \(spread(probeTotals))")
            print("start() \(spread(startTotals))")
        }
        return failed ? .checkFailed : .ok
    }

    private static func spread(_ values: [Int]) -> String {
        let sorted = values.sorted()
        guard let low = sorted.first, let high = sorted.last else { return "n/a" }
        return "median \(sorted[sorted.count / 2])ms (min \(low), max \(high), n=\(sorted.count))"
    }
}

// MARK: - segverify

enum SegVerifyCommand {
    static func run(_ arguments: [String]) async throws -> ExitCode {
        var limit: Int?
        var alreadyHLS = false
        var reader = ArgumentReader(arguments)
        try reader.parse { flag, reader in
            switch flag {
            case "--limit": limit = try reader.number(for: flag)
            case "--hls": alreadyHLS = true
            default: return false
            }
            return true
        }
        let options = reader.options
        let stop = StopSignal(watchStdin: false)
        // `-H` belongs to whatever the source URL is: the origin under a
        // remux, the HLS presentation itself under --hls. The playlist a
        // remux serves is PrismCore's own loopback, which wants none.
        let hlsHeaders = alreadyHLS ? options.headers : [:]
        let verify: @Sendable (URL) async throws -> SegmentVerifier.Report = { [limit] playlist in
            print("verifying \(playlist.absoluteString)")
            return try await untilStopped(stop) {
                try await SegmentVerifier.verify(playlist: playlist, httpHeaders: hlsHeaders, limit: limit) {
                    print("  \($0)")
                }
            }
        }
        let report: SegmentVerifier.Report
        if alreadyHLS {
            report = try await verify(options.source!)
        } else {
            report = try await withServedSession(options, stop: stop, verify)
        }

        print("")
        for playlist in report.playlists {
            if let skipped = playlist.skipped {
                print("\(playlist.uri): skipped — \(skipped)")
            } else {
                print("\(playlist.uri): \(playlist.segmentsChecked) segment(s), "
                    + "\(playlist.videoFrames) video / \(playlist.audioFrames) audio frames decoded"
                    + (playlist.undecodedStreams.isEmpty
                        ? "" : "; NOT decoded: " + playlist.undecodedStreams.joined(separator: ", ")))
            }
        }
        for finding in report.findings { print(finding) }
        return summarize(report)
    }

    /// The last line and the exit status. A problem found outranks a check
    /// not made; a check not made is never `ok` — a missing decoder says
    /// nothing is wrong with the media, and just as little that it is right.
    static func summarize(_ report: SegmentVerifier.Report) -> ExitCode {
        let errors = report.findings.filter { $0.severity == .error }.count
        let unverified = report.findings.filter { $0.severity == .unverified }.count
        if errors > 0 {
            print("segverify: \(errors) segment problem(s)"
                + (unverified > 0 ? ", and \(unverified) check(s) not made" : ""))
            return .checkFailed
        }
        if unverified > 0 {
            print("segverify: unverified — \(unverified) check(s) could not be made; "
                + "no problem found in what was checked")
            return .unavailable
        }
        print("segverify: ok")
        return .ok
    }
}
#endif
