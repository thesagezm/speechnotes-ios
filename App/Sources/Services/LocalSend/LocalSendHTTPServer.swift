import Foundation
import Network

/// One parsed HTTP/1.1 request. The body arrives either in memory (small
/// JSON endpoints) or spilled to a temp file (uploads — book files reach
/// hundreds of MB and must never be fully materialized).
struct LocalSendHTTPRequest {
    enum Body {
        case memory(Data)
        case file(URL, byteCount: Int64)
    }

    let method: String
    let path: String
    /// Query items, percent-decoded.
    let query: [String: String]
    let headers: [String: String]
    /// Sender IP, IPv6-mapped prefixes stripped ("::ffff:a.b.c.d" → a.b.c.d).
    let remoteHost: String?
    let body: Body

    func queryValue(_ name: String) -> String? {
        query[name]
    }

    var contentLength: Int64 {
        headers["content-length"].flatMap { Int64($0) } ?? 0
    }
}

struct LocalSendHTTPResponse {
    let status: Int
    let body: Data
    let contentType: String

    init(status: Int, body: Data = Data(), contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    static func json<T: Encodable>(_ value: T) -> LocalSendHTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return LocalSendHTTPResponse(status: 200, body: data)
    }

    static func status(_ code: Int) -> LocalSendHTTPResponse {
        LocalSendHTTPResponse(status: code)
    }

    static func badRequest() -> LocalSendHTTPResponse { status(400) }
    static func forbidden() -> LocalSendHTTPResponse { status(403) }
    static func notFound() -> LocalSendHTTPResponse { status(404) }
    static func conflict() -> LocalSendHTTPResponse { status(409) }
    static func unsupported() -> LocalSendHTTPResponse { status(422) }
}

/// A minimal HTTP/1.1 server on NWListener — enough for the LocalSend
/// endpoints: request-line + headers + Content-Length body, one request per
/// connection (Connection: close; LocalSend senders tolerate this), no
/// chunked encoding, no TLS.
///
/// Threading: all connection work and `handler` run on the private server
/// queue; the handler hops to main for published state itself.
final class LocalSendHTTPServer {
    /// Called on the server queue for every complete request.
    var handler: ((LocalSendHTTPRequest) -> LocalSendHTTPResponse)?

    private let queue = DispatchQueue(label: "com.speechnotes.localsend.server")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    /// Body bytes spill to disk past this threshold (uploads).
    private let spillThreshold = 8 << 20
    /// Request-head cap — a hostile peer cannot OOM the parser with an
    /// endless header block.
    private let maxHeadBytes = 64 << 10

    // MARK: - Lifecycle

    /// Starts on the first free port among 53317–53327 (the LocalSend
    /// default first). `onReady(port)` / `onFailed(reason)` fire on main.
    func start(onReady: @escaping (UInt16) -> Void, onFailed: @escaping (String) -> Void) {
        queue.async { [weak self] in
            self?.startLocked(candidates: Array(53317...53327), onReady: onReady, onFailed: onFailed)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.port = 0
        }
    }

