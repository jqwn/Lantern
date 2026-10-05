import Foundation
import Darwin
import Testing
@testable import LanternMac

@Test @MainActor func sharingDefaultsOnAndRemembersExplicitStopButNotTemporaryPauses() async throws {
    try #require(Bundle.main.bundleIdentifier != "local.lantern.mac")
    let defaults = UserDefaults.standard
    let keys = ["folder", "uuid", "subtitles", "englishReady", "subtitleQueue", "subtitleRetryAt", "subtitleQueuePaused", "sharingEnabled", "sharingInterface"]
    let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
    defer { for key in keys { defaults.set(saved[key], forKey: key) } }
    for key in keys { defaults.removeObject(forKey: key) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-sharing-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    defaults.set(directory.path, forKey: "folder")
    defaults.set("unavailable-test-interface", forKey: "sharingInterface")

    for enabled: Bool? in [nil, false, true] {
        defaults.set(enabled, forKey: "sharingEnabled")
        let model = AppModel()
        for _ in 0..<200 {
            if !model.busy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(!model.busy)
        try #require(model.library != nil)
        // An attempted restore must report the missing saved interface, never fall back to another network.
        #expect((model.error != nil) == (enabled ?? true))
        #expect(!model.sharing && !model.starting)
        defaults.set(true, forKey: "sharingEnabled")
        model.stop(remember: false)
        #expect(defaults.bool(forKey: "sharingEnabled"))
        model.shutdown()
        #expect(defaults.bool(forKey: "sharingEnabled"))
        model.stop()
        #expect(!defaults.bool(forKey: "sharingEnabled"))
        model.shutdown()
    }

    defaults.set(false, forKey: "sharingEnabled")
    let model = AppModel()
    defer { model.shutdown() }
    for _ in 0..<200 {
        if !model.busy { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(!model.busy)
    let nested = directory.appendingPathComponent("New season")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let video = nested.appendingPathComponent("Example.mp4")
    model.busy = true
    try Data("synthetic video".utf8).write(to: video)
    try await Task.sleep(nanoseconds: 1_500_000_000)
    #expect(model.library?.videos.isEmpty == true)
    model.busy = false
    for _ in 0..<120 {
        if model.library?.videos.count == 1 { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(model.library?.videos.first?.title == "Example")
    #expect(!model.sharing && !model.starting)
    try FileManager.default.removeItem(at: video)
    for _ in 0..<120 {
        if model.library?.videos.isEmpty == true { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(model.library?.videos.isEmpty == true)
    let state = nested.appendingPathComponent(".dl-state/v1")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data(#"{"version":1,"policy":"ready-only"}"#.utf8).write(to: state.appendingPathComponent("root.json"), options: .atomic)
    try Data("completed video".utf8).write(to: video)
    try await Task.sleep(nanoseconds: 1_800_000_000)
    #expect(model.library?.videos.isEmpty == true)
    var info = stat()
    try #require(lstat(video.path, &info) == 0)
    let attempt = String(repeating: "a", count: 32), gid = String(repeating: "b", count: 16)
    let record: [String: Any] = ["version": 1, "attempt": attempt, "gid": gid, "files": [["path": video.lastPathComponent, "size": String(info.st_size), "mtime_ns": String(UInt64(info.st_mtimespec.tv_sec) * 1_000_000_000 + UInt64(info.st_mtimespec.tv_nsec))]]]
    try JSONSerialization.data(withJSONObject: record).write(to: state.appendingPathComponent("ready-\(attempt)-\(gid).json"), options: .atomic)
    for _ in 0..<120 {
        if model.library?.videos.count == 1 { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(model.library?.videos.count == 1)
    try Data().write(to: state.appendingPathComponent("pending-\(attempt).json"))
    for _ in 0..<120 {
        if model.library?.videos.isEmpty == true { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(model.library?.videos.isEmpty == true)
    model.shutdown()
    try Data("after shutdown".utf8).write(to: video)
    try await Task.sleep(nanoseconds: 1_500_000_000)
    #expect(model.library?.videos.isEmpty == true)
}
