import Foundation
import CoreServices

final class FolderWatcher {
    private var stream: FSEventStreamRef?

    init(paths: [URL], onChange: @escaping () -> Void) throws {
        let callback = Callback(onChange)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(), retain: { info in
            guard let info else { return nil }
            _ = Unmanaged<Callback>.fromOpaque(info).retain()
            return info
        }, release: { info in
            if let info { Unmanaged<Callback>.fromOpaque(info).release() }
        }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, { _, context, _, _, _, _ in
            if let context { Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue().action() }
        }, &context, paths.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else {
            throw MediaTools.failure("Could not watch the video folder for changes.")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            stop()
            throw MediaTools.failure("Could not start watching the video folder for changes.")
        }
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private final class Callback {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }
}
