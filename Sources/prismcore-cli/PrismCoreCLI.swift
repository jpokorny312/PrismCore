import Foundation

#if os(macOS)
import PrismCore

/// `prismcore-cli` — reproduce a field report from a terminal.
///
/// The loop this shortens: a report arrives, and until now the only ways to
/// see what the engine does with that source were an opt-in test harness or a
/// device build. Each subcommand here is one question a report usually asks —
/// what did the probe see and where does it route (`probe`), does the served
/// HLS play in Safari/QuickTime (`serve`), does Apple's validator accept it
/// (`validate`), where did startup spend its time (`bench`), is every segment
/// decodable on its own (`segverify`).
///
/// What it cannot answer, and never claims to: anything the tvOS display
/// handshake, a Dolby Vision panel or an Atmos receiver decides. Those still
/// need the device.
@main
struct PrismCoreCLI {
    static let usage = """
        usage: prismcore-cli <command> <url-or-path> [options]

        Commands:
          probe      SourceInfo, container structure, and the routing verdict with its reason
          serve      start a remux session and print its loopback playlist URL; runs
                     until Enter or Ctrl-C (or --for SECONDS)
          validate   serve, then run Apple's mediastreamvalidator (and hlsreport) over the
                     produced HLS. Opt-in: needs Apple's HTTP Live Streaming Tools
          bench      startup checkpoint line, the same shape a host logs
          segverify  decode every served segment on its own and name each one that fails

        Common options:
          -H, --header "Name: value"   HTTP header for the source (repeatable)
          --coordinated-http           read http(s) sources through PrismCore's range reader
          --budget SECONDS             probe budget (default 10; bench defaults to 20)
          --display sdr|hdr|dv         display the master is built for (default dv)
          -v, --verbose                libav* warnings and engine notices on stderr

        probe:      --structure none|layout|full   (default layout)
        serve:      --for SECONDS                  stop on its own after SECONDS
        validate:   --require-validator            exit 69 when the validator is missing
                    --out DIR                      where the report goes (default ./prismcore-validation)
                    -- ARGS…                       passed to mediastreamvalidator verbatim
                    Tools: $PRISMCORE_MEDIASTREAMVALIDATOR / $PRISMCORE_HLSREPORT, else PATH
        bench:      --runs N                       repeat and print the spread (default 1)
                    --keyframe-cache DIR           persist harvested keyframe maps
        segverify:  --limit N                      check at most N segments per playlist
                    --hls                          the source already is an HLS playlist; verify
                                                   it directly instead of remuxing

        Exit status: 0 ok, 1 check failed, 2 source unreadable, 3 source routes away from
        the remux path, 64 usage, 66 no such file, 69 a check could not be made (validator
        missing under --require-validator; segverify: a stream with no decoder in this
        build, a segment that left a live window, or encrypted segments), 130 interrupted
        (Ctrl-C/SIGTERM) — except serve once its URL is printed, where Ctrl-C is the
        intended end and exits 0.
        Media over HTTP, not a mounted share — see AGENTS.md "Measuring".
        """

    static func main() async {
        // Line-buffered even into a pipe: `serve` prints its URL and then
        // waits, and a script reading that URL would otherwise wait for a
        // block-buffered line that is only flushed at exit.
        setvbuf(stdout, nil, _IOLBF, 0)
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print(usage)
            exit(ExitCode.usage.rawValue)
        }
        arguments.removeFirst()
        if ["-h", "--help", "help"].contains(command) {
            print(usage)
            exit(ExitCode.ok.rawValue)
        }
        // Only what precedes a bare `--` is ours; the rest belongs to the
        // validator and may well contain its own -v.
        let own = arguments.prefix { $0 != "--" }
        if own.contains("-h") || own.contains("--help") {
            print(usage)
            exit(ExitCode.ok.rawValue)
        }
        let verbose = own.contains("-v") || own.contains("--verbose")
        LibraryLogLevel.set(verbose: verbose)
        if verbose {
            // The engine's notices normally go to the unified log only; a
            // repro in a terminal wants them next to the output they explain.
            PrismCoreLog.observer = { printError("[prismcore] \($0)") }
        }

        let code: ExitCode
        do {
            switch command {
            case "probe": code = try await ProbeCommand.run(arguments)
            case "serve": code = try await ServeCommand.run(arguments)
            case "validate": code = try await ValidateCommand.run(arguments)
            case "bench": code = try await BenchCommand.run(arguments)
            case "segverify": code = try await SegVerifyCommand.run(arguments)
            default: throw CLIFailure(code: .usage, message: "unknown command \"\(command)\"")
            }
        } catch let failure as CLIFailure {
            printError("prismcore-cli: \(failure.message)")
            if failure.code == .usage { printError("run `prismcore-cli --help` for usage") }
            exit(failure.code.rawValue)
        } catch {
            printError("prismcore-cli: \(error)")
            exit(ExitCode.checkFailed.rawValue)
        }
        exit(code.rawValue)
    }
}

func printError(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
#else
@main
struct PrismCoreCLI {
    // Serving, the validator and the stdin/signal handling are desktop
    // concerns; on a device the host app is the harness.
    static func main() {
        FileHandle.standardError.write(Data("prismcore-cli runs on macOS only\n".utf8))
        exit(69)
    }
}
#endif
