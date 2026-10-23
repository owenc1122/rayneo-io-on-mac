import Foundation
import Network

/// One parsed HTTP/1.1 request.
struct AappDevRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]      // lower-cased names
    var body: Data

    var bearer: String? {
        guard let value = headers["authorization"], value.lowercased().hasPrefix("bearer ") else { return nil }
        return String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }

    func jsonBody() -> [String: Any]? {
        body.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// Incremental, bounded HTTP/1.1 request parser (no pipelining beyond sequential requests on one connection).
struct AappDevRequestParser {
    enum Result { case needMore, request(AappDevRequest), failure(Int, String) }
    static let maxHead = 16 * 1024

    private(set) var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    /// Takes one complete request off the front of the buffer, if there is one.
    mutating func next(maxBody: Int = AappDevProtocol.maxRequestBody) -> Result {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.maxHead ? .failure(431, "Request header too large") : .needMore
        }
        guard headEnd.lowerBound - buffer.startIndex <= Self.maxHead else { return .failure(431, "Request header too large") }
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .failure(400, "Bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .failure(400, "Bad header") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headEnd.upperBound
        var body = Data(), consumed = bodyStart
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var p = bodyStart
            while true {
                guard let lineEnd = buffer[p...].range(of: Data("\r\n".utf8)) else { return buffer.count - bodyStart > maxBody + 1024 ? .failure(413, "Body too large") : .needMore }
                let sizeText = String(decoding: buffer[p..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { return .failure(400, "Bad chunk") }
                guard body.count + size <= maxBody else { return .failure(413, "Body too large") }
                let dataStart = lineEnd.upperBound
                if size == 0 {
                    // Trailers end with an empty line.
                    guard let end = buffer[dataStart...].range(of: Data("\r\n".utf8)) else { return .needMore }
                    consumed = end.upperBound; break
                }
                guard buffer.endIndex >= dataStart + size + 2 else { return .needMore }
                body.append(buffer[dataStart..<(dataStart + size)])
                p = dataStart + size + 2
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return .failure(400, "Bad Content-Length") }
            guard length <= maxBody else { return .failure(413, "Body too large") }
            guard buffer.endIndex - bodyStart >= length else { return .needMore }
            body = Data(buffer[bodyStart..<(bodyStart + length)])
            consumed = bodyStart + length
        }
        buffer = Data(buffer[consumed...])
        let target = String(start[1])
        let components = URLComponents(string: "http://localhost" + (target.hasPrefix("/") ? target : "/" + target))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .request(AappDevRequest(method: String(start[0]).uppercased(), path: components?.percentEncodedPath ?? target,
                                       query: query, headers: headers, body: body))
    }
}

/// One accepted TLS connection. Requests are answered in order; one of them may turn the connection into an
/// SSE stream, after which no more requests are read from it. All calls happen on the server's queue.
final class AappDevHTTPConnection {
    let id = UUID()
    let connection: NWConnection
    var onRequest: ((AappDevRequest, AappDevHTTPConnection) -> Void)?
    var onClose: ((AappDevHTTPConnection) -> Void)?
    private(set) var streaming = false
    private var parser = AappDevRequestParser()
    private var closed = false
    private var pendingWrites = 0
    private let queue: DispatchQueue

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty, !self.streaming {
                self.parser.append(data)
                self.drain()
            }
            if done || error != nil { self.finish(); return }
            self.receive()
        }
    }

    private func drain() {
        while !closed && !streaming {
            switch parser.next() {
            case .needMore: return
            case .failure(let status, let text):
                respond(status, json: AappDevProtocol.errorBody(text), close: true); return
            case .request(let request): onRequest?(request, self)
            }
        }
    }

    static func reason(_ status: Int) -> String {
        [200: "OK", 204: "No Content", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
         404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 410: "Gone", 413: "Payload Too Large",
         416: "Range Not Satisfiable", 431: "Request Header Fields Too Large", 500: "Internal Server Error"][status] ?? "Status"
    }

    func respond(_ status: Int, json body: Data, close: Bool = false) {
        respond(status, body: body, contentType: "application/json; charset=utf-8", close: close)
    }

    func respond(_ status: Int, body: Data, contentType: String, extraHeaders: [String: String] = [:], close: Bool = false) {
        guard !closed else { return }
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        head += close ? "Connection: close\r\n\r\n" : "Connection: keep-alive\r\n\r\n"
        write(Data(head.utf8) + body, then: close ? { [weak self] in self?.cancel() } : nil)
    }

    /// Switches to a Server-Sent Events stream (chunked transfer).
    func beginStream() {
        guard !closed else { return }
        streaming = true
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\n\r\n"
        write(Data(head.utf8))
    }

    /// One SSE chunk. Returns false if the client is not draining (too many writes in flight) and was dropped.
    @discardableResult func streamWrite(_ payload: Data) -> Bool {
        guard streaming, !closed else { return false }
        guard pendingWrites < 256 else { cancel(); return false }
        write(Data(String(payload.count, radix: 16).utf8) + Data("\r\n".utf8) + payload + Data("\r\n".utf8))
        return true
    }

    func endStream() {
        guard streaming, !closed else { return }
        write(Data("0\r\n\r\n".utf8)) { [weak self] in self?.cancel() }
    }

    private func write(_ data: Data, then done: (() -> Void)? = nil) {
        pendingWrites += 1
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingWrites -= 1
            if error != nil { self.cancel(); return }
            done?()
        })
    }

    func cancel() {
        guard !closed else { return }
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        onClose?(self)
        onRequest = nil; onClose = nil
    }
}
