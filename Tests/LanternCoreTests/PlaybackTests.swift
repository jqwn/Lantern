import Foundation
import Darwin
import Testing
@testable import LanternCore

@Test func playbackSleepActivity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-playback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("sample.mp4")
    let empty = directory.appendingPathComponent("empty.mp4")
    let large = directory.appendingPathComponent("large.mp4")
    try Data("0123456789".utf8).write(to: video)
    try Data().write(to: empty)
    try Data().write(to: large)
    let largeFile = try FileHandle(forWritingTo: large)
    try largeFile.truncate(atOffset: 64 * 1024 * 1024)
    try largeFile.close()

    let queue = DispatchQueue(label: "Lantern.playback-test")
    let server = HTTPServer(queue: queue, playbackIdleTimeout: 1)
    let library = try Library(root: directory)
    var events: [Bool] = []
    server.playbackActivity = { events.append($0) }
    server.handler = { request in
        switch request.path {
        case "/browse": return SOAP.respond(request, service: "ContentDirectory", library: library, base: "http://127.0.0.1")
        case "/video": return .stream(url: video, type: "video/mp4", request: request)
        case "/large": return .stream(url: large, type: "video/mp4", request: request)
        case "/empty": return .stream(url: empty, type: "video/mp4", request: request)
        case "/subtitle": return .stream(url: video, type: "application/x-subrip", request: request)
        case "/unavailable":
            var response = HTTPResponse(type: "video/mp4")
            response.file = directory.appendingPathComponent("missing.mp4"); response.count = 10
            return response
        case "/missing": return HTTPResponse(404)
        default: return HTTPResponse(text: "Catalogue")
        }
    }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
        queue.sync {
            server.state = { result in server.state = nil; continuation.resume(with: result) }
            do { try server.start(address: "127.0.0.1", port: 0) }
            catch { continuation.resume(throwing: error) }
        }
    }
    defer { queue.sync { server.stop() } }
    let base = "http://127.0.0.1:\(port)"
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    #expect(queue.sync { events.isEmpty })
    for (path, method, range, status) in [("/", "GET", "", 200), ("/video", "HEAD", "", 200), ("/subtitle", "GET", "", 200), ("/empty", "GET", "", 200), ("/missing", "GET", "", 404), ("/unavailable", "GET", "", 404), ("/video", "GET", "bytes=20-", 416)] {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        if !range.isEmpty { request.setValue(range, forHTTPHeaderField: "Range") }
        let (_, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == status)
    }
    #expect(queue.sync { events.isEmpty })

    var browse = URLRequest(url: URL(string: base + "/browse")!)
    browse.httpMethod = "POST"
    browse.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"", forHTTPHeaderField: "SOAPAction")
    browse.httpBody = Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:Browse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\"><ObjectID>0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><StartingIndex>0</StartingIndex><RequestedCount>0</RequestedCount></u:Browse></s:Body></s:Envelope>".utf8)
    let (_, browseResponse) = try await session.data(for: browse)
    #expect((browseResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(queue.sync { events } == [true])
    try await Task.sleep(nanoseconds: 650_000_000)
    _ = try await session.data(for: browse)
    try await Task.sleep(nanoseconds: 650_000_000)
    #expect(queue.sync { events } == [true, true])
    _ = try await session.data(from: URL(string: base + "/")!)
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(queue.sync { events } == [true, true, false])
    queue.sync { events.removeAll() }

    let (data, _) = try await session.data(from: URL(string: base + "/video")!)
    #expect(data == Data("0123456789".utf8))
    #expect(queue.sync { events } == [true])
    try await Task.sleep(nanoseconds: 650_000_000)
    var rangeRequest = URLRequest(url: URL(string: base + "/video")!)
    rangeRequest.setValue("bytes=2-4", forHTTPHeaderField: "Range")
    let (rangeData, _) = try await session.data(for: rangeRequest)
    #expect(rangeData == Data("234".utf8))
    try await Task.sleep(nanoseconds: 650_000_000)
    #expect(queue.sync { events } == [true, true])
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(queue.sync { events } == [true, true, false])

    queue.sync { events.removeAll() }
    var sockets: [Int32] = []
    defer { for socket in sockets { Darwin.close(socket) } }
    for _ in 0..<2 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(socket >= 0)
        sockets.append(socket)
        var receiveBuffer: Int32 = 4096
        #expect(setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout.size(ofValue: receiveBuffer))) == 0)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        #expect(setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(connected == 0)
        let request = Data("GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        try #require(request.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) } == request.count)
        var header = [UInt8](repeating: 0, count: 16)
        try #require(Darwin.recv(socket, &header, header.count, 0) > 0)
    }
    // Stop reading so both transfers stay open beyond the shortened test grace period.
    try await Task.sleep(nanoseconds: 1_200_000_000)
    #expect(queue.sync { events } == [true])
    Darwin.close(sockets.removeFirst())
    try await Task.sleep(nanoseconds: 1_200_000_000)
    #expect(queue.sync { events } == [true])
    Darwin.close(sockets.removeFirst())
    try await Task.sleep(nanoseconds: 1_300_000_000)
    #expect(queue.sync { events } == [true, false])

    queue.sync { events.removeAll() }
    _ = try await session.data(from: URL(string: base + "/video")!)
    queue.sync { server.stop() }
    #expect(queue.sync { events } == [true, false])
    try await Task.sleep(nanoseconds: 1_200_000_000)
    #expect(queue.sync { events } == [true, false])
}
