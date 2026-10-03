import Foundation
import NaturalLanguage
import LanternCore

struct MediaStream: Decodable, Identifiable, Hashable {
    let index: Int
    let codec_name: String?
    let codec_type: String
    let tags: [String: String]?
    let disposition: [String: Int]?
    var id: Int { index }
    var label: String { "\(tags?["language"] ?? "und") · \(codec_name ?? "unknown")\(tags?["title"].map { " · \($0)" } ?? "")" }
    var isTextSubtitle: Bool { codec_type == "subtitle" && ["subrip", "ass", "ssa", "mov_text", "webvtt", "text"].contains(codec_name ?? "") }
    var isEnglish: Bool { ["eng", "en"].contains((tags?["language"] ?? "").lowercased()) }
    var isForced: Bool { disposition?["forced"] == 1 || (tags?["title"] ?? "").range(of: #"\b(forced|foreign parts only|signs(?: and| &)? songs)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
    var isSDH: Bool { disposition?["hearing_impaired"] == 1 || (tags?["title"] ?? "").range(of: #"\b(sdh|hearing impaired)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
}

enum MediaTools {
    struct Probe: Decodable { let streams: [MediaStream] }
    enum EnglishPlan: Equatable { case ready, extract(Int), download, review(String) }
    static func executable(_ name: String) -> URL? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", "/opt/homebrew/opt/ffmpeg-full/bin/"].map { URL(fileURLWithPath: $0 + name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ name: String, _ arguments: [String]) throws -> Data {
        guard let url = executable(name) else { throw failure("\(name) is not installed. Install FFmpeg to prepare subtitles.") }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // A file avoids filling a stderr pipe while reading stdout.
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close(); try? FileManager.default.removeItem(at: errorURL) }
        process.standardError = errors
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? "Unknown error"
            throw failure(String(detail.suffix(1800)))
        }
        return data
    }

    static func inspect(_ url: URL) throws -> [MediaStream] {
        let data = try run("ffprobe", ["-v", "error", "-show_entries", "stream=index,codec_type,codec_name:stream_tags=language,title:stream_disposition=forced,hearing_impaired", "-of", "json", url.path])
        return try JSONDecoder().decode(Probe.self, from: data).streams
    }

    static func cacheURL(_ item: MediaItem, stream: Int?) throws -> URL {
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Lantern/Subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var source = item.url
        source.removeAllCachedResourceValues()
        let values = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return cache.appendingPathComponent("\(item.id)-\(values.fileSize ?? 0)-\(String(modified.bitPattern, radix: 16))-\(stream.map(String.init) ?? "download").srt")
    }

    static func preferredEnglish(_ streams: [MediaStream]) -> MediaStream? {
        let english = streams.filter { $0.isTextSubtitle && $0.isEnglish && !$0.isForced }
        return english.first(where: { !$0.isSDH }) ?? english.first
    }

    static func englishFingerprint(_ item: MediaItem) throws -> String? {
        guard var subtitle = item.subtitle else { return nil }
        subtitle.removeAllCachedResourceValues()
        let values = try subtitle.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
        return try cacheURL(item, stream: nil).lastPathComponent + "|\(subtitle.path)|\(size)|\(String(modified.timeIntervalSince1970.bitPattern, radix: 16))"
    }

    static func englishPlan(_ item: MediaItem, streams inspect: @autoclosure () throws -> [MediaStream], readyFingerprint: String? = nil) throws -> EnglishPlan {
        if let readyFingerprint, readyFingerprint == (try? englishFingerprint(item)) { return .ready }
        let streams = try inspect()
        var unknownSidecar = false
        if let subtitle = item.subtitle, FileManager.default.fileExists(atPath: subtitle.path) {
            let data = try Data(contentsOf: subtitle, options: .mappedIfSafe)
            let parsed = try parseSRT(data)
            if subtitle == (try cacheURL(item, stream: nil)) { return .ready }
            if let track = preferredEnglish(streams), subtitle == (try cacheURL(item, stream: track.index)) { return .ready }
            let cached = subtitle.deletingLastPathComponent() == (try cacheURL(item, stream: nil)).deletingLastPathComponent()
            if !cached {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(String(parsed.text.prefix(20_000)))
                let english = recognizer.languageHypotheses(withMaximum: 3)[.english] ?? 0
                if parsed.text.count >= 80 && english >= 0.8 { return .ready }
                unknownSidecar = true
            }
        }
        if let track = preferredEnglish(streams) { return .extract(track.index) }
        if unknownSidecar { return .review("Existing SRT language is not confidently English; left unchanged") }
        if streams.contains(where: { $0.isTextSubtitle && ["", "und"].contains(($0.tags?["language"] ?? "und").lowercased()) }) {
            return .review("Embedded text subtitles have no language label")
        }
        return .download
    }

    static func parseSRT(_ data: Data) throws -> (srt: String, text: String) {
        guard data.count <= 8 * 1024 * 1024, let decoded = String(data: data, encoding: .utf8) else { throw failure("Subtitles must be UTF-8 SRT, no larger than 8 MB.") }
        let srt = decoded.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks = srt.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var text: [String] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 3, Int(lines[0].trimmingCharacters(in: .whitespaces)) != nil,
                  lines[1].range(of: #"^\d{2,}:\d{2}:\d{2},\d{3}\s+-->\s+\d{2,}:\d{2}:\d{2},\d{3}(?:\s.*)?$"#, options: .regularExpression) != nil else { throw failure("The subtitle file is not valid SRT.") }
            text.append(lines.dropFirst(2).joined(separator: " "))
        }
        let dialogue = text.joined(separator: " ").replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dialogue.isEmpty else { throw failure("The subtitle file is empty.") }
        return (srt + "\n", dialogue)
    }

    static func extract(_ item: MediaItem, stream: Int) throws -> URL {
        let destination = try cacheURL(item, stream: stream)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let data = try run("ffmpeg", ["-nostdin", "-v", "error", "-i", item.url.path, "-map", "0:\(stream)", "-c:s", "srt", "-f", "srt", "pipe:1"])
        guard !data.isEmpty else { throw failure("The selected subtitle track is empty.") }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func failure(_ text: String) -> NSError { NSError(domain: "Lantern", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
