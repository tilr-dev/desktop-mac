import CoreServices
import Foundation

/// Calls `onChange` on the main queue with the paths that changed under `root`. FSEvents
/// coalesces bursts (an editor's save, a build writing many files) into one call, `latency`
/// seconds (`watch.latency`) after the first change of the burst.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init(_ root: URL, latency: Double, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            // kFSEventStreamCreateFlagUseCFTypes makes eventPaths a CFArray of CFStrings.
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            Unmanaged<FolderWatcher>.fromOpaque(info!).takeUnretainedValue().onChange(paths)
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            // No kFSEventStreamCreateFlagNoDefer: it reports the first change at once and the rest
            // `latency` later, two reloads for one build.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
