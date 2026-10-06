import Foundation
import Darwin
import Testing
@testable import LanternCore
@testable import LanternMac

@Test @MainActor func sharingDefaultsOnAndRemembersExplicitStopButNotTemporaryPauses() async throws {
    try #require(Bundle.main.bundleIdentifier != "local.lantern.mac")
    let defaults = UserDefaults.standard
    let keys = ["folder", "uuid", "subtitles", "englishReady", "selectedSubtitleReady", "subtitleQueue", "subtitleRetryAt", "subtitleQueuePaused", "sharingEnabled", "sharingInterface"]
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
    try await selectedAndRequestedPreparationKeepsSharing(directory: directory)
}

@MainActor private func selectedAndRequestedPreparationKeepsSharing(directory: URL) async throws {
    let root = directory.appendingPathComponent("Playback")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("First.mp4"), second = root.appendingPathComponent("Second.mp4"), third = root.appendingPathComponent("Third.mp4")
    for file in [first, second, third] { try Data(repeating: 0, count: 131_072).write(to: file) }
    let library = try Library(root: root)
    let firstItem = try #require(library.videos.first(where: { $0.title == "First" }))
    let secondItem = try #require(library.videos.first(where: { $0.title == "Second" }))
    let thirdItem = try #require(library.videos.first(where: { $0.title == "Third" }))
    let fixture = try SubtitleTests()
    let embedded = try fixture.tracks(#"{"streams":[{"index":1,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng"}}]}"#)
    let extracted = try MediaTools.cacheURL(firstItem, stream: 1)
    let chosen = try MediaTools.cacheURL(secondItem, stream: 2)
    let downloaded = try MediaTools.cacheURL(secondItem, stream: nil)
    defer { for file in [extracted, chosen, downloaded] { try? FileManager.default.removeItem(at: file) } }
    try Data(fixture.srt.utf8).write(to: extracted)
    try Data(fixture.srt.utf8).write(to: chosen)
    let lock = NSLock()
    var inspected: [String] = [], downloads = 0, quotaExhausted = false
    let defaults = UserDefaults.standard
    defaults.set(root.path, forKey: "folder"); defaults.set(false, forKey: "sharingEnabled")
    let server = DLNAServer(uuid: UUID().uuidString)
    let model = AppModel(server: server, inspect: { url in
        lock.lock(); inspected.append(url.lastPathComponent); lock.unlock()
        return url.lastPathComponent == "First.mp4" ? embedded : []
    }, makeDownloads: {
        OpenSubtitles(apiKey: "synthetic-test-key") { request in
            let data: Data
            if request.url!.path == "/api/v1/subtitles" { data = try fixture.search([fixture.entry()]) }
            else if request.url!.path == "/api/v1/download" {
                if lock.withLock({ quotaExhausted }) { return (Data(#"{"reset_time_utc":"2099-01-01T00:00:00Z"}"#.utf8), fixture.response(request, status: 406)) }
                lock.lock(); downloads += 1; lock.unlock()
                data = Data(#"{"link":"https://dl.opensubtitles.com/subtitle.srt","remaining":4}"#.utf8)
            } else { data = Data(fixture.srt.utf8) }
            return (data, fixture.response(request))
        }
    })
    defer { model.shutdown() }
    for _ in 0..<200 {
        if !model.busy { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(!model.busy)
    server.start(library: try #require(model.library), interface: LANInterface(name: "lo0", address: "127.0.0.1", mask: inet_addr("255.0.0.0")), port: 0)
    for _ in 0..<200 {
        if model.sharing { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(model.sharing)
    let base = model.address
    model.selection = firstItem.id
    model.prepareEnglish()
    #expect(model.sharing)
    for _ in 0..<200 {
        if !model.busy { break }
        #expect(model.sharing)
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(!model.busy)
    #expect(model.subtitleResults[firstItem.id] == "English subtitles extracted")
    #expect(model.subtitleResults[secondItem.id] == nil && model.subtitleResults[thirdItem.id] == nil)
    #expect(lock.withLock { inspected } == ["First.mp4"])
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let firstURL = URL(string: "\(base)/media/\(firstItem.id).mp4")!
    let secondURL = URL(string: "\(base)/media/\(secondItem.id).mp4")!
    let (_, ready) = try await session.data(from: firstURL)
    #expect((ready as? HTTPURLResponse)?.value(forHTTPHeaderField: "CaptionInfo.sec") != nil)
    let (_, requested) = try await session.data(from: secondURL)
    #expect((requested as? HTTPURLResponse)?.value(forHTTPHeaderField: "CaptionInfo.sec") != nil)
    #expect(model.library?.items[secondItem.id]?.subtitle == downloaded)
    #expect(lock.withLock { downloads } == 1)
    #expect(lock.withLock { inspected } == ["First.mp4", "Second.mp4"])
    _ = try await session.data(from: secondURL)
    #expect(lock.withLock { downloads } == 1)
    #expect(model.sharing && model.address == base)
    model.selection = secondItem.id; model.subtitleIndex = 2
    model.prepareSelected()
    #expect(model.sharing)
    for _ in 0..<200 {
        if !model.busy { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.library?.items[secondItem.id]?.subtitle == chosen)
    _ = try await session.data(from: secondURL)
    #expect(model.library?.items[secondItem.id]?.subtitle == chosen)
    #expect(lock.withLock { downloads } == 1)
    #expect(model.sharing && model.address == base)
    lock.withLock { quotaExhausted = true }
    model.busy = true
    let thirdURL = URL(string: "\(base)/media/\(thirdItem.id).mp4")!
    let queuedRequest = Task { try await session.data(from: thirdURL) }
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(lock.withLock { !inspected.contains("Third.mp4") })
    model.busy = false
    model.prepareNextRequestedVideo()
    let (_, withoutSubtitles) = try await queuedRequest.value
    #expect((withoutSubtitles as? HTTPURLResponse)?.statusCode == 200)
    #expect((withoutSubtitles as? HTTPURLResponse)?.value(forHTTPHeaderField: "CaptionInfo.sec") == nil)
    #expect(SubtitleQueue(defaults: defaults).pending.contains(thirdItem.id))
    #expect(try #require(SubtitleQueue(defaults: defaults).retryAt) > Date())
    let callsBeforeRepeat = lock.withLock { inspected.count }
    _ = try await session.data(from: thirdURL)
    #expect(lock.withLock { inspected.count } == callsBeforeRepeat)
    #expect(model.sharing && model.address == base)
}