    /// The Readest lesson (their zombie-listener bug): a backgrounded iOS
    /// app can have its listening socket reclaimed while the accept loop
    /// hangs — "running" stays true but nobody can connect. The ONLY
    /// reliable check is a loopback TCP connect.
    func verifyAlive(timeout: TimeInterval = 0.5, completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, let port = self.livePortLocked() else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            Self.loopbackConnect(port: port, timeout: timeout) { alive in
                DispatchQueue.main.async { completion(alive) }
            }
        }
    }

    /// Caller on server queue: the port the listener actually bound (only
    /// meaningful after .ready).
    private func livePortLocked() -> UInt16? {
        port > 0 ? port : nil
    }

    private func startLocked(candidates: [UInt16], onReady: @escaping (UInt16) -> Void, onFailed: @escaping (String) -> Void) {
        listener?.cancel()
        guard let candidate = candidates.first else {
            DispatchQueue.main.async { onFailed("Ports 53317–53327 are all in use") }
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: candidate)!) else {
            startLocked(candidates: Array(candidates.dropFirst()), onReady: onReady, onFailed: onFailed)
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = candidate
                DispatchQueue.main.async { onReady(candidate) }
            case .failed:
                self.listener?.cancel()
                self.listener = nil
                self.port = 0
                self.startLocked(candidates: Array(candidates.dropFirst()), onReady: onReady, onFailed: onFailed)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    /// 500 ms loopback connect — probe, don't trust the flag.
    private static func loopbackConnect(port: UInt16, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let probeQueue = DispatchQueue(label: "com.speechnotes.localsend.probe")
        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let box = ProbeBox()
        // Exactly one completion: whichever of ready/failed/timeout marks
        // the box done first wins; the rest are no-ops.
        let finish: (Bool) -> Void = { success in
            guard box.markDone(success) else { return }
            conn.cancel()
            completion(success)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        conn.start(queue: probeQueue)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(box.success)
        }
    }

    private final class ProbeBox {
        private var done = false
        var success = false
        /// Returns true exactly once.
        func markDone(_ success: Bool) -> Bool {
            if done { return false }
            done = true
            self.success = success
            return true
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        guard buffer.count <= maxHeadBytes else {
            respond(connection, .status(431))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                let rest = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                self.headParsed(connection, headData: headData, bodyStart: rest)
            } else if error == nil, !isComplete {
                self.receiveHead(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func headParsed(_ connection: NWConnection, headData: Data, bodyStart: Data) {
        guard let head = String(data: headData, encoding: .utf8) else {
            respond(connection, .badRequest())
            return
        }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            respond(connection, .badRequest())
            return
        }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(connection, .badRequest())
            return
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Path + query split, percent-decoding the query pairs.
        var path = target
        var query: [String: String] = [:]
        if let qIdx = target.firstIndex(of: "?") {
            path = String(target[..<qIdx])
            let queryString = String(target[target.index(after: qIdx)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }

        let contentLength = Int64(headers["content-length"] ?? "0") ?? 0
        let remoteHost = Self.host(of: connection)
        let accumulator = BodyAccumulator(spillThreshold: spillThreshold, initial: bodyStart)
        readBody(connection, accumulator: accumulator, remaining: contentLength - Int64(bodyStart.count)) { [weak self] in
            guard let self else { return }
            let request = LocalSendHTTPRequest(
                method: method,
                path: path,
                query: query,
                headers: headers,
                remoteHost: remoteHost,
                body: accumulator.finish()
            )
            let response = (self.handler?(request) ?? .notFound())
            self.respond(connection, response)
        }
    }

    private func readBody(
        _ connection: NWConnection,
        accumulator: BodyAccumulator,
        remaining: Int64,
        done: @escaping () -> Void
    ) {
        guard remaining > 0 else {
            done()
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                accumulator.append(data)
                let next = remaining - Int64(data.count)
                if next > 0 {
                    self.readBody(connection, accumulator: accumulator, remaining: next, done: done)
                    return
                }
                done()
            } else if error == nil, !isComplete {
                self.readBody(connection, accumulator: accumulator, remaining: remaining, done: done)
            } else {
                // Peer hung up mid-body — drop the connection; LocalSend
                // senders retry on a fresh one.
                accumulator.abort()
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, _ response: LocalSendHTTPResponse) {
        let reason = Self.reason(for: response.status)
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default: return "Status \(status)"
        }
    }

    private static func host(of connection: NWConnection) -> String? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            var text = "\(address)"
            if text.hasPrefix("::ffff:") { text.removeFirst(7) }
            return text
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }
}

/// Accumulates a request body, spilling to a temp file past the threshold so
/// uploads never fully materialize in RAM. finish() returns the body source;
/// abort() discards (peer hung up).
final class BodyAccumulator {
    private let spillThreshold: Int
    private var memory = Data()
    private var handle: FileHandle?
    private var spillURL: URL?
    private(set) var totalBytes: Int64 = 0
    private let capBytes: Int64 = 2 << 30 // 2 GB hard cap

    init(spillThreshold: Int, initial: Data = Data()) {
        self.spillThreshold = spillThreshold
        if !initial.isEmpty { append(initial) }
    }

    func append(_ data: Data) {
        totalBytes += Int64(data.count)
        guard totalBytes <= capBytes else { return }
        if handle != nil {
            handle?.write(data)
            return
        }
        memory.append(data)
        guard memory.count > spillThreshold else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localsend-body-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.write(memory)
        memory = Data()
        spillURL = url
        self.handle = handle
    }

    func finish() -> LocalSendHTTPRequest.Body {
        handle?.closeFile()
        handle = nil
        if let spillURL {
            return .file(spillURL, byteCount: totalBytes)
        }
        return .memory(memory)
    }

    func abort() {
        handle?.closeFile()
        handle = nil
        if let spillURL {
            try? FileManager.default.removeItem(at: spillURL)
        }
        spillURL = nil
    }
}
