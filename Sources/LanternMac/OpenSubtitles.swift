import Foundation
import LanternCore

final class OpenSubtitles {
    struct Search: Decodable { let data: [Entry] }
    struct Entry: Decodable {
        let attributes: Attributes
        struct Attributes: Decodable {
            let language: String
            let moviehash_match: Bool?
            let foreign_parts_only: Bool
            let hearing_impaired: Bool
            let ai_translated: Bool
            let machine_translated: Bool
            let from_trusted: Bool
            let download_count: Int
            let release: String?
            let feature_details: Feature
            let files: [File]
        }
        struct Feature: Decodable {
            let feature_id: Int
            let movie_name: String?
            let title: String?
            let season_number: Int?
            let episode_number: Int?
        }
        struct File: Decodable { let file_id: Int }
    }
    struct Ticket: Decodable { let link: URL; let remaining: Int; let reset_time_utc: String? }
    struct Quota: Decodable { let reset_time_utc: String? }
    struct Candidate: Identifiable {
        let id: Int
        let release: String
        let detail: String
    }
    struct Query {
        var title: String
        var season = ""
        var episode = ""

        init(filename: String) {
            let name = filename.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
            let pattern = #"(?i)\bs([0-9]{1,3})e([0-9]{1,3})\b"#
            let match = try! NSRegularExpression(pattern: pattern).firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
            if let match, let range = Range(match.range, in: name) {
                title = String(name[..<range.lowerBound])
                season = String(Int((name as NSString).substring(with: match.range(at: 1)))!)
                episode = String(Int((name as NSString).substring(with: match.range(at: 2)))!)
            } else {
                let boundary = name.range(of: #"(?i)\s+(?:19\d{2}|20\d{2}|\d{3,4}p|web[ -]?(?:dl|rip)|blu[ -]?ray|brrip|hdtv|[xh]26[45])\b"#, options: .regularExpression)
                title = String(name[..<(boundary?.lowerBound ?? name.endIndex)])
            }
            title = title.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-([")))
        }
    }
    enum Failure: Error, LocalizedError {
        case unavailable(String), noMatch, quota, rateLimit
        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .noMatch: return "No confident full English subtitle match; no download attempted."
            case .quota: return "OpenSubtitles download quota exhausted; queued for automatic retry after reset."
            case .rateLimit: return "OpenSubtitles is rate-limiting requests. Try Find English Subtitles again later."
            }
        }
    }

    let apiKey: String
    let transport: (URLRequest) throws -> (Data, HTTPURLResponse)
    private(set) var remaining: Int?
    private(set) var resetAt: Date?
    private(set) var blocked: String?
    private var nextRequest = Date.distantPast

    init(apiKey: String = Bundle.main.object(forInfoDictionaryKey: "LanternOpenSubtitlesAPIKey") as? String ?? "", transport: @escaping (URLRequest) throws -> (Data, HTTPURLResponse) = SubtitleTransfer.fetch) {
        self.apiKey = apiKey
        self.transport = transport
    }

