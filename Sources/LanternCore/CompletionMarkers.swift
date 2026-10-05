import Foundation
import Darwin

struct CompletionMarkers {
    private enum State {
        case unmanaged, blocked
        case ready([String: [Identity]])
    }
    private struct Root: Decodable { let version: Int; let policy: String }
    private struct Record: Decodable {
        let version: Int
        let attempt: String
        let gid: String
        let files: [Entry]
    }
    private struct Entry: Decodable { let path: String; let size: String; let mtime_ns: String }
    private struct Identity { let size: UInt64; let modified: UInt64 }
    private var states: [URL: State] = [:]

    mutating func allows(_ file: URL) -> Bool {
        var root = file.deletingLastPathComponent()
        while true {
            let state = states[root] ?? load(root)
            states[root] = state
            switch state {
            case .unmanaged: break
            case .blocked: return false
            case .ready(let files):
                let relative = String(file.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
                var info = stat()
                guard let identities = files[relative], file.resolvingSymlinksInPath() == file.standardizedFileURL,
                      lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
                      info.st_mtimespec.tv_sec >= 0 else { return false }
                let (seconds, overflow) = UInt64(info.st_mtimespec.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
                let (modified, nanosOverflow) = seconds.addingReportingOverflow(UInt64(info.st_mtimespec.tv_nsec))
                guard !overflow, !nanosOverflow,
                      identities.contains(where: { $0.size == UInt64(info.st_size) && $0.modified == modified }),
                      let names = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".dl-state/v1").path),
                      !names.contains(where: Self.isPending) else { return false }
            }
            if root.path == "/" { return true }
            let parent = root.deletingLastPathComponent()
            if parent.path == root.path { return true }
            root = parent
        }
    }

    private func load(_ root: URL) -> State {
        let metadata = root.appendingPathComponent(".dl-state")
        var info = stat()
        if lstat(metadata.path, &info) != 0 { return errno == ENOENT ? .unmanaged : .blocked }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .blocked }
        let directory = metadata.appendingPathComponent("v1")
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .blocked }
        do {
            let policy: Root = try read(directory.appendingPathComponent("root.json"))
            guard policy.version == 1, policy.policy == "ready-only" else { return .blocked }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard !names.contains(where: Self.isPending) else { return .blocked }
            var files: [String: [Identity]] = [:]
            for name in names where name.hasPrefix("ready-") && name.hasSuffix(".json") {
                let record: Record = try read(directory.appendingPathComponent(name))
                guard record.version == 1, Self.isHex(record.attempt, count: 32), Self.isHex(record.gid, count: 16),
                      name == "ready-\(record.attempt)-\(record.gid).json", !record.files.isEmpty else { return .blocked }
                var paths: Set<String> = []
                for entry in record.files {
                    let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
                    guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".dl-state" }),
                          !entry.path.contains("\0"), paths.insert(entry.path).inserted,
                          let size = Self.decimal(entry.size), let modified = Self.decimal(entry.mtime_ns) else { return .blocked }
                    let file = root.appendingPathComponent(entry.path)
                    guard file.resolvingSymlinksInPath() == file.standardizedFileURL else { return .blocked }
                    files[entry.path, default: []].append(Identity(size: size, modified: modified))
                }
            }
            return .ready(files)
        } catch { return .blocked }
    }

    private func read<T: Decodable>(_ url: URL) throws -> T {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        let limit = 8 * 1024 * 1024
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try file.read(upToCount: limit + 1), data.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func isPending(_ name: String) -> Bool { name.hasPrefix("pending-") && name.hasSuffix(".json") }
    private static func isHex(_ text: String, count: Int) -> Bool { text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func decimal(_ text: String) -> UInt64? {
        guard !text.isEmpty, text == "0" || text.first != "0", text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt64(text)
    }
}
