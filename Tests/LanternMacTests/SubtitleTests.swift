import Foundation
import Testing
import LanternCore
@testable import LanternMac

final class SubtitleTests {
    let directory: URL
    let srt = "1\n00:00:01,000 --> 00:00:05,000\nWe should leave the house before the rain starts. Please bring your coat and remember to close the door behind you.\n\n2\n00:00:06,000 --> 00:00:09,000\nI will meet you at the station this evening, and we can walk home together.\n"
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-subtitle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func video() throws -> MediaItem {
        let url = directory.appendingPathComponent("Example.S01E01.mkv")
        try Data(repeating: 0, count: 131_072).write(to: url)
        return try Library(root: directory).videos[0]
    }

    func tracks(_ json: String) throws -> [MediaStream] { try JSONDecoder().decode(MediaTools.Probe.self, from: Data(json.utf8)).streams }
    func entry(file: Int = 1, feature: Int = 100, hash: Bool = true, language: String = "en", forced: Bool = false, ai: Bool = false, files: Int = 1) -> [String: Any] {
        ["attributes": ["language": language, "moviehash_match": hash, "foreign_parts_only": forced, "hearing_impaired": false, "ai_translated": ai, "machine_translated": false, "from_trusted": true, "download_count": 10, "feature_details": ["feature_id": feature], "files": Array(repeating: ["file_id": file], count: files)]]
    }
    func search(_ entries: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["data": entries]) }
    func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse { HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])! }

    @Test func englishTrackSelectionAndReadiness() throws {
        var item = try video()
        let embedded = try tracks(#"{"streams":[{"index":1,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng","title":"Forced"}},{"index":2,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng","title":"SDH"}},{"index":3,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng"},"disposition":{"forced":0}}]}"#)
        #expect(MediaTools.preferredEnglish(embedded)?.index == 3)
        #expect(try MediaTools.englishPlan(item, streams: embedded) == .extract(3))
        #expect(try MediaTools.englishPlan(item, streams: [embedded[0]]) == .download)
        #expect(MediaTools.preferredEnglish([embedded[1]])?.index == 2)
        let bitmap = try tracks(#"{"streams":[{"index":1,"codec_type":"subtitle","codec_name":"dvd_subtitle","tags":{"language":"eng"}}]}"#)
        #expect(try MediaTools.englishPlan(item, streams: bitmap) == .download)
        let forcedFlag = try tracks(#"{"streams":[{"index":1,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng"},"disposition":{"forced":1}}]}"#)
        #expect(try MediaTools.englishPlan(item, streams: forcedFlag) == .download)
        let forcedCache = try MediaTools.cacheURL(item, stream: 1)
        defer { try? FileManager.default.removeItem(at: forcedCache) }
        try Data(srt.utf8).write(to: forcedCache)
        item.subtitle = forcedCache
        #expect(try MediaTools.englishPlan(item, streams: embedded) == .extract(3))
        #expect(try MediaTools.englishPlan(item, streams: forcedFlag) == .download)
        let sidecar = directory.appendingPathComponent("Example.S01E01.srt")
        try Data(srt.utf8).write(to: sidecar)
        item.subtitle = sidecar
        #expect(try MediaTools.englishPlan(item, streams: []) == .ready)
        try Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8).write(to: sidecar)
        #expect(try MediaTools.englishPlan(item, streams: []).isReview)
    }

    @Test func srtValidation() throws {
        let parsed = try MediaTools.parseSRT(Data(("\u{feff}" + srt.replacingOccurrences(of: "\n", with: "\r\n")).utf8))
        #expect(parsed.srt == srt)
        for invalid in ["", "<html>Not a subtitle</html>", "1\nnot a timestamp\nHello"] {
            #expect(throws: (any Error).self) { try MediaTools.parseSRT(Data(invalid.utf8)) }
        }
        #expect(throws: (any Error).self) { try MediaTools.parseSRT(Data([0xff, 0xfe, 0xff])) }
        #expect(throws: (any Error).self) { try MediaTools.parseSRT(Data(repeating: 0, count: SubtitleTransfer.limit + 1)) }
    }

    @Test func rememberedEnglishSkipsInspectionAcrossRestartsAndInvalidatesChanges() throws {
        var item = try video()
        let sidecar = directory.appendingPathComponent("Example.S01E01.srt")
        try Data(srt.utf8).write(to: sidecar)
        item.subtitle = sidecar
        #expect(try MediaTools.englishPlan(item, streams: []) == .ready)
        let fingerprint = try #require(try MediaTools.englishFingerprint(item))
        let suite = "Lantern.readiness-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([item.id: fingerprint], forKey: "englishReady")
        let restored = try #require(UserDefaults(suiteName: suite)?.dictionary(forKey: "englishReady") as? [String: String])
        func unexpectedInspection() throws -> [MediaStream] { throw MediaTools.failure("Inspection was invoked") }
        #expect(try MediaTools.englishPlan(item, streams: unexpectedInspection(), readyFingerprint: restored[item.id]) == .ready)
        #expect(throws: (any Error).self) { try MediaTools.englishPlan(item, streams: unexpectedInspection()) }

        let videoDate = try #require(item.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try FileManager.default.setAttributes([.modificationDate: videoDate.addingTimeInterval(10)], ofItemAtPath: item.url.path)
        #expect(throws: (any Error).self) { try MediaTools.englishPlan(item, streams: unexpectedInspection(), readyFingerprint: fingerprint) }
        try Data(repeating: 0, count: 131_073).write(to: item.url)
        try FileManager.default.setAttributes([.modificationDate: videoDate], ofItemAtPath: item.url.path)
        #expect(throws: (any Error).self) { try MediaTools.englishPlan(item, streams: unexpectedInspection(), readyFingerprint: fingerprint) }

        let resizedFingerprint = try #require(try MediaTools.englishFingerprint(item))
        let subtitleDate = try #require(sidecar.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try FileManager.default.setAttributes([.modificationDate: subtitleDate.addingTimeInterval(10)], ofItemAtPath: sidecar.path)
        #expect(throws: (any Error).self) { try MediaTools.englishPlan(item, streams: unexpectedInspection(), readyFingerprint: resizedFingerprint) }
        try Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8).write(to: sidecar)
        try FileManager.default.setAttributes([.modificationDate: subtitleDate], ofItemAtPath: sidecar.path)
        #expect(try MediaTools.englishPlan(item, streams: [], readyFingerprint: resizedFingerprint).isReview)
        try FileManager.default.removeItem(at: sidecar)
        #expect(try MediaTools.englishPlan(item, streams: [], readyFingerprint: resizedFingerprint) == .download)
        item.subtitle = nil
        #expect(throws: (any Error).self) { try MediaTools.englishPlan(item, streams: unexpectedInspection(), readyFingerprint: resizedFingerprint) }
    }

    @Test func movieHashUsesBothEndsAndWrappingLittleEndianSum() throws {
        let item = try video()
        #expect(try OpenSubtitles.movieHash(item.url) == "0000000000020000")
        try Data(repeating: 0xff, count: 131_072).write(to: item.url)
        #expect(try OpenSubtitles.movieHash(item.url) == "000000000001c000")
        var bytes = Data(repeating: 0, count: 196_608)
        bytes[0] = 1; bytes[131_073] = 1; bytes[65_536] = 255
        try bytes.write(to: item.url)
        #expect(try OpenSubtitles.movieHash(item.url) == "0000000000030101")
    }

    @Test func confidenceRejectsWrongLanguagePartialAndAmbiguousMatches() throws {
        for entries in [[entry(hash: false)], [entry(language: "fr")], [entry(forced: true)], [entry(ai: true)], [entry(files: 2)], [entry(), entry(file: 2, feature: 101)]] {
            let decoded = try JSONDecoder().decode(OpenSubtitles.Search.self, from: search(entries))
            #expect(OpenSubtitles.confidentFile(decoded.data) == nil)
        }
        let exact = try JSONDecoder().decode(OpenSubtitles.Search.self, from: search([entry(hash: false), entry(file: 2)]))
        #expect(OpenSubtitles.confidentFile(exact.data) == 2)
    }

    @Test func downloadFlowKeepsOriginalsAndCredentialsPrivate() throws {
        let item = try video()
        let original = try Data(contentsOf: item.url)
        let destination = try MediaTools.cacheURL(item, stream: nil)
        defer { try? FileManager.default.removeItem(at: destination) }
        var calls = 0
        let client = OpenSubtitles(apiKey: "synthetic-test-key") { request in
            calls += 1
            switch calls {
            case 1:
                #expect(request.url?.host == "api.opensubtitles.com")
                #expect(request.url?.query?.contains("moviehash_match=only") == true)
                #expect(request.url?.absoluteString.contains(item.title) == false)
                #expect(request.value(forHTTPHeaderField: "Api-Key") == "synthetic-test-key")
                return (try self.search([self.entry()]), self.response(request))
            case 2:
                #expect(request.httpMethod == "POST")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                #expect(body["sub_format"] as? String == "srt")
                #expect(body["file_id"] as? Int == 1)
                return (Data(#"{"link":"https://dl.opensubtitles.com/download/test.srt","remaining":0,"reset_time_utc":"2100-01-01T00:00:00.000Z"}"#.utf8), self.response(request))
            default:
                #expect(request.value(forHTTPHeaderField: "Api-Key") == nil)
                return (Data(self.srt.utf8), self.response(request))
            }
        }
        #expect(try client.download(item) == destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == srt)
        #expect(try Data(contentsOf: item.url) == original)
        #expect(client.remaining == 0)
        #expect(client.resetAt == Date(timeIntervalSince1970: 4_102_444_860))
        #expect(try client.download(item) == destination)
        #expect(calls == 3)
        var cached = item; cached.subtitle = destination
        #expect(try MediaTools.englishPlan(cached, streams: []) == .ready)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: item.url.path)
        #expect(try MediaTools.cacheURL(item, stream: nil) != destination)
        #expect(throws: OpenSubtitles.Failure.self) { try client.download(item) }
        #expect(calls == 3)
        #expect(try MediaTools.englishPlan(cached, streams: []) == .download)
        let beforeResize = try MediaTools.cacheURL(item, stream: nil)
        try Data(repeating: 0, count: 131_073).write(to: item.url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: item.url.path)
        #expect(try MediaTools.cacheURL(item, stream: nil) != beforeResize)
    }

    @Test func failuresDoNotSpendQuotaOnGuessesOrRepeatRateLimits() throws {
        let item = try video()
        var calls = 0
        let noMatch = OpenSubtitles(apiKey: "synthetic-test-key") { request in
            calls += 1
            return (try self.search([self.entry(hash: false)]), self.response(request))
        }
        #expect(throws: OpenSubtitles.Failure.self) { try noMatch.download(item) }
        #expect(calls == 1)
        for status in [401, 403, 406, 429, 503] {
            calls = 0
            let blocked = OpenSubtitles(apiKey: "synthetic-test-key") { request in
                calls += 1
                return (Data(), self.response(request, status: status))
            }
            #expect(throws: OpenSubtitles.Failure.self) { try blocked.download(item) }
            #expect(throws: OpenSubtitles.Failure.self) { try blocked.download(item) }
            #expect(calls == 1)
        }
        #expect(!SubtitleTransfer.allowedDownload(URL(string: "https://opensubtitles.com.evil.invalid/file")!))
        #expect(!SubtitleTransfer.allowedDownload(URL(string: "http://dl.opensubtitles.com/file")!))
        #expect(!SubtitleTransfer.allowedDownload(URL(string: "https://127.0.0.1/file")!))
        #expect(!SubtitleTransfer.allowedDownload(URL(string: "https://user@dl.opensubtitles.com/file")!))
    }

    @Test func quotaFailuresStayTypedAndRememberProviderReset() throws {
        let item = try video()
        let reset = Date(timeIntervalSince1970: 4_102_444_800)
        let expected = reset.addingTimeInterval(60)
        var calls = 0
        let client = OpenSubtitles(apiKey: "synthetic-test-key") { request in
            calls += 1
            return (Data(#"{"remaining":0,"reset_time_utc":"2100-01-01T00:00:00.000Z"}"#.utf8), self.response(request, status: 406))
        }
        for _ in 0..<3 {
            do { _ = try client.download(item); Issue.record("Quota should defer this download") }
            catch OpenSubtitles.Failure.quota { }
        }
        #expect(calls == 1)
        #expect(client.remaining == 0)
        #expect(client.resetAt == expected)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(OpenSubtitles.quotaReset("2100-01-01T00:00:00Z", now: now) == expected)
        for timestamp in [nil, "invalid", "2020-01-01T00:00:00.000Z"] {
            #expect(OpenSubtitles.quotaReset(timestamp, now: now) == now.addingTimeInterval(86_400))
        }
    }

    @Test func quotaQueueRestoresWaitsForResetAndRespectsPauseAndCurrentLibrary() throws {
        let item = try video()
        let suite = "Lantern.queue-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        var queue = SubtitleQueue(defaults: defaults)
        queue.pending = [item.id, "removed-video"]
        queue.retryAt = reset
        queue.save(defaults: defaults)
        var restored = SubtitleQueue(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(restored.pending == queue.pending)
        #expect(restored.due(in: [item], now: reset.addingTimeInterval(-1)).isEmpty)
        #expect(restored.due(in: [item], now: reset) == [item])
        #expect(restored.due(in: [], now: reset).isEmpty)
        restored.paused = true
        restored.save(defaults: defaults)
        #expect(SubtitleQueue(defaults: defaults).due(in: [item], now: reset).isEmpty)
        restored.paused = false
        restored.pending.remove(item.id)
        restored.save(defaults: defaults)
        #expect(SubtitleQueue(defaults: defaults).due(in: [item], now: reset).isEmpty)
    }

    @Test func unsafeDownloadsAndInvalidSRTNeverReachCache() throws {
        let item = try video()
        let destination = try MediaTools.cacheURL(item, stream: nil)
        for link in ["https://127.0.0.1/private", "http://dl.opensubtitles.com/file", "https://dl.opensubtitles.com/file"] {
            var calls = 0
            let client = OpenSubtitles(apiKey: "synthetic-test-key") { request in
                calls += 1
                if calls == 1 { return (try self.search([self.entry()]), self.response(request)) }
                if calls == 2 { return (try JSONSerialization.data(withJSONObject: ["link": link, "remaining": 4]), self.response(request)) }
                return (Data("<html>not subtitles</html>".utf8), self.response(request))
            }
            #expect(throws: (any Error).self) { try client.download(item) }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(calls == (link == "https://dl.opensubtitles.com/file" ? 3 : 2))
        }
    }

    @Test func boundedTransferAndCredentialRedirectProtection() async throws {
        let queue = DispatchQueue(label: "Lantern.subtitle-transfer-test")
        let server = HTTPServer(queue: queue)
        var receivedPaths: [String] = []
        server.handler = { request in
            receivedPaths.append(request.path)
            if request.path == "/large" {
                var response = HTTPResponse()
                response.body = Data(repeating: 1, count: SubtitleTransfer.limit + 1)
                return response
            }
            if request.path == "/redirect" { return HTTPResponse(302, headers: ["Location": "https://api.opensubtitles.com/should-not-be-requested"]) }
            return HTTPResponse(text: "small response")
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            queue.sync {
                server.state = { result in server.state = nil; continuation.resume(with: result) }
                do { try server.start(address: "127.0.0.1", port: 0) }
                catch { continuation.resume(throwing: error) }
            }
        }
        defer { queue.sync { server.stop() } }
        let base = "http://127.0.0.1:\(port)"
        let (data, response) = try SubtitleTransfer.fetch(URLRequest(url: URL(string: base + "/small")!))
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "small response")
        #expect(throws: OpenSubtitles.Failure.self) { try SubtitleTransfer.fetch(URLRequest(url: URL(string: base + "/large")!)) }
        var redirect = URLRequest(url: URL(string: base + "/redirect")!)
        redirect.setValue("synthetic-test-key", forHTTPHeaderField: "Api-Key")
        let (_, redirected) = try SubtitleTransfer.fetch(redirect)
        #expect(redirected.statusCode == 302)
        #expect(queue.sync { receivedPaths } == ["/small", "/large", "/redirect"])
    }
}

extension MediaTools.EnglishPlan {
    var isReview: Bool { if case .review = self { return true }; return false }
}
