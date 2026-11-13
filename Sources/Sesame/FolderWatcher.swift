import CoreServices
import Foundation
import SesameEngine

/// The system file events as the watcher sees them. `watch` starts one stream for one folder (subfolders included, file
/// level) and returns the closure that stops it, which is called at most once. `onEvent` runs on the main actor, once per
/// changed path. A source stats for the modified time and reads no content.
@MainActor
protocol ChangeSource: AnyObject {
    func watch(path: String, onEvent: @escaping @MainActor (ChangeEvent) -> Void) -> @MainActor () -> Void
}

/// Watches the folders being read and says "sync needed" to the helper supervisor, once per due request (design
/// sections 3 and 8). It follows `settings.json`: a folder whose `reading` is true has a stream; an untick or a removal
/// stops it. `schedule` and `now` are its only clock.
@MainActor
final class FolderWatcher {
    private struct Stream {
        let token: Int
        /// The real path the stream was started on, resolved once; the debouncer is given the same one.
        let realPath: String
        let stop: @MainActor () -> Void
    }

    private let source: any ChangeSource
    private let settings: () -> Settings
    private let now: () -> Date
    private let schedule: (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void
    private let syncNeeded: () -> Void

    private var started = false
    private var streams: [String: Stream] = [:]
    private var nextToken = 0
    private var debouncer = ChangeDebouncer(roots: [])
    /// Mount points of volumes that went away and have not come back (see `volumeUnmounted`).
    private var awayVolumes: Set<String> = []
    /// When the earliest wake-up still outstanding fires; nil when none is.
    private var wakeAt: Date?

    init(
        source: any ChangeSource, settings: @escaping () -> Settings, now: @escaping () -> Date,
        schedule: @escaping (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void,
        syncNeeded: @escaping () -> Void
    ) {
        self.source = source
        self.settings = settings
        self.now = now
        self.schedule = schedule
        self.syncNeeded = syncNeeded
    }

    /// Starts one stream per folder that is reading. Creating the watcher starts nothing.
    func start() {
        started = true
        follow(settings())
    }

    /// `settings.json` was written: a newly reading folder gets a stream, a folder no longer reading or no longer listed
    /// loses its stream, and the others keep theirs.
    func settingsChanged() {
        guard started else { return }
        follow(settings())
    }

    /// Stops every stream and drops a pending request.
    func stop() {
        started = false
        let running = streams.values
        streams = [:]
        awayVolumes = []
        for stream in running { stream.stop() }
        debouncer = ChangeDebouncer(roots: [])
    }

    /// A volume went away (unplugged, ejected). Its roots keep their streams until it comes back.
    func volumeUnmounted(_ mountPoint: String) {
        guard started else { return }
        awayVolumes.insert(Self.normalized(mountPoint))
    }

    /// A volume was mounted. If it went away before, the stream of every root on it is stopped and started again once:
    /// a stream made before the volume vanished may never report again. Anything else changes nothing.
    func volumeMounted(_ mountPoint: String) {
        guard started, awayVolumes.remove(Self.normalized(mountPoint)) != nil else { return }
        let mount = Self.normalized(mountPoint)
        for (path, stream) in streams where Self.isOn(path, volume: mount) || Self.isOn(stream.realPath, volume: mount) {
            streams[path] = nil
            stream.stop()
        }
        follow(settings())
    }

    private static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The root is the mount point or lies under it, on a path component boundary.
    private static func isOn(_ root: String, volume: String) -> Bool {
        let root = normalized(root)
        return volume == "/" || root == volume || root.hasPrefix(volume + "/")
    }

    private func follow(_ current: Settings) {
        var wanted: [String] = []
        for folder in current.folders where folder.reading && !wanted.contains(folder.path) {
            wanted.append(folder.path)
        }
        for (path, stream) in streams where !wanted.contains(path) {
            streams[path] = nil
            stream.stop()
        }
        for path in wanted where streams[path] == nil {
            nextToken += 1
            let token = nextToken
            let realPath = RealPath.resolve(path)
            let stop = source.watch(path: realPath) { [weak self] event in self?.received(event, from: path, token: token) }
            streams[path] = Stream(token: token, realPath: realPath, stop: stop)
        }
        debouncer.roots = wanted.compactMap { streams[$0]?.realPath }
    }

    /// An event from a stream that was stopped since (an untick, a removal, `stop()`) is ignored.
    private func received(_ event: ChangeEvent, from path: String, token: Int) {
        guard streams[path]?.token == token else { return }
        debouncer.record(event, at: now())
        guard let due = debouncer.dueDate else { return }
        if let wakeAt, wakeAt <= due { return }
        wake(at: due)
    }

    private func wake(at due: Date) {
        wakeAt = due
        schedule(due.timeIntervalSince(now())) { [weak self] in self?.wakeUp() }
    }

    private func wakeUp() {
        wakeAt = nil
        guard started else { return }
        if debouncer.takeDue(at: now()) {
            syncNeeded()
        } else if let due = debouncer.dueDate {
            wake(at: due)
        }
    }
}

/// The real source: `FSEventStreamCreate` with the file-level flag, delivered on the main queue.
@MainActor
final class FSEventsChangeSource: ChangeSource {
    /// How long the system may hold events back to batch them.
    static let latency: CFTimeInterval = 0.5

    private final class Box {
        let onEvent: @MainActor (ChangeEvent) -> Void
        init(_ onEvent: @escaping @MainActor (ChangeEvent) -> Void) { self.onEvent = onEvent }
    }

    func watch(path: String, onEvent: @escaping @MainActor (ChangeEvent) -> Void) -> @MainActor () -> Void {
        let box = Box(onEvent)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<Box>.fromOpaque(info).release() } }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            MainActor.assumeIsolated {
                for index in 0..<count {
                    guard let changed = list[index] as? String else { continue }
                    box.onEvent(ChangeEvent(path: changed, modified: FSEventsChangeSource.modifiedTime(of: changed)))
                }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency, flags)
        else {
            Unmanaged<Box>.fromOpaque(context.info!).release()
            return {}
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return {}
        }
        var stopped = false
        return {
            guard !stopped else { return }
            stopped = true
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// The item's modified time by `lstat`, nil when it is gone. Nothing is opened or read.
    private static func modifiedTime(of path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}
