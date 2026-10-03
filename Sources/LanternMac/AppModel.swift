import AppKit
import SwiftUI
import LanternCore

final class AppModel: ObservableObject {
    @Published var folder: URL
    @Published var library: Library?
    @Published var interfaces = LANInterface.available()
    @Published var interfaceID = ""
    @Published var selection: String?
    @Published var search = ""
    @Published var sharing = false
    @Published var starting = false
    @Published var busy = false
    @Published var status = "Ready to share"
    @Published var address = ""
    @Published var logs: [String] = []
    @Published var streams: [MediaStream] = []
    @Published var subtitleIndex = -1
    @Published var detailStatus = "Select a video to inspect its tracks."
    @Published var error: String?
    @Published var showActivity = false
    @Published var preparation: Progress?
    @Published var subtitleResults: [String: String] = [:]
    private var subtitles: [String: URL] = [:]
    private var englishReady = UserDefaults.standard.dictionary(forKey: "englishReady") as? [String: String] ?? [:]
    private var subtitleQueue = SubtitleQueue()
    private var subtitleRetryTimer: Timer?
    private var activity: NSObjectProtocol?
    private let server: DLNAServer
    private let worker = DispatchQueue(label: "Lantern.media", qos: .userInitiated)
    private var inspection = UUID()
    private var restoreSharing = UserDefaults.standard.object(forKey: "sharingEnabled") as? Bool ?? true

