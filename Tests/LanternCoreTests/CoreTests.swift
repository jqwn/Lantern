import Foundation
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

    @Test func foldersNewestFirstAndEpisodesByNaturalFilename() throws {
        let old = try write("A old/E01.mkv").deletingLastPathComponent()
        let new = try write("Z new/E10.mkv").deletingLastPathComponent()
        let first = try write("Z new/E01.mkv")
        _ = try write("Z new/E02.mkv")
        _ = try write("Z new/E3.mkv")
        _ = try write("Root film.mkv")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: new.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: first.path)
        let library = try Library(root: directory)
        #expect(library.children(of: "0").map(\.title) == ["Z new", "A old", "Root film"])
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
}
