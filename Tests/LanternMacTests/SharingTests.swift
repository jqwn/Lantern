import Foundation
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
}
