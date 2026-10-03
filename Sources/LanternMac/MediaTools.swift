import Foundation
import LanternCore

struct MediaStream: Decodable, Identifiable, Hashable {
    let index: Int
    let codec_name: String?
    let codec_type: String
    let tags: [String: String]?
    var id: Int { index }
    var label: String { "\(tags?["language"] ?? "und") · \(codec_name ?? "unknown")\(tags?["title"].map { " · \($0)" } ?? "")" }
    var isTextSubtitle: Bool { codec_type == "subtitle" && ["subrip", "ass", "ssa", "mov_text", "webvtt", "text"].contains(codec_name ?? "") }
}

enum MediaTools {
    struct Probe: Decodable { let streams: [MediaStream] }
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
        let data = try run("ffprobe", ["-v", "error", "-show_entries", "stream=index,codec_type,codec_name:stream_tags=language,title", "-of", "json", url.path])
        return try JSONDecoder().decode(Probe.self, from: data).streams
    }

    static func cacheURL(_ item: MediaItem, stream: Int) throws -> URL {
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Lantern/Subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let modified = try item.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 ?? 0
        return cache.appendingPathComponent("\(item.id)-\(item.size)-\(String(modified.bitPattern, radix: 16))-\(stream).srt")
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
