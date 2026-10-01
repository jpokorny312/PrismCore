#if os(macOS)
import Foundation
import PrismCore

/// Exit statuses, sysexits-flavoured where one fits so a script can tell a
/// broken invocation from a broken source from a failed check.
enum ExitCode: Int32 {
    case ok = 0
    /// The check ran and found a problem: a bad segment, a validator
    /// failure, a startup that threw.
    case checkFailed = 1
    /// The source could not be opened or described at all.
    case probeFailed = 2
    /// The source opened, but the router sends it away from the remux path —
    /// so there is no HLS to serve, bench or verify.
    case notRemuxable = 3
    case usage = 64          // EX_USAGE
    case noInput = 66        // EX_NOINPUT
    /// EX_UNAVAILABLE: a required check could not be made — the validator
    /// is missing under `--require-validator`, or `segverify` met a stream
    /// this build cannot decode (or a segment it could not fetch in time
    /// from a live window). Distinct from 1 on purpose: nothing was found
    /// wrong with the media, and nothing was shown right.
    case unavailable = 69
    /// 128 + SIGINT, what a shell reports for a Ctrl-C'd command.
    case interrupted = 130
}

struct CLIFailure: Error {
    let code: ExitCode
    let message: String
}

/// The options every subcommand shares. Hand-parsed: one small tool does not
/// justify a package dependency every host would then resolve.
struct SourceOptions: Sendable {
    var source: URL?
    var headers: [String: String] = [:]
    var coordinatedHTTP = false
    var budget: Duration?
    var display = DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true)
    /// Everything after a bare `--`, verbatim (validate passes it on).
    var passthrough: [String] = []
}

/// A cursor over the arguments after the subcommand name.
struct ArgumentReader {
    private var remaining: [String]
    private(set) var options = SourceOptions()

    init(_ arguments: [String]) { remaining = arguments }

    /// Parse the shared options and the one positional source; hand every
    /// flag the shared set does not know to `extra`, which returns whether it
    /// consumed it.
    mutating func parse(extra: (String, inout ArgumentReader) throws -> Bool = { _, _ in false }) throws {
        var positional: [String] = []
        while !remaining.isEmpty {
            let argument = remaining.removeFirst()
            switch argument {
            case "--":
                options.passthrough = remaining
                remaining = []
            case "-H", "--header":
                let raw = try value(for: argument)
                guard let colon = raw.firstIndex(of: ":") else {
                    throw usage("\(argument) wants \"Name: value\", got \"\(raw)\"")
                }
                let name = raw[..<colon].trimmingCharacters(in: .whitespaces)
                let content = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                options.headers[name] = content
            case "-v", "--verbose":
                break  // applied process-wide in `main`, before any engine call
            case "--coordinated-http":
                options.coordinatedHTTP = true
            case "--budget":
                options.budget = .seconds(try number(for: argument))
            case "--display":
                switch try value(for: argument) {
                case "sdr": options.display = DisplayCapabilities(isHDRReady: false, isDolbyVisionCapable: false)
                case "hdr": options.display = DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: false)
                case "dv": options.display = DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true)
                case let other: throw usage("--display takes sdr, hdr or dv, not \"\(other)\"")
                }
            default:
                if try extra(argument, &self) { continue }
                if argument.hasPrefix("-"), argument.count > 1 {
                    throw usage("unknown option \(argument)")
                }
                positional.append(argument)
            }
        }
        guard positional.count == 1 else {
            throw usage(positional.isEmpty ? "missing <url-or-path>" : "expected one source, got \(positional.count)")
        }
        options.source = try Self.resolve(positional[0])
    }

    mutating func value(for flag: String) throws -> String {
        guard !remaining.isEmpty else { throw usage("\(flag) needs a value") }
        return remaining.removeFirst()
    }

    mutating func number(for flag: String) throws -> Int {
        let raw = try value(for: flag)
        guard let parsed = Int(raw), parsed > 0 else {
            throw usage("\(flag) wants a positive integer, got \"\(raw)\"")
        }
        return parsed
    }

    func usage(_ message: String) -> CLIFailure { CLIFailure(code: .usage, message: message) }

    /// A URL when it has a scheme, a path otherwise — checked up front, so a
    /// typo is "no such file", not an FFmpeg error three layers down.
    static func resolve(_ raw: String) throws -> URL {
        if raw.contains("://"), let url = URL(string: raw) { return url }
        let path = (raw as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIFailure(code: .noInput, message: "no such file: \(raw)")
        }
        return URL(fileURLWithPath: path)
    }
}
#endif
