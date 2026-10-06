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
    try await manualSubtitlePickerRequiresChoiceAndKeepsSharing(directory: directory)
}

@MainActor private func manualSubtitlePickerRequiresChoiceAndKeepsSharing(directory: URL) async throws {
    let root = directory.appendingPathComponent("Picker")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["Example.Show.S02E03.1080p.WEBRip", "Another.Show.S01E01", "Third.Show.S01E01"] {
        try Data(repeating: 0, count: 131_072).write(to: root.appendingPathComponent(name + ".mp4"))
    }
    let fixture = try SubtitleTests(), defaults = UserDefaults.standard
    defaults.set(root.path, forKey: "folder"); defaults.set(false, forKey: "sharingEnabled")
    defaults.removeObject(forKey: "subtitleRetryAt"); defaults.removeObject(forKey: "subtitleQueue")
    let lock = NSLock()
    var titles: [String] = [], chosen: [Int] = [], emptySearch = false, quota = false
    let server = DLNAServer(uuid: UUID().uuidString)
    let model = AppModel(server: server, inspect: { _ in [] }, makeDownloads: {
        OpenSubtitles(apiKey: "synthetic-test-key") { request in
            if request.url?.path == "/api/v1/subtitles" {
                let parameters = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                if let title = parameters.first(where: { $0.name == "query" })?.value {
                    lock.withLock { titles.append(title) }
                    return (try fixture.search(lock.withLock { emptySearch } ? [] : [fixture.entry(file: 41, hash: false), fixture.entry(file: 42, hash: false)]), fixture.response(request))
                }
                return (try fixture.search([]), fixture.response(request))
            }
            if request.url?.path == "/api/v1/download" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                lock.withLock { chosen.append(body["file_id"] as! Int) }
                if lock.withLock({ quota }) { return (Data(#"{"reset_time_utc":"2099-01-01T00:00:00Z"}"#.utf8), fixture.response(request, status: 406)) }
                return (Data(#"{"link":"https://dl.opensubtitles.com/selected.srt","remaining":4}"#.utf8), fixture.response(request))
            }
            return (Data(fixture.srt.utf8), fixture.response(request))
        }
    })
    defer { model.shutdown() }
    for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    let first = try #require(model.library?.videos.first(where: { $0.title.hasPrefix("Example") }))
    let second = try #require(model.library?.videos.first(where: { $0.title.hasPrefix("Another") }))
    let third = try #require(model.library?.videos.first(where: { $0.title.hasPrefix("Third") }))
    let destination = try MediaTools.cacheURL(first, stream: nil)
    defer { try? FileManager.default.removeItem(at: destination) }
    server.start(library: try #require(model.library), interface: LANInterface(name: "lo0", address: "127.0.0.1", mask: inet_addr("255.0.0.0")), port: 0)
    for _ in 0..<200 { if model.sharing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    try #require(model.sharing)
    let base = model.address
    model.prepareEnglish(requestedID: first.id)
    for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(model.subtitlePicker == nil && model.error == nil)
    #expect(lock.withLock { titles.isEmpty && chosen.isEmpty })
    model.selection = first.id; model.prepareEnglish()
    for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    try #require(model.subtitlePicker?.item.id == first.id)
    #expect(model.subtitleCandidates.count == 2 && model.subtitleCandidateID == nil)
    #expect(lock.withLock { titles == ["Example Show"] && chosen.isEmpty })
    #expect(model.error == nil && model.sharing && model.address == base)
    model.downloadSubtitleCandidate()
    #expect(lock.withLock { chosen.isEmpty })
    lock.withLock { emptySearch = true }
    model.subtitleQuery.title = "Different Title"; model.searchSubtitleCandidates()
    for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(model.subtitleCandidates.isEmpty && model.subtitleSearchStatus.contains("No full English"))
    model.subtitlePicker = nil; model.downloadSubtitleCandidate()
    #expect(lock.withLock { chosen.isEmpty })
    lock.withLock { emptySearch = false }
    model.prepareEnglish()
    for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    model.selection = second.id
    model.subtitleCandidateID = 42; model.downloadSubtitleCandidate()
    for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(lock.withLock { chosen == [42] })
    #expect(model.subtitlePicker == nil && model.library?.items[first.id]?.subtitle == destination)
    #expect(model.library?.items[second.id]?.subtitle == nil)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (_, response) = try await session.data(from: URL(string: "\(base)/media/\(first.id).mp4")!)
    #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "CaptionInfo.sec") != nil)
    #expect(lock.withLock { chosen == [42] })
    #expect(model.sharing && model.address == base)
    model.selection = third.id; model.prepareEnglish()
    for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    try #require(model.subtitlePicker?.item.id == third.id)
    try Data(repeating: 0, count: 131_073).write(to: third.url)
    model.subtitleCandidateID = 41; model.downloadSubtitleCandidate()
    for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(model.subtitleSearchStatus.contains("Video changed"))
    #expect(lock.withLock { chosen == [42] })
    model.subtitlePicker = nil
    model.selection = second.id; model.prepareEnglish()
    for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    lock.withLock { quota = true }
    model.subtitleCandidateID = 41; model.downloadSubtitleCandidate()
    for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(model.subtitlePicker?.item.id == second.id && model.subtitleCandidateID == 41)
    #expect(model.subtitleSearchStatus.contains("not been downloaded or queued"))
    #expect(!SubtitleQueue(defaults: defaults).pending.contains(second.id))
    model.downloadSubtitleCandidate()
    #expect(lock.withLock { chosen == [42, 41] })
    #expect(model.sharing && model.address == base)
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
