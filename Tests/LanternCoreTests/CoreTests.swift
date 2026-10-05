import Foundation
import Darwin
import Testing
@testable import LanternCore

final class CoreTests {
    var directory: URL!
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func write(_ name: String, _ content: String = "video") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }

    @Test func ranges() throws {
        #expect(try ByteRange.parse(nil, size: 10) == nil)
        #expect(try ByteRange.parse("bytes=0-3", size: 10) == 0...3)
        #expect(try ByteRange.parse("bytes=7-", size: 10) == 7...9)
        #expect(try ByteRange.parse("bytes=-3", size: 10) == 7...9)
        #expect(try ByteRange.parse("bytes=-90", size: 10) == 0...9)
        #expect(try ByteRange.parse("bytes=2-100", size: 10) == 2...9)
        for bad in ["bytes=10-", "bytes=9-1", "bytes=-0", "bytes=0-1,3-4", "bytes=-", "bytes=a-3", "bytes=0-9999999999999999999999999", "items=0-1"] {
            #expect(throws: ByteRange.self) { try ByteRange.parse(bad, size: 10) }
        }
        #expect(throws: ByteRange.self) { try ByteRange.parse("bytes=0-0", size: 0) }
    }

    @Test func libraryFiltersAndSubtitles() throws {
        let film = try write("Season/Film & One.mkv")
        let srt = try write("Season/Film & One.srt", "1\n00:00:00,000 --> 00:00:01,000\nHello")
        _ = try write("notes.txt")
        _ = try write("empty/readme.txt")
        _ = try write(".hidden.mp4")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.mp4"), withDestinationURL: film)
        let library = try Library(root: directory)
        try #require(library.videos.count == 1)
        #expect(library.videos[0].subtitle == srt.resolvingSymlinksInPath())
        #expect(library.children(of: "0").map(\.title) == ["Season"])
        let didl = library.didl(library.videos, base: "http://192.168.1.2:8200")
        #expect(didl.contains("Film &amp; One"))
        #expect(didl.contains("sec:CaptionInfoEx"))
        #expect(XMLParser(data: Data(didl.utf8)).parse())
        #expect(Library.id(for: film.resolvingSymlinksInPath()) == library.videos[0].id)
    }

    @Test func subtitleCannotEscapeFolder() throws {
        _ = try write("film.mkv")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("film.srt"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(try Library(root: directory).videos[0].subtitle == nil)
    }

    @Test func mixedFoldersAndVideosByDateButEpisodesByNaturalFilename() throws {
        let old = try write("A old/E01.mkv").deletingLastPathComponent()
        let new = try write("Z new/E10.mkv").deletingLastPathComponent()
        let first = try write("Z new/E01.mkv")
        _ = try write("Z new/E02.mkv")
        _ = try write("Z new/E3.mkv")
        let film = try write("Root film.mkv")
        let newest = try write("Newest film.mkv")
        let sameDate = try write("B same date.mkv")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: new.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 150)], ofItemAtPath: film.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: newest.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: sameDate.path)
        let library = try Library(root: directory)
        #expect(library.children(of: "0").map(\.title) == ["Newest film", "B same date", "Z new", "Root film", "A old"])
        #expect(library.children(of: Library.id(for: new.resolvingSymlinksInPath())).map(\.title) == ["E01", "E02", "E3", "E10"])
    }

    @Test func filenamesCannotInvalidateXML() throws {
        _ = try write("Broken\u{0001}Title.mp4")
        let library = try Library(root: directory)
        let response = SOAP.respond(request("Browse", args: "<ObjectID>0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><StartingIndex>0</StartingIndex><RequestedCount>0</RequestedCount>"), service: "ContentDirectory", library: library, base: "http://127.0.0.1")
        #expect(response.status == 200)
        #expect(response.isLibraryBrowse)
        #expect(XMLParser(data: response.body).parse())
        let didl = library.didl(library.videos, base: "http://127.0.0.1")
        #expect(XMLParser(data: Data(didl.utf8)).parse())
        #expect(didl.contains("BrokenTitle"))
        #expect(xml("\u{0}\u{8}\t\n\r\u{FFFE}\u{FFFF}<&🎬") == "\t\n\r&lt;&amp;🎬")
    }

    func request(_ action: String, args: String, service: String = "ContentDirectory") -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/control/content", headers: ["soapaction": "\"urn:schemas-upnp-org:service:\(service):1#\(action)\""], body: Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action) xmlns:u=\"urn:schemas-upnp-org:service:\(service):1\">\(args)</u:\(action)></s:Body></s:Envelope>".utf8))
    }

    @Test func browsePaginationAndMetadata() throws {
        _ = try write("B.mp4"); _ = try write("A.mkv"); _ = try write("C.mov")
        let library = try Library(root: directory)
        let args = "<ObjectID>0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><StartingIndex>1</StartingIndex><RequestedCount>1</RequestedCount><SortCriteria>+dc:title</SortCriteria>"
        let response = SOAP.respond(request("Browse", args: args), service: "ContentDirectory", library: library, base: "http://127.0.0.1:8200")
        #expect(response.status == 200)
        let text = String(decoding: response.body, as: UTF8.self)
        #expect(text.contains("<NumberReturned>1</NumberReturned>"))
        #expect(text.contains("<TotalMatches>3</TotalMatches>"))
        #expect(text.contains("&gt;B&lt;"))
        #expect(XMLParser(data: response.body).parse())
        let all = SOAP.respond(request("Browse", args: args.replacingOccurrences(of: "<StartingIndex>1", with: "<StartingIndex>0").replacingOccurrences(of: "<RequestedCount>1", with: "<RequestedCount>0")), service: "ContentDirectory", library: library, base: "http://127.0.0.1")
        #expect(String(decoding: all.body, as: UTF8.self).contains("<NumberReturned>3</NumberReturned>"))
        let metadata = SOAP.respond(request("Browse", args: args.replacingOccurrences(of: "BrowseDirectChildren", with: "BrowseMetadata").replacingOccurrences(of: "<StartingIndex>1", with: "<StartingIndex>0")), service: "ContentDirectory", library: library, base: "http://127.0.0.1")
        #expect(String(decoding: metadata.body, as: UTF8.self).contains("&lt;container"))
    }

    @Test func soapFaultsAndDescriptions() throws {
        let library = try Library(root: directory)
        let invalid = SOAP.respond(request("Browse", args: "<ObjectID>missing</ObjectID>"), service: "ContentDirectory", library: library, base: "http://127.0.0.1")
        #expect(invalid.status == 500)
        #expect(!invalid.isLibraryBrowse)
        #expect(String(decoding: invalid.body, as: UTF8.self).contains("<errorCode>701</errorCode>"))
        let unknown = SOAP.respond(request("DeleteObject", args: ""), service: "ContentDirectory", library: library, base: "http://127.0.0.1")
        #expect(String(decoding: unknown.body, as: UTF8.self).contains("<errorCode>401</errorCode>"))
        #expect(!unknown.isLibraryBrowse)
        let status = SOAP.respond(request("GetSystemUpdateID", args: ""), service: "ContentDirectory", library: library, base: "http://127.0.0.1")
        #expect(status.status == 200)
        #expect(!status.isLibraryBrowse)
        for source in [DLNAServer.description(uuid: "test"), SOAP.scpd(service: "ContentDirectory"), SOAP.scpd(service: "ConnectionManager")] {
            #expect(XMLParser(data: Data(source.utf8)).parse())
        }
    }

    @Test func httpStreamMetadata() throws {
        let file = try write("sample.mp4", "0123456789")
        let request = HTTPRequest(method: "GET", path: "/media/sample.mp4", headers: ["range": "bytes=2-4"], body: Data())
        let response = HTTPResponse.stream(url: file, type: "video/mp4", request: request)
        #expect(response.status == 206)
        #expect(response.offset == 2)
        #expect(response.count == 3)
        #expect(response.headers["Content-Range"] == "bytes 2-4/10")
        let invalid = HTTPRequest(method: "GET", path: "/media/sample.mp4", headers: ["range": "bytes=10-"], body: Data())
        #expect(HTTPResponse.stream(url: file, type: "video/mp4", request: invalid).status == 416)
    }

    @Test func liveCatalogueAndSubtitlesDoNotInterruptStreaming() async throws {
        let video = try write("Example.mp4", "")
        let file = try FileHandle(forWritingTo: video)
        let size = 16 * 1024 * 1024
        try file.truncate(atOffset: UInt64(size)); try file.close()
        let library = try Library(root: directory)
        let item = try #require(library.videos.first)
        let subtitle = try write("downloaded.srt", "1\n00:00:00,000 --> 00:00:01,000\nHello\n")
        let server = DLNAServer(uuid: UUID().uuidString)
        defer { server.shutdown() }
        let base: String = try await withCheckedThrowingContinuation { continuation in
            server.onState = { running, detail in
                server.onState = nil
                if running { continuation.resume(returning: detail) }
                else { continuation.resume(throwing: NSError(domain: "LanternTests", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])) }
            }
            server.start(library: library, interface: LANInterface(name: "lo0", address: "127.0.0.1", mask: inet_addr("255.0.0.0")), port: 0)
        }
        let port = UInt16(try #require(URLComponents(string: base)?.port))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let mediaURL = URL(string: base + "/media/\(item.id).mp4")!
        let subtitleURL = URL(string: base + "/subtitles/\(item.id).srt")!
        var head = URLRequest(url: mediaURL); head.httpMethod = "HEAD"
        let (_, before) = try await session.data(for: head)
        #expect((before as? HTTPURLResponse)?.value(forHTTPHeaderField: "CaptionInfo.sec") == nil)

        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(socket >= 0)
        defer { Darwin.close(socket) }
        var receiveBuffer: Int32 = 4096
        try #require(setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout.size(ofValue: receiveBuffer))) == 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        try #require(setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(connected == 0)
        let request = Data("GET \(mediaURL.path) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        try #require(request.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) } == request.count)
        var initial = [UInt8](repeating: 0, count: 16)
        let initialCount = Darwin.recv(socket, &initial, initial.count, 0)
        try #require(initialCount > 0)

        server.updateSubtitles([item.id: subtitle], root: directory.appendingPathComponent("wrong-root"))
        let (_, ignored) = try await session.data(from: subtitleURL)
        #expect((ignored as? HTTPURLResponse)?.statusCode == 404)
        server.updateSubtitles([item.id: subtitle], root: library.root)
        let (srt, response) = try await session.data(from: subtitleURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(srt == (try Data(contentsOf: subtitle)))
        let (_, after) = try await session.data(for: head)
        #expect((after as? HTTPURLResponse)?.value(forHTTPHeaderField: "CaptionInfo.sec") == subtitleURL.absoluteString)
        var browse = URLRequest(url: URL(string: base + "/control/content")!)
        browse.httpMethod = "POST"
        let soap = self.request("Browse", args: "<ObjectID>0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><StartingIndex>0</StartingIndex><RequestedCount>0</RequestedCount>")
        browse.httpBody = soap.body; browse.allHTTPHeaderFields = soap.headers
        let (catalogue, _) = try await session.data(for: browse)
        #expect(String(decoding: catalogue, as: UTF8.self).contains("sec:CaptionInfoEx"))
        #expect(String(decoding: catalogue, as: UTF8.self).contains("<UpdateID>\(library.revision &+ 1)</UpdateID>"))

        let added = try write("New season/Fresh.mp4", "new video")
        try FileManager.default.removeItem(at: video)
        server.updateLibrary(try Library(root: directory))
        let (_, removed) = try await session.data(for: head)
        #expect((removed as? HTTPURLResponse)?.statusCode == 404)
        let addedURL = URL(string: base + "/media/\(Library.id(for: added.resolvingSymlinksInPath())).mp4")!
        let (addedData, addedResponse) = try await session.data(from: addedURL)
        #expect((addedResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(addedData == Data("new video".utf8))
        let (updatedCatalogue, _) = try await session.data(for: browse)
        #expect(String(decoding: updatedCatalogue, as: UTF8.self).contains("New season"))
        #expect(String(decoding: updatedCatalogue, as: UTF8.self).contains("<UpdateID>\(library.revision &+ 2)</UpdateID>"))
        server.updateLibrary(try Library(root: added.deletingLastPathComponent()))
        let (unchangedCatalogue, _) = try await session.data(for: browse)
        #expect(unchangedCatalogue == updatedCatalogue)

        var streamed = Data(initial.prefix(initialCount))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.recv(socket, &buffer, buffer.count, 0)
            try #require(count >= 0)
            if count == 0 { break }
            streamed.append(contentsOf: buffer.prefix(count))
        }
        let bodyStart = try #require(streamed.range(of: Data("\r\n\r\n".utf8))?.upperBound)
        #expect(streamed.count - bodyStart == size)
        #expect(streamed[bodyStart...].allSatisfy { $0 == 0 })
    }
}
