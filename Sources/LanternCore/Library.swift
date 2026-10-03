import Foundation
import CryptoKit

public struct MediaItem: Identifiable, Hashable {
    public let id: String
    public let parentID: String
    public let title: String
    public let url: URL
    public let isFolder: Bool
    public let size: UInt64
    public var subtitle: URL?
    var modifiedAt: TimeInterval = 0

    public var mime: String {
        switch url.pathExtension.lowercased() {
        case "mkv": return "video/x-matroska"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "ts", "mts", "m2ts": return "video/mp2t"
        case "mpg", "mpeg": return "video/mpeg"
        default: return "video/mp4"
        }
    }
}

public struct Library {
    public let root: URL
    public var items: [String: MediaItem]
    public let revision: UInt32
    public var videos: [MediaItem] { items.values.filter { !$0.isFolder }.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending } }
    public static let extensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "mts", "m2ts", "mpg", "mpeg"]

    public init(root: URL, subtitles: [String: URL] = [:]) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        revision = UInt32(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: Double(UInt32.max)))
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let rootValues = try self.root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true else { throw CocoaError(.fileReadInvalidFileName) }
        items = ["0": MediaItem(id: "0", parentID: "-1", title: self.root.lastPathComponent, url: self.root, isFolder: true, size: 0)]
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: self.root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else { throw CocoaError(.fileReadNoPermission) }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            let folder = values.isDirectory == true
            guard folder || (values.isRegularFile == true && Self.extensions.contains(url.pathExtension.lowercased())) else { continue }
            let id = Self.id(for: url)
            let parent = url.deletingLastPathComponent().standardizedFileURL
            let sidecar = url.deletingPathExtension().appendingPathExtension("srt")
            let safeSidecar = sidecar.resolvingSymlinksInPath().path.hasPrefix(self.root.path + "/") && FileManager.default.fileExists(atPath: sidecar.path)
            items[id] = MediaItem(id: id, parentID: parent.path == self.root.path ? "0" : Self.id(for: parent), title: folder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent, url: url, isFolder: folder, size: UInt64(values.fileSize ?? 0), subtitle: subtitles[id] ?? (safeSidecar ? sidecar.resolvingSymlinksInPath() : nil))
            if folder { items[id]?.modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? 0 }
        }
        if let scanError { throw scanError }
        // Only advertise folders that contain playable media, including through descendants.
        var retained: Set<String> = ["0"]
        for video in items.values where !video.isFolder {
            retained.insert(video.id)
            var parent = video.parentID
            while parent != "0", let item = items[parent] { retained.insert(parent); parent = item.parentID }
        }
        items = items.filter { retained.contains($0.key) }
    }

    public static func id(for url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public func children(of id: String) -> [MediaItem] {
        items.values.filter { $0.parentID == id }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            if $0.isFolder && $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    public func didl(_ entries: [MediaItem], base: String) -> String {
        let body = entries.map { item -> String in
            let common = "id=\"\(item.id)\" parentID=\"\(item.parentID)\" restricted=\"1\""
            let title = "<dc:title>\(xml(item.title))</dc:title>"
            if item.isFolder { return "<container \(common) childCount=\"\(children(of: item.id).count)\">\(title)<upnp:class>object.container.storageFolder</upnp:class></container>" }
            let subtitle = item.subtitle == nil ? "" : "<sec:CaptionInfoEx sec:type=\"srt\">\(xml(base))/subtitles/\(item.id).srt</sec:CaptionInfoEx>"
            return "<item \(common)>\(title)<upnp:class>object.item.videoItem</upnp:class><res protocolInfo=\"http-get:*:\(item.mime):DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\" size=\"\(item.size)\">\(xml(base))/media/\(item.id).\(item.url.pathExtension.lowercased())</res>\(subtitle)</item>"
        }.joined()
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:sec=\"http://www.sec.co.kr/\">\(body)</DIDL-Lite>"
    }
}

public func xml(_ value: String) -> String {
    let scalars = value.unicodeScalars.filter { scalar in
        let code = scalar.value
        return code == 0x9 || code == 0xA || code == 0xD || (0x20...0xD7FF).contains(code) || (0xE000...0xFFFD).contains(code) || (0x10000...0x10FFFF).contains(code)
    }
    return String(String.UnicodeScalarView(scalars)).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
}
