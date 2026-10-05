import Foundation
import Testing
@testable import LanternMac

@Test @MainActor func folderWatcherSeesNestedChangesAndStops() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-watcher-tests-\(UUID().uuidString)")
    let nested = directory.appendingPathComponent("Season/Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var events = 0
    let watcher = try FolderWatcher(paths: [directory]) { events += 1 }
    defer { watcher.stop() }
    let video = nested.appendingPathComponent("Example.mp4")
    try Data("synthetic video".utf8).write(to: video)
    for _ in 0..<100 {
        if events > 0 { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try #require(events > 0)
    let beforeRemoval = events
    try FileManager.default.removeItem(at: video)
    for _ in 0..<100 {
        if events > beforeRemoval { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(events > beforeRemoval)
    watcher.stop()
    let stopped = events
    try Data("after stop".utf8).write(to: video)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(events == stopped)
}
