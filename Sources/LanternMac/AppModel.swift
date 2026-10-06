import AppKit
import SwiftUI
import LanternCore

final class AppModel: ObservableObject {
    struct SubtitlePicker: Identifiable {
        let id = UUID()
        let item: MediaItem
        let source: URL
    }
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
    @Published var subtitlePicker: SubtitlePicker?
    @Published var subtitleQuery = OpenSubtitles.Query(filename: "")
    @Published var subtitleCandidates: [OpenSubtitles.Candidate] = []
    @Published var subtitleCandidateID: Int?
    @Published var subtitleSearchStatus = ""
    private var subtitles: [String: URL] = [:]
    private var englishReady = UserDefaults.standard.dictionary(forKey: "englishReady") as? [String: String] ?? [:]
    private var selectedSubtitleReady = UserDefaults.standard.dictionary(forKey: "selectedSubtitleReady") as? [String: String] ?? [:]
    private var subtitleQueue = SubtitleQueue()
    private var subtitleRetryTimer: Timer?
    private var activity: NSObjectProtocol?
    private let server: DLNAServer
    private let inspect: (URL) throws -> [MediaStream]
    private let makeDownloads: () -> OpenSubtitles
    private let worker = DispatchQueue(label: "Lantern.media", qos: .userInitiated)
    private var inspection = UUID()
    private var restoreSharing = UserDefaults.standard.object(forKey: "sharingEnabled") as? Bool ?? true
    private var folderWatcher: FolderWatcher?
    private var watchedFolder: URL?
    private var libraryRefreshTimer: Timer?
    private var shuttingDown = false
    private var requestedVideos: [(String, (Bool) -> Void)] = []

    var videos: [MediaItem] { (library?.videos ?? []).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    var selected: MediaItem? { selection.flatMap { library?.items[$0] } }
    var textTracks: [MediaStream] { streams.filter(\.isTextSubtitle) }

    init(server: DLNAServer? = nil, inspect: @escaping (URL) throws -> [MediaStream] = { try MediaTools.inspect($0) }, makeDownloads: @escaping () -> OpenSubtitles = { OpenSubtitles() }) {
        self.inspect = inspect; self.makeDownloads = makeDownloads
        folder = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "folder") ?? NSHomeDirectory() + "/Downloads/Videos")
        subtitles = (UserDefaults.standard.dictionary(forKey: "subtitles") as? [String: String] ?? [:]).mapValues { URL(fileURLWithPath: $0) }
        let uuid = UserDefaults.standard.string(forKey: "uuid") ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(uuid, forKey: "uuid")
        self.server = server ?? DLNAServer(uuid: uuid)
        let server = self.server
        interfaceID = UserDefaults.standard.string(forKey: "sharingInterface") ?? interfaces.first?.id ?? ""
        server.onLog = { [weak self] message in DispatchQueue.main.async { self?.log(message) } }
        server.onPrepareVideo = { [weak self] item, complete in
            DispatchQueue.main.async {
                guard let self, !self.shuttingDown, self.sharing, self.library?.items[item.id]?.url == item.url else { complete(false); return }
                if let current = self.library?.items[item.id], let fingerprint = try? MediaTools.englishFingerprint(current),
                   fingerprint == self.englishReady[item.id] || fingerprint == self.selectedSubtitleReady[item.id] { complete(true); return }
                self.requestedVideos.append((item.id, complete))
                self.prepareNextRequestedVideo()
            }
        }
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
                self.prepareNextRequestedVideo()
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