    static func movieHash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 65_536 else { throw Failure.unavailable("Video is too small for a reliable OpenSubtitles fingerprint.") }
        var hash = size
        for offset in [UInt64(0), size - 65_536] {
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: 65_536), data.count == 65_536 else { throw Failure.unavailable("Video changed while calculating its fingerprint.") }
            for start in stride(from: 0, to: data.count, by: 8) {
                var word: UInt64 = 0
                for byte in 0..<8 { word |= UInt64(data[start + byte]) << (byte * 8) }
                hash = hash &+ word
            }
        }
        return String(format: "%016llx", hash)
    }

    static func confidentFile(_ entries: [Entry]) -> Int? {
        let matches = entries.map(\.attributes).filter {
            $0.language == "en" && $0.moviehash_match == true && !$0.foreign_parts_only && !$0.ai_translated && !$0.machine_translated && $0.files.count == 1 && $0.files[0].file_id > 0
        }
        guard Set(matches.map { $0.feature_details.feature_id }).count == 1 else { return nil }
        return matches.sorted {
            if $0.from_trusted != $1.from_trusted { return $0.from_trusted }
            if $0.hearing_impaired != $1.hearing_impaired { return !$0.hearing_impaired }
            if $0.download_count != $1.download_count { return $0.download_count > $1.download_count }
            return $0.files[0].file_id < $1.files[0].file_id
        }.first?.files[0].file_id
    }

    static func quotaReset(_ timestamp: String?, now: Date = Date()) -> Date {
        if let timestamp {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = formatter.date(from: timestamp)
            if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: timestamp) }
            if let date, date > now { return date.addingTimeInterval(60) }
        }
        return now.addingTimeInterval(24 * 60 * 60)
    }

    func request(_ request: URLRequest) throws -> Data {
        let delay = nextRequest.timeIntervalSinceNow
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        nextRequest = Date().addingTimeInterval(0.3)
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try transport(request) }
        catch { blocked = error.localizedDescription; throw error }
        switch response.statusCode {
        case 200..<300: return data
        case 406:
            remaining = 0
            resetAt = Self.quotaReset((try? JSONDecoder().decode(Quota.self, from: data))?.reset_time_utc)
            throw Failure.quota
        case 429: throw Failure.rateLimit
        case 401, 403:
            blocked = "OpenSubtitles rejected this app's API key. Downloads are unavailable in this build."
            throw Failure.unavailable(blocked!)
        default:
            blocked = "OpenSubtitles request failed (HTTP \(response.statusCode))."
            throw Failure.unavailable(blocked!)
        }
    }

    func searchCandidates(_ query: Query) throws -> [Candidate] {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 3 else { throw Failure.unavailable("Enter a title of at least three characters.") }
        var parameters = [URLQueryItem(name: "query", value: title), URLQueryItem(name: "languages", value: "en"), URLQueryItem(name: "foreign_parts_only", value: "exclude"), URLQueryItem(name: "ai_translated", value: "exclude"), URLQueryItem(name: "machine_translated", value: "exclude")]
        for (name, value) in [("season_number", query.season), ("episode_number", query.episode)] where !value.isEmpty {
            guard let number = Int(value), number >= 0 else { throw Failure.unavailable("Season and episode must be non-negative numbers, or left blank.") }
            parameters.append(URLQueryItem(name: name, value: String(number)))
        }
        var url = URLComponents(string: "https://api.opensubtitles.com/api/v1/subtitles")!
        url.queryItems = parameters
        let results = try JSONDecoder().decode(Search.self, from: request(apiRequest(url.url!)))
        var seen = Set<Int>()
        return results.data.compactMap { entry in
            let a = entry.attributes
            guard a.language == "en", !a.foreign_parts_only, !a.ai_translated, !a.machine_translated, a.files.count == 1,
                  let file = a.files.first, file.file_id > 0, seen.insert(file.file_id).inserted else { return nil }
            let f = a.feature_details
            var detail = [f.movie_name ?? f.title ?? "Unknown title"]
            if let season = f.season_number, let episode = f.episode_number { detail.append("S\(season) E\(episode)") }
            if a.hearing_impaired { detail.append("SDH") }
            if a.from_trusted { detail.append("Trusted uploader") }
            detail.append("\(a.download_count) downloads")
            return Candidate(id: file.file_id, release: a.release ?? "Release not supplied", detail: detail.joined(separator: " · "))
        }
    }

    func apiRequest(_ url: URL) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw Failure.unavailable("This build has no OpenSubtitles API key. Local subtitle extraction still works.") }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Lantern v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func download(_ item: MediaItem, fileID: Int? = nil) throws -> URL {
        let destination = try MediaTools.cacheURL(item, stream: nil)
        if fileID == nil && FileManager.default.fileExists(atPath: destination.path) {
            _ = try MediaTools.parseSRT(Data(contentsOf: destination, options: .mappedIfSafe))
            return destination
        }
        if remaining == 0 { throw Failure.quota }
        if let blocked { throw Failure.unavailable(blocked) }
        guard !apiKey.isEmpty else {
            blocked = "This build has no OpenSubtitles API key. Local subtitle extraction still works."
            throw Failure.unavailable(blocked!)
        }
        do {
            let file: Int
            if let fileID {
                guard fileID > 0 else { throw Failure.noMatch }
                file = fileID
            } else {
                let hash = try Self.movieHash(item.url)
                let search = try apiRequest(URL(string: "https://api.opensubtitles.com/api/v1/subtitles?foreign_parts_only=exclude&languages=en&moviehash=\(hash)&moviehash_match=only")!)
                let results = try JSONDecoder().decode(Search.self, from: request(search))
                guard let match = Self.confidentFile(results.data) else { throw Failure.noMatch }
                file = match
            }
            var ticketRequest = try apiRequest(URL(string: "https://api.opensubtitles.com/api/v1/download")!)
            ticketRequest.httpMethod = "POST"
            ticketRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ticketRequest.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": file, "sub_format": "srt"])
            let ticket = try JSONDecoder().decode(Ticket.self, from: request(ticketRequest))
            remaining = max(0, ticket.remaining)
            resetAt = Self.quotaReset(ticket.reset_time_utc)
            guard SubtitleTransfer.allowedDownload(ticket.link) else { throw Failure.unavailable("OpenSubtitles returned an unsupported download address.") }
            // Never forward the application API key to a subtitle-download host.
            let data = try request(URLRequest(url: ticket.link))
            let parsed = try MediaTools.parseSRT(data)
            guard try MediaTools.cacheURL(item, stream: nil) == destination,
                  UInt64(try item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == item.size else { throw Failure.unavailable("Video changed during the subtitle download; refresh the library and try again.") }
            try Data(parsed.srt.utf8).write(to: destination, options: .atomic)
            return destination
        } catch Failure.quota {
            blocked = Failure.quota.localizedDescription
            throw Failure.quota
        } catch Failure.rateLimit {
            blocked = Failure.rateLimit.localizedDescription
            throw Failure.rateLimit
        }
    }
}

