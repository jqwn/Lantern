import Foundation
import Network

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public var peerAddress: String? = nil
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var file: URL?
    public var offset: UInt64 = 0
    public var count: UInt64 = 0
    var isLibraryBrowse = false
    var deferred: ((@escaping (HTTPResponse) -> Void) -> Void)?

    public init(_ status: Int = 200, text: String = "", type: String = "text/xml; charset=utf-8", headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
        self.headers["Content-Type"] = type
        body = Data(text.utf8)
    }

    public static func stream(url: URL, type: String, request: HTTPRequest, headers: [String: String] = [:]) -> HTTPResponse {
        do {
            var source = url
            source.removeAllCachedResourceValues()
            let size = UInt64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            let range = try ByteRange.parse(request.headers["range"], size: size)
            var result = HTTPResponse(range == nil ? 200 : 206, type: type, headers: headers)
            result.file = url
            result.offset = range?.lowerBound ?? 0
            result.count = range.map { $0.upperBound - $0.lowerBound + 1 } ?? size
            result.headers["Accept-Ranges"] = "bytes"
            if let range { result.headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)" }
            return result
        } catch ByteRange.invalid(let size) {
            return HTTPResponse(416, headers: ["Content-Range": "bytes */\(size)"])
        } catch { return HTTPResponse(404, text: "File unavailable", type: "text/plain") }
    }
}

public enum ByteRange: Error {
    case invalid(UInt64)
    public static func parse(_ header: String?, size: UInt64) throws -> ClosedRange<UInt64>? {
        guard let header else { return nil }
        guard header.hasPrefix("bytes="), size > 0 else { throw invalid(size) }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw invalid(size) }
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { throw invalid(size) }
            return (size - min(suffix, size))...(size - 1)
        }
        guard let start = UInt64(parts[0]), start < size else { throw invalid(size) }
        let end: UInt64
        if parts[1].isEmpty { end = size - 1 }
        else { guard let value = UInt64(parts[1]) else { throw invalid(size) }; end = min(value, size - 1) }
        guard start <= end else { throw invalid(size) }
        return start...end
    }
}

public final class HTTPServer {
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var clients: [UUID: HTTPClient] = [:]
    private var activePlaybackRequests = 0
    private var playbackIdleTimer: DispatchSourceTimer?
    private let playbackIdleTimeout: TimeInterval
    public var handler: ((HTTPRequest) -> HTTPResponse)?
    public var state: ((Result<UInt16, Error>) -> Void)?
    public var playbackActivity: ((Bool) -> Void)?

    public init(queue: DispatchQueue, playbackIdleTimeout: TimeInterval = 15 * 60) { self.queue = queue; self.playbackIdleTimeout = playbackIdleTimeout }

    public func start(address: String, port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] status in
            guard let self, self.listener === listener else { return }
            switch status {
            case .ready: if let port = listener?.port { self.state?(.success(port.rawValue)) }
            case .failed(let error): self.state?(.failure(error)); self.stop()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.clients.count < 48 else { connection.cancel(); return }
            let id = UUID()
            let client = HTTPClient(connection: connection, queue: self.queue, handler: { [weak self] in self?.handler?($0) ?? HTTPResponse(503) }, playbackRequest: { [weak self] started in
                guard let self else { return }
                if started {
                    self.activePlaybackRequests += 1
                    self.playbackIdleTimer?.cancel(); self.playbackIdleTimer = nil
                    if self.activePlaybackRequests == 1 { self.playbackActivity?(true) }
                } else {
                    self.activePlaybackRequests -= 1
                    if self.activePlaybackRequests == 0 {
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        self.playbackIdleTimer = timer
                        timer.schedule(deadline: .now() + self.playbackIdleTimeout)
                        timer.setEventHandler { [weak self] in
                            guard let self else { return }
                            self.playbackIdleTimer?.cancel(); self.playbackIdleTimer = nil
                            self.playbackActivity?(false)
                        }
                        timer.resume()
                    }
                }
            }, finished: { [weak self] in self?.clients.removeValue(forKey: id) })
            self.clients[id] = client
            client.start()
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel(); listener = nil
        let active = Array(clients.values)
        clients.removeAll()
        active.forEach { $0.close() }
        playbackIdleTimer?.cancel(); playbackIdleTimer = nil
        playbackActivity?(false)
    }
}

