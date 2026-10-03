import Foundation
import LanternCore

@main
struct MediaToolsChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw MediaTools.failure("Usage: media-tools-check VIDEO_FILE (with an English text subtitle track)") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let library = try Library(root: source.deletingLastPathComponent())
        guard let item = library.items[Library.id(for: source)], !item.isFolder else { throw MediaTools.failure("The supplied video is not supported") }
        let streams = try MediaTools.inspect(item.url)
        guard let track = streams.first(where: { $0.isTextSubtitle && $0.tags?["language"] == "eng" }) else { throw MediaTools.failure("English text track missing") }
        let url = try MediaTools.cacheURL(item, stream: track.index)
        let existed = FileManager.default.fileExists(atPath: url.path)
        defer { if !existed { try? FileManager.default.removeItem(at: url) } }
        let extracted = try MediaTools.extract(item, stream: track.index)
        let text = try String(contentsOf: extracted, encoding: .utf8)
        guard text.contains(" --> "), text.count > 100 else { throw MediaTools.failure("Subtitle output is not valid SRT") }
        let cached = try MediaTools.extract(item, stream: track.index)
        guard cached == extracted else { throw MediaTools.failure("Cache was not reused") }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-cache-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fixture = temporary.appendingPathComponent("sample.mp4")
        try Data("video".utf8).write(to: fixture)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1700000000.25)], ofItemAtPath: fixture.path)
        let first = try MediaTools.cacheURL(Library(root: temporary).videos[0], stream: 0)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1700000000.75)], ofItemAtPath: fixture.path)
        let second = try MediaTools.cacheURL(Library(root: temporary).videos[0], stream: 0)
        guard first != second else { throw MediaTools.failure("Subsecond file changes did not invalidate the subtitle cache") }
        print("PASS: FFprobe track inspection, English SRT extraction, cache reuse and subsecond cache invalidation")
    }
}
