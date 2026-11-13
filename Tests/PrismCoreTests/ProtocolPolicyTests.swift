import Testing
import Foundation
import Network
@testable import PrismCore
import Libavformat
import Libavutil

/// What FFmpeg may open **itself** (2026-11-13, the Ensō fork): a local file or a plain `http` address, and no redirect. FFmpeg's own TLS (GnuTLS in MPVKit's build) takes any
/// certificate; a host reads `https` through its own reader, so FFmpeg must never be the one that dials an `https` address - not by being handed one, and not by following a
/// `Location` header there. These tests drive real loopback sockets: a listener that only counts the connections made to it stands for the `https` address ("where FFmpeg's TLS would
/// knock"), and an origin that answers every request with a redirect stands for the server that sends the stream elsewhere.
@Suite("Protocol policy of FFmpeg opens", .serialized)
struct ProtocolPolicyTests {

    /// A TCP listener that counts the connections made to it and closes them at once: it is no TLS server, it only tells whether somebody knocked.
    final class KnockCounter: @unchecked Sendable {
        private let queue = DispatchQueue(label: "prismcore.tests.knock-counter")
        private let listener: NWListener
        private var count = 0
        private var resumed = false

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        /// How many connections have been made so far.
        var connections: Int { queue.sync { count } }

        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { [self] state in
                    guard !resumed else { return }
                    switch state {
                    case .ready: resumed = true; continuation.resume(returning: listener.port!.rawValue)
                    case .failed(let error): resumed = true; continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [self] connection in
                    count += 1
                    connection.start(queue: queue)
                    connection.cancel()
                }
                listener.start(queue: queue)
            }
        }

        func stop() { queue.sync { listener.cancel(); listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil } }
    }

    private func media() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// An origin that answers every request with a redirect to `location`.
    private func redirectingOrigin(to location: String) throws -> ScriptedHTTPServer {
        try ScriptedHTTPServer { _ in .respond(status: 302, headers: ["Location": location], body: Data()) }
    }

    // MARK: The policy is on the options of every open

    @Test func theOptionsOfEveryOpenCarryTheWhitelistAndNoRedirects() {
        var options = SourceOpenTuning.makeOptions(httpHeaders: [:])
        defer { av_dict_free(&options) }
        func value(_ key: String) -> String? { av_dict_get(options, key, nil, 0).map { String(cString: $0.pointee.value) } }
        #expect(value("protocol_whitelist") == SourceOpenTuning.protocolWhitelist)
        #expect(value("max_redirects") == "0")
        // The list is what it says: a file, plain http and the tcp under it - never TLS, never crypto, never a datagram protocol.
        #expect(Set(SourceOpenTuning.protocolWhitelist.split(separator: ",").map(String.init)) == ["file", "http", "tcp"])
        #expect(SourceOpenTuning.maxRedirects == 0)
    }

    // MARK: Real sockets

    /// Handed an `https` address, FFmpeg refuses before it makes a connection: nobody knocks at the port.
    @Test func anHttpsAddressIsRefusedBeforeAnyConnection() async throws {
        let knock = try KnockCounter()
        let port = try await knock.start()
        defer { knock.stop() }
        let url = try #require(URL(string: "https://127.0.0.1:\(port)/movie.mkv"))
        await #expect(throws: (any Error).self) { _ = try await SourceProbe.openDetached(url: url, budget: .seconds(5)) }
        #expect(knock.connections == 0, "FFmpeg's own TLS dialled an https address")
    }

    /// An `http` address that sends the stream to an `https` one: the redirect is not followed, nothing knocks at the target - and the origin is asked once.
    @Test func aRedirectToHttpsIsNotFollowed() async throws {
        let knock = try KnockCounter()
        let port = try await knock.start()
        defer { knock.stop() }
        let origin = try redirectingOrigin(to: "https://127.0.0.1:\(port)/movie.mkv")
        let url = try await origin.start()
        defer { origin.stop() }
        await #expect(throws: (any Error).self) { _ = try await SourceProbe.openDetached(url: url.appendingPathComponent("movie.mkv"), budget: .seconds(5)) }
        #expect(knock.connections == 0, "FFmpeg followed a redirect to an https address with its own TLS")
        #expect(origin.requests.count >= 1)
    }

    /// No redirect at all: one to a plain `http` address on another port is not followed either (the host resolves the address it means), and that other origin sees no request;
    /// the same file opened at its own address works, so the refusal is the redirect's and not the fixture's.
    @Test func aRedirectToPlainHttpIsNotFollowedEither() async throws {
        let target = try RangeFixtureServer(media: try media())
        let targetURL = try await target.start()
        defer { target.stop() }
        let origin = try redirectingOrigin(to: targetURL.absoluteString)
        let originURL = try await origin.start()
        defer { origin.stop() }

        await #expect(throws: (any Error).self) { _ = try await SourceProbe.openDetached(url: originURL, budget: .seconds(5)) }
        #expect(target.requests.isEmpty, "the redirect was followed to another http origin")

        let probed = try await SourceProbe.openDetached(url: targetURL, budget: .seconds(10))
        #expect(!probed.info.audioTracks.isEmpty, "control: the same file opens at its own address")
    }

    /// What stays: a file, and plain http without a redirect.
    @Test func aFileAndAPlainHttpAddressStillOpen() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"))
        let fileProbed = try await SourceProbe.openDetached(url: fixture, budget: .seconds(10))
        #expect(!fileProbed.info.audioTracks.isEmpty)
        let server = try RangeFixtureServer(media: try media())
        let url = try await server.start()
        defer { server.stop() }
        let httpProbed = try await SourceProbe.openDetached(url: url, budget: .seconds(10))
        #expect(!httpProbed.info.audioTracks.isEmpty)
    }

    // MARK: Nothing opens an address without the policy

    /// Every source file that calls `avformat_open_input` takes its options from `SourceOpenTuning` (which carries the policy) - a new open that forgets it fails here. (What this
    /// cannot see: an open whose options are built elsewhere but pass through a file that mentions `SourceOpenTuning` for something else. The list of exceptions is one local file.)
    @Test func everyOpenThatTakesAnAddressCarriesThePolicy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PrismCore")
        // SegmentVerifier opens one local segment file by its path, with no options: a diagnostic of the remuxer's own output.
        let local: Set<String> = ["Diagnostics/SegmentVerifier.swift"]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var opens = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("avformat_open_input(") else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            opens += 1
            if local.contains(relative) { continue }
            #expect(text.contains("SourceOpenTuning.makeOptions") || text.contains("SourceOpenTuning.applyProtocolPolicy"),
                    "\(relative) opens an input without the protocol policy (SourceOpenTuning.makeOptions / applyProtocolPolicy)")
        }
        #expect(opens >= 5, "the scan found only \(opens) files that open an input: it is looking in the wrong place")
    }
}