    func scheduleLibraryRefresh() {
        guard !shuttingDown, libraryRefreshTimer == nil else { return }
        libraryRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.libraryRefreshTimer = nil
            self.refresh(automatic: true)
        }
    }

    func refresh(automatic: Bool = false) {
        guard !shuttingDown else { return }
        guard !busy, !automatic || !starting else {
            if automatic { scheduleLibraryRefresh() }
            return
        }
        if watchedFolder != folder {
            folderWatcher?.stop(); folderWatcher = nil; watchedFolder = nil
            do {
                folderWatcher = try FolderWatcher(paths: [folder]) { [weak self] in self?.scheduleLibraryRefresh() }
                watchedFolder = folder
            } catch { log(error.localizedDescription) }
        }
        let restoring = restoreSharing, resume = sharing || restoreSharing
        restoreSharing = false
        if !automatic && (sharing || starting) { stop(remember: false) }
        busy = true
        if !automatic { status = "Scanning videos…" }
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
                guard !self.shuttingDown else { return }
                self.busy = false
                defer { self.prepareNextRequestedVideo() }
                switch result {
                case .success(let library):
                    if automatic && self.library?.items == library.items { return }
                    self.library = library
                    if !automatic { self.status = "\(library.videos.count) videos ready" }
                    self.subtitleResults = automatic ? self.subtitleResults.filter { library.items[$0.key] != nil } : [:]
                    if !automatic { self.subtitleQueue.pending.formIntersection(library.videos.map(\.id)) }
                    self.subtitleQueue.save()
                    for id in self.subtitleQueue.pending { self.subtitleResults[id] = self.subtitleQueue.status }
                    self.log("\(automatic ? "Updated library:" : "Scanned") \(library.videos.count) videos; original files unchanged")
                    if automatic { self.server.updateLibrary(library) }
                    else if resume { self.start(restoring: restoring) }
                case .failure(let error):
                    if automatic { self.log("Could not update the library: \(error.localizedDescription)") }
                    else { self.library = nil; self.error = error.localizedDescription; self.status = "Could not read folder" }
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
        let requests = requestedVideos; requestedVideos.removeAll()
        requests.forEach { $0.1(false) }
    }
    func shutdown() {
        shuttingDown = true
        let requests = requestedVideos; requestedVideos.removeAll()
        requests.forEach { $0.1(false) }
        folderWatcher?.stop(); libraryRefreshTimer?.invalidate(); subtitleRetryTimer?.invalidate()
        server.shutdown()
    }

    func inspectSelection() {
        let token = UUID(); inspection = token
        streams = []; subtitleIndex = -1
        guard let item = selected else { detailStatus = "Select a video to inspect its tracks."; return }
        detailStatus = "Reading audio and subtitle tracks…"
        worker.async {
            let result = Result { try self.inspect(item.url) }
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
        let index = subtitleIndex, root = library?.root
        busy = true; status = "Preparing subtitles…"
        worker.async {
            let result = Result { try MediaTools.extract(item, stream: index) }
            DispatchQueue.main.async {
                self.busy = false
                defer { self.prepareNextRequestedVideo() }
                switch result {
                case .success(let url):
                    self.subtitles[item.id] = url; self.library?.items[item.id]?.subtitle = url
                    UserDefaults.standard.set(self.subtitles.mapValues(\.path), forKey: "subtitles")
                    self.status = "Subtitles ready"; self.log("Prepared subtitles for \(item.title)")
                    self.subtitleResults[item.id] = "Selected subtitles ready"
                    self.subtitleQueue.pending.remove(item.id); self.subtitleQueue.save()
                    if let current = self.library?.items[item.id] { self.selectedSubtitleReady[item.id] = try? MediaTools.englishFingerprint(current) }
                    UserDefaults.standard.set(self.selectedSubtitleReady, forKey: "selectedSubtitleReady")
                    if let root { self.server.updateSubtitles([item.id: url], root: root) }
                case .failure(let error): self.error = error.localizedDescription; self.status = "Subtitle preparation failed"
                }
            }
        }
    }

    func prepareNextRequestedVideo() {
        guard !shuttingDown, !busy, !starting, !requestedVideos.isEmpty else { return }
        let (id, complete) = requestedVideos.removeFirst()
        if let item = library?.items[id], let fingerprint = try? MediaTools.englishFingerprint(item),
           fingerprint == englishReady[id] || fingerprint == selectedSubtitleReady[id] {
            complete(true); prepareNextRequestedVideo(); return
        }
        guard !subtitleQueue.paused, library?.items[id] != nil else {
            complete(false); prepareNextRequestedVideo(); return
        }
        prepareEnglish(requestedID: id, completion: complete)
    }

    func prepareEnglish(queuedOnly: Bool = false, requestedID: String? = nil, completion: ((Bool) -> Void)? = nil) {
        guard let library, !busy, !starting, !shuttingDown else { completion?(false); return }
        let videos = queuedOnly ? subtitleQueue.due(in: library.videos) : (requestedID ?? selection).flatMap { library.items[$0] }.map { [$0] } ?? []
        guard !videos.isEmpty else { completion?(false); return }
        let automatic = queuedOnly || requestedID != nil
        busy = true
        if !automatic {
            subtitleQueue.paused = false
            for item in videos { selectedSubtitleReady.removeValue(forKey: item.id) }
            UserDefaults.standard.set(selectedSubtitleReady, forKey: "selectedSubtitleReady")
        }
        let englishReady = englishReady, subtitleQueue = subtitleQueue
        let progress = Progress(totalUnitCount: Int64(videos.count))
        preparation = progress
        worker.async {
            let downloads = self.makeDownloads()
            var prepared: [String: URL] = [:]
            var readiness = englishReady
            var queue = subtitleQueue
            var failures: [String] = []
            var picker: SubtitlePicker?
            var ready = 0, extracted = 0, downloaded = 0, unresolved = 0
            for (index, item) in videos.enumerated() {
                if progress.isCancelled { break }
                DispatchQueue.main.async { self.status = "Preparing English subtitles \(index + 1)/\(videos.count)…" }
                var outcome: String
                var source: URL?
                do {
                    queue.pending.remove(item.id)
                    readiness.removeValue(forKey: item.id)
                    source = try MediaTools.cacheURL(item, stream: nil)
                    let plan = try MediaTools.englishPlan(item, streams: self.inspect(item.url), readyFingerprint: englishReady[item.id])
                    var readyItem = item
                    switch plan {
                    case .ready:
                        readiness[item.id] = try MediaTools.englishFingerprint(item)
                        if let subtitle = item.subtitle { prepared[item.id] = subtitle }
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
                    guard source == (try MediaTools.cacheURL(item, stream: nil)) else { throw MediaTools.failure("Video changed while preparing subtitles; try again after it finishes changing.") }
                } catch OpenSubtitles.Failure.noMatch where !automatic && !progress.isCancelled {
                    unresolved += 1; outcome = "Choose an English subtitle"
                    if let source { picker = SubtitlePicker(item: item, source: source) }
                } catch OpenSubtitles.Failure.quota {
                    queue.pending.insert(item.id)
                    queue.retryAt = downloads.resetAt ?? queue.retryAt ?? OpenSubtitles.quotaReset(nil)
                    outcome = queue.status
                } catch {
                    prepared.removeValue(forKey: item.id); readiness.removeValue(forKey: item.id)
                    unresolved += 1; outcome = "English subtitles unresolved"
                    failures.append("\(item.title): \(error.localizedDescription)")
                }
                let result = outcome
                DispatchQueue.main.async { self.subtitleResults[item.id] = result }
            }
            if downloads.remaining == 0 { queue.retryAt = downloads.resetAt ?? queue.retryAt }
            if progress.isCancelled { queue.paused = true }
            let results = prepared, errors = failures, readyResults = readiness, queuedResults = queue, pendingPicker = picker
            let summary = "\(progress.isCancelled ? "Cancelled: " : "")\(ready) ready · \(extracted) extracted · \(downloaded) downloaded · \(queue.pending.count) queued · \(unresolved) unresolved"
            let quota = downloads.remaining
            DispatchQueue.main.async {
                guard !self.shuttingDown else { completion?(false); return }
                for (id, url) in results { self.subtitles[id] = url; self.library?.items[id]?.subtitle = url }
                UserDefaults.standard.set(self.subtitles.mapValues(\.path), forKey: "subtitles")
                self.englishReady = readyResults
                UserDefaults.standard.set(readyResults, forKey: "englishReady")
                self.subtitleQueue = queuedResults; self.subtitleQueue.save()
                for id in self.subtitleQueue.pending { self.subtitleResults[id] = self.subtitleQueue.status }
                self.server.updateSubtitles(results, root: library.root)
                self.busy = false; self.preparation = nil
                self.status = summary
                self.log(self.status)
                if !self.subtitleQueue.pending.isEmpty { self.log(self.subtitleQueue.status) }
                if let quota { self.log("OpenSubtitles reports \(quota) downloads remaining for this IP today") }
                for error in errors { self.log(error) }
                if !automatic && !errors.isEmpty { self.error = "\(errors.count) videos could not be processed. See Activity for details." }
                completion?(videos.first.map { readyResults[$0.id] != nil } ?? false)
                if let pendingPicker, !progress.isCancelled {
                    self.subtitleQuery = OpenSubtitles.Query(filename: pendingPicker.item.title)
                    self.subtitleCandidates = []; self.subtitleCandidateID = nil
                    self.subtitlePicker = pendingPicker
                    self.searchSubtitleCandidates()
                }
                self.prepareNextRequestedVideo()
            }
        }
    }

    func searchSubtitleCandidates() {
        guard let picker = subtitlePicker, !busy, !shuttingDown else { return }
        let query = subtitleQuery
        busy = true; subtitleCandidates = []; subtitleCandidateID = nil
        subtitleSearchStatus = "Searching OpenSubtitles…"
        worker.async {
            let result = Result {
                guard picker.source == (try MediaTools.cacheURL(picker.item, stream: nil)) else { throw MediaTools.failure("Video changed. Close this picker and search again.") }
                return try self.makeDownloads().searchCandidates(query)
            }
            DispatchQueue.main.async {
                self.busy = false
                defer { self.prepareNextRequestedVideo() }
                guard !self.shuttingDown, self.subtitlePicker?.id == picker.id else { return }
                switch result {
                case .success(let candidates):
                    self.subtitleCandidates = candidates
                    self.subtitleSearchStatus = candidates.isEmpty ? "No full English subtitles found. Edit the title or episode and search again." : "Choose a release matching your video. Timing is not verified."
                case .failure(let error): self.subtitleSearchStatus = error.localizedDescription
                }
            }
        }
    }

    func downloadSubtitleCandidate() {
        guard let picker = subtitlePicker, let fileID = subtitleCandidateID, subtitleCandidates.contains(where: { $0.id == fileID }),
              let library, library.items[picker.item.id]?.url == picker.item.url, !busy, !shuttingDown else { return }
        if let retryAt = subtitleQueue.retryAt, retryAt > Date() {
            subtitleSearchStatus = "Download quota exhausted. Try Download & Use again after \(retryAt.formatted(date: .abbreviated, time: .shortened))."
            return
        }
        busy = true; subtitleSearchStatus = "Downloading selected subtitle…"
        worker.async {
            let downloads = self.makeDownloads()
            let result = Result {
                guard picker.source == (try MediaTools.cacheURL(picker.item, stream: nil)) else { throw MediaTools.failure("Video changed. Close this picker and search again.") }
                let subtitle = try downloads.download(picker.item, fileID: fileID)
                guard picker.source == (try MediaTools.cacheURL(picker.item, stream: nil)) else { throw MediaTools.failure("Video changed during download. Close this picker and search again.") }
                var item = picker.item; item.subtitle = subtitle
                return (subtitle, try MediaTools.englishFingerprint(item))
            }
            DispatchQueue.main.async {
                self.busy = false
                defer { self.prepareNextRequestedVideo() }
                guard !self.shuttingDown, self.subtitlePicker?.id == picker.id else { return }
                if downloads.remaining == 0 { self.subtitleQueue.retryAt = downloads.resetAt; self.subtitleQueue.save() }
                switch result {
                case .success(let (subtitle, fingerprint)):
                    guard self.library?.root == library.root, self.library?.items[picker.item.id]?.url == picker.item.url,
                          picker.source == (try? MediaTools.cacheURL(picker.item, stream: nil)) else {
                        self.subtitleSearchStatus = "Video changed. Close this picker and search again."; return
                    }
                    self.subtitles[picker.item.id] = subtitle; self.library?.items[picker.item.id]?.subtitle = subtitle
                    self.selectedSubtitleReady[picker.item.id] = fingerprint
                    self.englishReady.removeValue(forKey: picker.item.id)
                    UserDefaults.standard.set(self.subtitles.mapValues(\.path), forKey: "subtitles")
                    UserDefaults.standard.set(self.selectedSubtitleReady, forKey: "selectedSubtitleReady")
                    UserDefaults.standard.set(self.englishReady, forKey: "englishReady")
                    self.subtitleQueue.pending.remove(picker.item.id); self.subtitleQueue.save()
                    self.server.updateSubtitles([picker.item.id: subtitle], root: library.root)
                    self.subtitleResults[picker.item.id] = "Selected English subtitle ready"
                    self.status = "Subtitles ready · reopen the video on your TV"
                    self.log("Downloaded selected English subtitle for \(picker.item.title)")
                    self.subtitlePicker = nil
                case .failure(OpenSubtitles.Failure.quota):
                    self.subtitleSearchStatus = "Download quota exhausted. Your choice has not been downloaded or queued; try Download & Use again after \((downloads.resetAt ?? OpenSubtitles.quotaReset(nil)).formatted(date: .abbreviated, time: .shortened))."
                case .failure(let error): self.subtitleSearchStatus = error.localizedDescription
                }
            }
        }
    }
}