    var videos: [MediaItem] { (library?.videos ?? []).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    var selected: MediaItem? { selection.flatMap { library?.items[$0] } }
    var textTracks: [MediaStream] { streams.filter(\.isTextSubtitle) }

    init() {
        folder = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "folder") ?? NSHomeDirectory() + "/Downloads/Videos")
        subtitles = (UserDefaults.standard.dictionary(forKey: "subtitles") as? [String: String] ?? [:]).mapValues { URL(fileURLWithPath: $0) }
        let uuid = UserDefaults.standard.string(forKey: "uuid") ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(uuid, forKey: "uuid")
        server = DLNAServer(uuid: uuid)
        interfaceID = UserDefaults.standard.string(forKey: "sharingInterface") ?? interfaces.first?.id ?? ""
        server.onLog = { [weak self] message in DispatchQueue.main.async { self?.log(message) } }
        server.onPlaybackActivity = { [weak self] active in
            DispatchQueue.main.async {
                guard let self else { return }
                if active && self.activity == nil { self.activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiatedAllowingIdleSystemSleep], reason: "TV browsing or streaming (15-minute idle grace period)") }
                if !active, let activity = self.activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            }
        }
        server.onState = { [weak self] running, message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sharing = running; self.starting = false
                self.status = running ? "Visible to TVs on your network" : message
                self.address = running ? message : ""
                self.log(message)
            }
        }
        refresh()
        subtitleRetryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, !self.busy, !self.starting, let library = self.library, !self.subtitleQueue.due(in: library.videos).isEmpty else { return }
            self.prepareEnglish(queuedOnly: true)
        }
    }

    func log(_ text: String) {
        logs.append("\(Date().formatted(date: .omitted, time: .standard))  \(text)")
        if logs.count > 120 { logs.removeFirst(logs.count - 120) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Only videos and subtitles in this folder will be shared with your local network."
        if panel.runModal() == .OK, let url = panel.url {
            stop(remember: false); folder = url; subtitles = [:]; selection = nil
            restoreSharing = UserDefaults.standard.object(forKey: "sharingEnabled") as? Bool ?? true
            subtitleQueue.pending = []; subtitleQueue.paused = false; subtitleQueue.save()
            UserDefaults.standard.set(url.path, forKey: "folder")
            refresh()
        }
    }

    func refresh() {
        guard !busy else { return }
        let restoring = restoreSharing, resume = sharing || restoreSharing
        restoreSharing = false
        if sharing || starting { stop(remember: false) }
        busy = true; status = "Scanning videos…"
        let root = folder, subtitles = subtitles
        worker.async {
            let result = Result {
                var library = try Library(root: root)
                for item in library.videos {
                    if let cached = subtitles[item.id],
                       (try? MediaTools.cacheURL(item, stream: Int(cached.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? ""))) == cached, FileManager.default.fileExists(atPath: cached.path) {
                        library.items[item.id]?.subtitle = cached
                    }
                }
                return library
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let library):
                    self.library = library; self.status = "\(library.videos.count) videos ready"
                    self.subtitleResults = [:]
                    self.subtitleQueue.pending.formIntersection(library.videos.map(\.id))
                    self.subtitleQueue.save()
                    for id in self.subtitleQueue.pending { self.subtitleResults[id] = self.subtitleQueue.status }
                    self.log("Scanned \(library.videos.count) videos; original files unchanged")
                    if resume { self.start(restoring: restoring) }
                case .failure(let error): self.library = nil; self.error = error.localizedDescription; self.status = "Could not read folder"
                }
            }
        }
    }

    func refreshInterfaces() {
        interfaces = LANInterface.available()
        if !interfaces.contains(where: { $0.id == interfaceID }) { interfaceID = interfaces.first?.id ?? "" }
    }

    func start(restoring: Bool = false) {
        guard !busy, !starting, !sharing, let library else { return }
        if restoring { interfaces = LANInterface.available() }
        else { refreshInterfaces() }
        guard let interface = interfaces.first(where: { $0.id == interfaceID }) else { error = "The selected network is unavailable. Choose a connected Wi-Fi or Ethernet interface and click Start Sharing."; return }
        UserDefaults.standard.set(true, forKey: "sharingEnabled")
        UserDefaults.standard.set(interface.id, forKey: "sharingInterface")
        starting = true; status = "Starting sharing…"
        server.start(library: library, interface: interface)
    }

    func stop(remember: Bool = true) {
        if remember { UserDefaults.standard.set(false, forKey: "sharingEnabled") }
        restoreSharing = false
        server.stop(); sharing = false; starting = false
    }
    func shutdown() { subtitleRetryTimer?.invalidate(); server.shutdown() }

    func inspectSelection() {
        let token = UUID(); inspection = token
        streams = []; subtitleIndex = -1
        guard let item = selected else { detailStatus = "Select a video to inspect its tracks."; return }
        detailStatus = "Reading audio and subtitle tracks…"
        worker.async {
            let result = Result { try MediaTools.inspect(item.url) }
            DispatchQueue.main.async {
                guard self.inspection == token else { return }
                switch result {
                case .success(let streams):
                    self.streams = streams
                    self.subtitleIndex = MediaTools.preferredEnglish(streams)?.index ?? streams.first(where: \.isTextSubtitle)?.index ?? -1
                    let audio = streams.filter { $0.codec_type == "audio" }.map { $0.codec_name ?? "unknown" }.joined(separator: ", ")
                    self.detailStatus = "Audio: \(audio.isEmpty ? "none" : audio) · \(streams.filter { $0.codec_type == "subtitle" }.count) subtitle tracks"
                    if streams.contains(where: { ["dts", "truehd"].contains($0.codec_name ?? "") }) { self.detailStatus += "\nDTS/TrueHD may need audio conversion before this TV can play it." }
                case .failure(let error): self.detailStatus = error.localizedDescription
                }
            }
        }
    }

    func prepareSelected() {
        guard let item = selected, subtitleIndex >= 0, !busy else { return }
        let index = subtitleIndex, resume = sharing
        if sharing { stop(remember: false) }
        busy = true; status = "Preparing subtitles…"
        worker.async {
            let result = Result { try MediaTools.extract(item, stream: index) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let url):
                    self.subtitles[item.id] = url; self.library?.items[item.id]?.subtitle = url
                    UserDefaults.standard.set(self.subtitles.mapValues(\.path), forKey: "subtitles")
                    self.status = "Subtitles ready"; self.log("Prepared subtitles for \(item.title)")
                    self.subtitleResults[item.id] = "Selected subtitles ready"
                    self.subtitleQueue.pending.remove(item.id); self.subtitleQueue.save()
                case .failure(let error): self.error = error.localizedDescription; self.status = "Subtitle preparation failed"
                }
                if resume { self.start() }
            }
        }
    }

    func prepareEnglish(queuedOnly: Bool = false) {
        guard let library, !busy, !starting else { return }
        let videos = queuedOnly ? subtitleQueue.due(in: library.videos) : library.videos
        guard !videos.isEmpty else { return }
        let resume = sharing && !queuedOnly
        if resume { stop(remember: false) }
        busy = true
        if !queuedOnly { subtitleQueue.paused = false }
        let englishReady = englishReady, subtitleQueue = subtitleQueue
        let progress = Progress(totalUnitCount: Int64(videos.count))
        preparation = progress
        if !queuedOnly { subtitleResults = [:] }
        worker.async {
            let downloads = OpenSubtitles()
            var prepared: [String: URL] = [:]
            var readiness = englishReady
            var queue = subtitleQueue
            var failures: [String] = []
            var ready = 0, extracted = 0, downloaded = 0, unresolved = 0
            for (index, item) in videos.enumerated() {
                if progress.isCancelled { break }
                DispatchQueue.main.async { self.status = "Preparing English subtitles \(index + 1)/\(videos.count)…" }
                var outcome: String
                do {
                    queue.pending.remove(item.id)
                    readiness.removeValue(forKey: item.id)
                    let plan = try MediaTools.englishPlan(item, streams: MediaTools.inspect(item.url), readyFingerprint: englishReady[item.id])
                    var readyItem = item
                    switch plan {
                    case .ready:
                        readiness[item.id] = try MediaTools.englishFingerprint(item)
                        ready += 1; outcome = "English subtitles ready"
                    case .extract(let track):
                        let subtitle = try MediaTools.extract(item, stream: track)
                        _ = try MediaTools.parseSRT(Data(contentsOf: subtitle, options: .mappedIfSafe))
                        readyItem.subtitle = subtitle
                        readiness[item.id] = try MediaTools.englishFingerprint(readyItem)
                        prepared[item.id] = subtitle
                        extracted += 1; outcome = "English subtitles extracted"
                    case .download:
                        if let retryAt = queue.retryAt, retryAt > Date() { throw OpenSubtitles.Failure.quota }
                        let subtitle = try downloads.download(item)
                        readyItem.subtitle = subtitle
                        readiness[item.id] = try MediaTools.englishFingerprint(readyItem)
                        prepared[item.id] = subtitle
                        downloaded += 1; outcome = "English subtitles downloaded"
                    case .review(let reason):
                        unresolved += 1; outcome = "Needs review"
                        failures.append("\(item.title): \(reason)")
                    }
                } catch OpenSubtitles.Failure.quota {
                    queue.pending.insert(item.id)
                    queue.retryAt = downloads.resetAt ?? queue.retryAt ?? OpenSubtitles.quotaReset(nil)
                    outcome = queue.status
                } catch {
                    unresolved += 1; outcome = "English subtitles unresolved"
                    failures.append("\(item.title): \(error.localizedDescription)")
                }
                let result = outcome
                DispatchQueue.main.async { self.subtitleResults[item.id] = result }
            }
            if downloads.remaining == 0 { queue.retryAt = downloads.resetAt ?? queue.retryAt }
            if progress.isCancelled { queue.paused = true }
            let results = prepared, errors = failures, readyResults = readiness, queuedResults = queue
            let summary = "\(progress.isCancelled ? "Cancelled: " : "")\(ready) ready · \(extracted) extracted · \(downloaded) downloaded · \(queue.pending.count) queued · \(unresolved) unresolved"
            let quota = downloads.remaining
            DispatchQueue.main.async {
                for (id, url) in results { self.subtitles[id] = url; self.library?.items[id]?.subtitle = url }
                UserDefaults.standard.set(self.subtitles.mapValues(\.path), forKey: "subtitles")
                self.englishReady = readyResults
                UserDefaults.standard.set(readyResults, forKey: "englishReady")
                self.subtitleQueue = queuedResults; self.subtitleQueue.save()
                for id in self.subtitleQueue.pending { self.subtitleResults[id] = self.subtitleQueue.status }
                if queuedOnly { self.server.updateSubtitles(results, root: library.root) }
                self.busy = false; self.preparation = nil
                self.status = summary
                self.log(self.status)
                if !self.subtitleQueue.pending.isEmpty { self.log(self.subtitleQueue.status) }
                if let quota { self.log("OpenSubtitles reports \(quota) downloads remaining for this IP today") }
                for error in errors { self.log(error) }
                if !errors.isEmpty { self.error = "\(errors.count) videos could not be processed. See Activity for details." }
                if resume { self.start() }
            }
        }
    }
}
