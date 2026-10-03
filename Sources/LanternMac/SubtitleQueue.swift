import Foundation
import LanternCore

struct SubtitleQueue {
    var pending: Set<String>
    var retryAt: Date?
    var paused: Bool

    init(defaults: UserDefaults = .standard) {
        pending = Set(defaults.stringArray(forKey: "subtitleQueue") ?? [])
        retryAt = defaults.object(forKey: "subtitleRetryAt") as? Date
        paused = defaults.bool(forKey: "subtitleQueuePaused")
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(Array(pending).sorted(), forKey: "subtitleQueue")
        defaults.set(retryAt, forKey: "subtitleRetryAt")
        defaults.set(paused, forKey: "subtitleQueuePaused")
    }

    func due(in videos: [MediaItem], now: Date = Date()) -> [MediaItem] {
        guard !paused, retryAt.map({ $0 <= now }) ?? true else { return [] }
        return videos.filter { pending.contains($0.id) }
    }

    var status: String {
        if paused { return "Queued · paused until Prepare English is clicked" }
        if let retryAt { return "Queued · retries after \(retryAt.formatted(date: .abbreviated, time: .shortened))" }
        return "Queued for automatic retry"
    }
}
