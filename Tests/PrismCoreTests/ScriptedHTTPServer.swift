import Foundation
import Network

/// A test-only origin whose every answer comes from a closure: an in-memory
/// HLS presentation, one that insists on a token, one whose playlist slides
/// between fetches, one that never answers at all. `RangeFixtureServer`
/// models one media file under bandwidth; this models a set of URLs.
///
/// One request per connection (`Connection: close`) — the simplest shape a
/// URLSession and FFmpeg's http both accept, and enough for a test.
final class ScriptedHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        /// Names lowercased.
        let headers: [String: String]
    }

    enum Reply {
        case respond(status: Int, headers: [String: String] = [:], body: Data)
        /// Hold the connection open and never answer: a starved origin.
        case stall
    }

    private let queue = DispatchQueue(label: "prismcore.tests.scripted-origin")
    private let listener: NWListener
    private let handler: @Sendable (Request) -> Reply
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var log: [Request] = []
    private var resumed = false

    init(_ handler: @escaping @Sendable (Request) -> Reply) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Every request received so far, in arrival order.
    var requests: [Request] { queue.sync { log } }

    /// The server's root, `http://127.0.0.1:<port>/`.
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!)
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: queue)
                receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    /// `body`, or the sub-range a `Range: bytes=a-b` / `bytes=a-` asks for,
    /// answered the way an origin that honours ranges does.
    static func ranged(_ body: Data, for request: Request, type: String = "application/octet-stream") -> Reply {
        guard let range = request.headers["range"], range.hasPrefix("bytes=") else {
            return .respond(status: 200, headers: ["Content-Type": type, "Accept-Ranges": "bytes"], body: body)
        }
        let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        let start = bounds.first.flatMap { Int($0) } ?? 0
        let end = min(body.count - 1, bounds.count > 1 ? Int(bounds[1]) ?? body.count - 1 : body.count - 1)
        guard start >= 0, start <= end else {
            return .respond(status: 416, headers: ["Content-Range": "bytes */\(body.count)"], body: Data())
        }
        return .respond(status: 206, headers: [
            "Content-Type": type,
            "Content-Range": "bytes \(start)-\(end)/\(body.count)",
        ], body: body.subdata(in: start..<(end + 1)))
    }

    static func text(_ text: String) -> Reply {
        .respond(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(text.utf8))
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, done, error in
            let buffer = accumulated + (data ?? Data())
            guard buffer.count <= 16384, error == nil else { close(connection); return }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if done { close(connection) } else { receive(connection, accumulated: buffer) }
                return
            }
            let lines = text.components(separatedBy: "\r\n")
            let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            let request = Request(path: URLComponents(string: target)?.path ?? target, headers: headers)
            log.append(request)
            switch handler(request) {
            case .stall:
                break
            case .respond(let status, let extra, let body):
                var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
                for (name, value) in extra { head += "\(name): \(value)\r\n" }
                head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                    self.close(connection)
                })
            }
        }
    }
}
