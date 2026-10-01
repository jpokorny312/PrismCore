#if os(macOS)
import Foundation
import PrismCore

/// Serve the source and run Apple's `mediastreamvalidator` over the result,
/// then `hlsreport` over the validator's JSON when that tool is present too.
///
/// Why a device alone is not enough: a master-playlist mistake — a `CODECS`
/// string, a `VIDEO-RANGE`, a `SUPPLEMENTAL-CODECS` brand — surfaces on a
/// device as `-11868` / `-12881` and nothing else. The validator names the
/// attribute.
///
/// **Opt-in by construction.** Apple's HTTP Live Streaming Tools are a
/// separate macOS download that CI and most machines do not have, so a
/// missing validator is a printed notice and exit 0, never a failure — unless
/// `--require-validator` says the caller wants one (exit 69, EX_UNAVAILABLE).
enum ValidateCommand {
    static let validatorVariable = "PRISMCORE_MEDIASTREAMVALIDATOR"
    static let reportVariable = "PRISMCORE_HLSREPORT"

    static func run(_ arguments: [String]) async throws -> ExitCode {
        var requireValidator = false
        var outOption = URL(fileURLWithPath: "prismcore-validation")
        var reader = ArgumentReader(arguments)
        try reader.parse { flag, reader in
            switch flag {
            case "--require-validator": requireValidator = true
            case "--out":
                outOption = URL(fileURLWithPath: (try reader.value(for: flag) as NSString).expandingTildeInPath)
            default: return false
            }
            return true
        }
        let options = reader.options

        // Checked before the probe, so a machine without the tools pays for
        // nothing it cannot use.
        guard let validator = locate("mediastreamvalidator", override: validatorVariable) else {
            let override = ProcessInfo.processInfo.environment[validatorVariable] ?? ""
            let notice = override.isEmpty ? """
                mediastreamvalidator not found — nothing validated.
                Install Apple's HTTP Live Streaming Tools (developer.apple.com/download/all,
                "HTTP Live Streaming Tools"), or point $\(validatorVariable) at the binary.
                """ : """
                $\(validatorVariable) is \(override), which is not an executable — nothing validated.
                """
            if requireValidator {
                throw CLIFailure(code: .unavailable, message: notice)
            }
            print(notice)
            return .ok
        }
        let hlsreport = locate("hlsreport", override: reportVariable)
        let outDirectory = outOption
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        // A previous run's JSON would otherwise be rendered as this run's
        // report if the validator dies before writing its own.
        try? FileManager.default.removeItem(at: outDirectory.appendingPathComponent("validation_data.json"))

        let stop = StopSignal(watchStdin: false)
        return try await withServedSession(options, stop: stop) { playlist in
            print("serving: \(playlist.absoluteString)")
            print("running \(validator.path) (output in \(outDirectory.path))")
            // Run in the output directory: the validator writes its JSON
            // (validation_data.json) into the working directory by default,
            // and depending on that avoids guessing at flag spellings that
            // differ between tool releases.
            let status = try await untilStopped(stop) {
                try await runTool(validator, arguments: options.passthrough + [playlist.absoluteString],
                            in: outDirectory, stop: stop)
            }
            print("mediastreamvalidator exited \(status)")

            let json = outDirectory.appendingPathComponent("validation_data.json")
            if let hlsreport, FileManager.default.fileExists(atPath: json.path) {
                let reportStatus = try await untilStopped(stop) {
                    try await runTool(hlsreport, arguments: [json.lastPathComponent], in: outDirectory, stop: stop)
                }
                // A report that could not be rendered does not change the
                // validator's verdict, so it is a notice, not the exit code.
                if reportStatus != 0 { printError("hlsreport exited \(reportStatus); the JSON is still in \(json.path)") }
            } else if hlsreport == nil {
                print("hlsreport not found ($\(reportVariable) or PATH); skipping the HTML report")
            }
            let produced = (try? FileManager.default.contentsOfDirectory(atPath: outDirectory.path)) ?? []
            if !produced.isEmpty { print("report files: " + produced.sorted().joined(separator: ", ")) }
            return status == 0 ? .ok : .checkFailed
        }
    }

    /// `$override` when it is set (and must then exist — a typo'd override
    /// silently falling back to PATH would validate with the wrong tool),
    /// otherwise the first executable `name` on PATH.
    static func locate(_ name: String, override: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment[override], !explicit.isEmpty {
            let path = (explicit as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Run a tool with inherited stdout/stderr and return its exit status.
    ///
    /// Awaited through the termination handler rather than
    /// `waitUntilExit()`, which would park a cooperative-pool thread for the
    /// validator's whole run — the thread the stop race may need to answer
    /// on. A stop terminates the child, so the session is not stopped under
    /// a validator still reading from it.
    private static func runTool(
        _ tool: URL, arguments: [String], in directory: URL, stop: StopSignal
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let watcher = Task {
            _ = await stop.wait()
            if process.isRunning { process.terminate() }
        }
        defer { watcher.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            // Installed before `run()`: a tool that exits at once must not
            // finish before anyone is listening.
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
#endif
