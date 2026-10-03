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
            let feature_details: Feature
            let files: [File]
        }
        struct Feature: Decodable { let feature_id: Int }
        struct File: Decodable { let file_id: Int }
    }
    struct Ticket: Decodable { let link: URL; let remaining: Int; let reset_time_utc: String? }
    struct Quota: Decodable { let reset_time_utc: String? }
    enum Failure: Error, LocalizedError {
        case unavailable(String), noMatch, quota, rateLimit
        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .noMatch: return "No confident full English subtitle match; no download attempted."
            case .quota: return "OpenSubtitles download quota exhausted; queued for automatic retry after reset."
            case .rateLimit: return "OpenSubtitles is rate-limiting requests. Try Prepare English again later."
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

    func download(_ item: MediaItem) throws -> URL {
        let destination = try MediaTools.cacheURL(item, stream: nil)
        if FileManager.default.fileExists(atPath: destination.path) {
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
            let hash = try Self.movieHash(item.url)
            var search = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/subtitles?foreign_parts_only=exclude&languages=en&moviehash=\(hash)&moviehash_match=only")!)
            search.setValue(apiKey, forHTTPHeaderField: "Api-Key")
            search.setValue("Lantern v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")", forHTTPHeaderField: "User-Agent")
            search.setValue("application/json", forHTTPHeaderField: "Accept")
            let results = try JSONDecoder().decode(Search.self, from: request(search))
            guard let file = Self.confidentFile(results.data) else { throw Failure.noMatch }
            var ticketRequest = search
            ticketRequest.url = URL(string: "https://api.opensubtitles.com/api/v1/download")!
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
