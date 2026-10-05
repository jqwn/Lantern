import Foundation
import Darwin
import Testing
@testable import LanternCore

final class CompletionMarkerTests {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("lantern-markers-\(UUID().uuidString)")
    let attempt = String(repeating: "a", count: 32)
    let gid = String(repeating: "b", count: 16)
    var incoming: URL { directory.appendingPathComponent("Incoming") }
    var state: URL { incoming.appendingPathComponent(".dl-state/v1") }
    var ready: URL { state.appendingPathComponent("ready-\(attempt)-\(gid).json") }
    var pending: URL { state.appendingPathComponent("pending-\(attempt).json") }

    init() throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try json(["version": 1, "policy": "ready-only"], to: state.appendingPathComponent("root.json"))
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func json(_ object: Any, to url: URL) throws { try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic) }
    func video(_ name: String) throws -> URL {
        let file = incoming.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic video".utf8).write(to: file)
        return file
    }
    func entry(_ file: URL) throws -> [String: String] {
        var info = stat()
        try #require(lstat(file.path, &info) == 0)
        return ["path": String(file.path.dropFirst(incoming.path.count + 1)), "size": String(info.st_size), "mtime_ns": String(UInt64(info.st_mtimespec.tv_sec) * 1_000_000_000 + UInt64(info.st_mtimespec.tv_nsec))]
    }
    func publish(_ files: [[String: String]]) throws {
        try json(["version": 1, "attempt": attempt, "gid": gid, "files": files], to: ready)
    }

    @Test func onlyExactCompletedMembersAreReadyAcrossRestartsAndSeeding() throws {
        let first = try video("Season/E01.mkv"), second = try video("Season/E02.mkv")
        _ = try video("Season/unlisted.mkv")
        let independent = directory.appendingPathComponent("Independent.mp4")
        try Data("independent".utf8).write(to: independent)
        #expect(try Library(root: directory).videos.map(\.title) == ["Independent"])
        try publish([entry(first), entry(second)])
        try Data().write(to: incoming.appendingPathComponent("Season.aria2"))
        #expect(try Library(root: directory).videos.count == 3)
        #expect(try Library(root: first.deletingLastPathComponent()).videos.count == 2)
        try FileManager.default.removeItem(at: second)
        #expect(try Library(root: directory).videos.count == 2)
        try Data("changed size".utf8).write(to: first)
        #expect(try Library(root: directory).videos.map(\.title) == ["Independent"])
    }

    @Test func pendingSurvivesFailureAndConcurrentCompletion() throws {
        let file = try video("Example.mp4")
        try publish([entry(file)])
        #expect(try Library(root: directory).videos.count == 1)
        // A malformed guard still blocks; no control file or live process is required.
        try Data("interrupted".utf8).write(to: pending)
        #expect(try Library(root: directory).videos.isEmpty)
        let other = state.appendingPathComponent("pending-\(String(repeating: "c", count: 32)).json")
        try Data().write(to: other)
        try FileManager.default.removeItem(at: pending)
        #expect(try Library(root: directory).videos.isEmpty)
        try FileManager.default.removeItem(at: other)
        #expect(try Library(root: directory).videos.count == 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        #expect(try Library(root: directory).videos.isEmpty)
        try publish([entry(file)])
        #expect(try Library(root: directory).videos.count == 1)
    }

    @Test func invalidOptInAndRecordsNeverFallBackToUnmanaged() throws {
        let file = try video("Example.mp4")
        let valid = try entry(file)
        try publish([valid])
        let root = state.appendingPathComponent("root.json")
        for document: [String: Any] in [["version": 2, "policy": "ready-only"], ["version": 1, "policy": "other"], [:]] {
            try json(document, to: root)
            #expect(try Library(root: directory).videos.isEmpty)
        }
        try FileManager.default.removeItem(at: root)
        #expect(try Library(root: directory).videos.isEmpty)
        try json(["version": 1, "policy": "ready-only"], to: root)
        for path in ["/Example.mp4", "../Example.mp4", "./Example.mp4", "Season//E01.mkv", ".dl-state/Example.mp4", "bad\0name.mp4"] {
            var bad = valid; bad["path"] = path
            try publish([valid, bad])
            #expect(try Library(root: directory).videos.isEmpty)
        }
        for size in ["01", "-1", "+1", "1.0", "18446744073709551616"] {
            var bad = valid; bad["size"] = size
            try publish([bad])
            #expect(try Library(root: directory).videos.isEmpty)
        }
        try publish([valid, valid])
        #expect(try Library(root: directory).videos.isEmpty)
        try json(["version": 2, "attempt": attempt, "gid": gid, "files": [valid]], to: ready)
        #expect(try Library(root: directory).videos.isEmpty)
        try publish([valid])
        try FileManager.default.moveItem(at: ready, to: state.appendingPathComponent("ready-wrong.json"))
        #expect(try Library(root: directory).videos.isEmpty)
    }

    @Test func temporaryFilesAreIgnoredAndSymlinksCannotAuthorize() throws {
        let file = try video("Example.mp4")
        let valid = try entry(file)
        try publish([valid])
        try Data("incomplete JSON".utf8).write(to: state.appendingPathComponent(".tmp-ready.json"))
        #expect(try Library(root: directory).videos.count == 1)
        let outside = directory.appendingPathComponent("record.json")
        try FileManager.default.moveItem(at: ready, to: outside)
        try FileManager.default.createSymbolicLink(at: ready, withDestinationURL: outside)
        #expect(try Library(root: directory).videos.isEmpty)
        try FileManager.default.removeItem(at: ready)
        try publish([valid])
        let link = incoming.appendingPathComponent("linked.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        var bad = valid; bad["path"] = "linked.mp4"
        try publish([valid, bad])
        #expect(try Library(root: directory).videos.isEmpty)
        try FileManager.default.removeItem(at: link)
        try publish([valid])
        let metadata = incoming.appendingPathComponent(".dl-state")
        let moved = directory.appendingPathComponent("metadata")
        try FileManager.default.moveItem(at: metadata, to: moved)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: moved)
        #expect(try Library(root: directory).videos.isEmpty)
    }

    @Test func nanosecondIdentityDoesNotRoundAndCachedScanRechecksPending() throws {
        let file = try video("Example.mp4")
        var times = [timespec(tv_sec: 1_790_000_000, tv_nsec: 123_456_789), timespec(tv_sec: 1_790_000_000, tv_nsec: 123_456_789)]
        try #require(utimensat(AT_FDCWD, file.path, &times, 0) == 0)
        let valid = try entry(file)
        try publish([valid])
        var markers = CompletionMarkers()
        let allowed = markers.allows(file)
        #expect(allowed)
        try Data().write(to: pending)
        let guarded = markers.allows(file)
        #expect(!guarded)
        try FileManager.default.removeItem(at: pending)
        var changed = valid; changed["mtime_ns"] = String(try #require(UInt64(valid["mtime_ns"]!)) + 1)
        try publish([changed])
        #expect(try Library(root: directory).videos.isEmpty)
        try publish([valid])
        #expect(try Library(root: directory).videos.count == 1)
    }

    @Test func newStreamRequestsRecheckGuardsWithoutWaitingForRescan() async throws {
        let file = try video("Example.mp4")
        try publish([entry(file)])
        let library = try Library(root: directory)
        let item = try #require(library.videos.first)
        let server = DLNAServer(uuid: UUID().uuidString)
        defer { server.shutdown() }
        let base: String = try await withCheckedThrowingContinuation { continuation in
            server.onState = { running, detail in
                server.onState = nil
                if running { continuation.resume(returning: detail) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
            server.start(library: library, interface: LANInterface(name: "lo0", address: "127.0.0.1", mask: inet_addr("255.0.0.0")), port: 0)
        }
        let url = try #require(URL(string: "\(base)/media/\(item.id).mp4"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, initial) = try await session.data(from: url)
        #expect((initial as? HTTPURLResponse)?.statusCode == 200)
        try Data().write(to: pending)
        let (_, guarded) = try await session.data(from: url)
        #expect((guarded as? HTTPURLResponse)?.statusCode == 404)
        try FileManager.default.removeItem(at: pending)
        let (_, completed) = try await session.data(from: url)
        #expect((completed as? HTTPURLResponse)?.statusCode == 200)
        try Data("changed".utf8).write(to: file)
        let (_, stale) = try await session.data(from: url)
        #expect((stale as? HTTPURLResponse)?.statusCode == 404)
    }
}