private final class HTTPClient {
    let connection: NWConnection
    let queue: DispatchQueue
    let handler: (HTTPRequest) -> HTTPResponse
    let playbackRequest: (Bool) -> Void
    let finished: () -> Void
    var buffer = Data()
    var file: FileHandle?
    var remaining: UInt64 = 0
    var timer: DispatchSourceTimer?
    var closed = false
    var playbackRequestActive = false
    var awaitingResponse = false

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping (HTTPRequest) -> HTTPResponse, playbackRequest: @escaping (Bool) -> Void, finished: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.handler = handler; self.playbackRequest = playbackRequest; self.finished = finished
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { [weak self] in self?.close() }
        timer.resume()
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .failed, .cancelled: self?.close(); default: break }
        }
        connection.start(queue: queue)
        receive()
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            guard self.buffer.count <= 262144 else { self.send(HTTPResponse(413), head: false); return }
            if let boundary = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard boundary.lowerBound <= 32768, let header = String(data: self.buffer[..<boundary.lowerBound], encoding: .utf8) else { self.send(HTTPResponse(400), head: false); return }
                let lines = header.components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                guard first.count == 3, first[1].hasPrefix("/") else { self.send(HTTPResponse(400), head: false); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { self.send(HTTPResponse(400), head: false); return }
                    let key = line[..<colon].lowercased()
                    guard headers[key] == nil else { self.send(HTTPResponse(400), head: false); return }
                    headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 196608 else { self.send(HTTPResponse(400), head: false); return }
                let start = boundary.upperBound
                if self.buffer.count >= start + length {
                    var request = HTTPRequest(method: String(first[0]), path: String(first[1]).components(separatedBy: "?")[0], headers: headers, body: self.buffer.subdata(in: start..<(start + length)))
                    if case .hostPort(let host, _) = self.connection.endpoint { request.peerAddress = "\(host)" }
                    self.send(self.handler(request), head: request.method == "HEAD")
                    return
                }
            } else if self.buffer.count > 32768 { self.send(HTTPResponse(431), head: false); return }
            if complete || error != nil { self.close() } else { self.receive() }
        }
    }

    func send(_ response: HTTPResponse, head: Bool) {
        guard !closed else { return }
        if let deferred = response.deferred {
            awaitingResponse = true
            deferred { [weak self] response in
                guard let self else { return }
                self.queue.async {
                    guard !self.closed, self.awaitingResponse else { return }
                    self.awaitingResponse = false
                    self.send(response, head: head)
                }
            }
            return
        }
        var response = response
        if let url = response.file, !head {
            do { file = try FileHandle(forReadingFrom: url); try file?.seek(toOffset: response.offset) }
            catch { response = HTTPResponse(404, text: "File unavailable", type: "text/plain") }
        }
        remaining = response.count
        var headers = response.headers
        headers["Content-Length"] = String(response.file == nil ? UInt64(response.body.count) : response.count)
        headers["Connection"] = "close"
        headers["Server"] = "Darwin/1.0 UPnP/1.0 Lantern/0.1"
        let reasons = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 412: "Precondition Failed", 413: "Content Too Large", 416: "Range Not Satisfiable", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]
        var bytes = Data("HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\n".utf8)
        bytes.append(Data((headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8))
        if !head && response.file == nil { bytes.append(response.body) }
        let hasFile = !head && response.file != nil
        if response.isLibraryBrowse || (hasFile && response.count > 0 && response.headers["Content-Type"]?.hasPrefix("video/") == true) {
            playbackRequestActive = true
            playbackRequest(true)
        }
        timer?.schedule(deadline: .now() + 30)
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil || !hasFile { self.close() } else { self.sendChunk() }
        })
    }

    func sendChunk() {
        guard !closed, remaining > 0 else { close(); return }
        do {
            guard let chunk = try file?.read(upToCount: Int(min(remaining, 262144))), !chunk.isEmpty else { close(); return }
            remaining -= UInt64(chunk.count)
            timer?.schedule(deadline: .now() + 30)
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() } else { self?.sendChunk() }
            })
        } catch { close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        try? file?.close(); file = nil
        connection.cancel()
        if playbackRequestActive { playbackRequestActive = false; playbackRequest(false) }
        finished()
    }
}