// A transfer is used once, on the media worker; delegate callbacks are serial and signal completion before the worker reads their results.
final class SubtitleTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let limit = 8 * 1024 * 1024
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()
    private var response: HTTPURLResponse?
    private var error: Error?
    private var redirects = 0

    static func allowedDownload(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return url.scheme == "https" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil && (host == "opensubtitles.com" || host.hasSuffix(".opensubtitles.com"))
    }

    static func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let transfer = SubtitleTransfer()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        guard transfer.done.wait(timeout: .now() + 35) == .success else { throw OpenSubtitles.Failure.unavailable("OpenSubtitles request timed out.") }
        if let error = transfer.error { throw error }
        guard let response = transfer.response else { throw OpenSubtitles.Failure.unavailable("OpenSubtitles returned no HTTP response.") }
        return (transfer.data, response)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > Self.limit {
            error = OpenSubtitles.Failure.unavailable("OpenSubtitles response exceeded the 8 MB limit.")
            completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.data.count + data.count <= Self.limit else {
            error = OpenSubtitles.Failure.unavailable("OpenSubtitles response exceeded the 8 MB limit.")
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if self.error == nil, error != nil { self.error = OpenSubtitles.Failure.unavailable("Could not reach OpenSubtitles. Check your internet connection and try again.") }
        done.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard task.originalRequest?.value(forHTTPHeaderField: "Api-Key") == nil, let url = request.url, Self.allowedDownload(url), redirects <= 4 else { completionHandler(nil); return }
        completionHandler(request)
    }
}
