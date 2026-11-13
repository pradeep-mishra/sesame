import AppKit
import Foundation
import SesameEngine

/// One volume mounted or unmounted. `path` is the volume's mount point, for example `/Volumes/Photos`.
struct MountEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case mounted, unmounted }
    var kind: Kind
    var path: String
}

/// The system's mount notifications as the watcher sees them. `observe` starts delivery to `onEvent` on the main actor,
/// one call per volume mounted or unmounted, and returns the closure that stops it (called at most once per `observe`).
@MainActor
protocol MountEventSource: AnyObject {
    func observe(_ onEvent: @escaping @MainActor (MountEvent) -> Void) -> @MainActor () -> Void
}

/// Says "sync needed" to the helper supervisor when a drive that holds a folder being read is unplugged or comes back
/// (design sections 3 and 8, S7.8). It never reads, writes or deletes a file and never writes `settings.json`: the
/// helper's reconcile removes the rows of a missing root, and a returning drive is read again with no click.
/// `schedule` and `now` are its only clock; `settings` is read afresh at every event.
@MainActor
final class VolumeWatcher {
    /// A request is made this long after the last event of a burst.
    static let quiet: TimeInterval = ChangeDebouncer.quiet
    /// A mounted volume that cannot be listed yet is asked again this often, and given up on after `giveUp`.
    static let pollEvery: TimeInterval = 2
    static let giveUp: TimeInterval = 600

    private struct Pending {
        var event: MountEvent
        var due: Date
        var giveUpAt: Date
    }

    private let source: any MountEventSource
    private let settings: () -> Settings
    private let isReadable: (_ mountPath: String) -> Bool
    private let now: () -> Date
    private let schedule: (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void
    private let syncNeeded: () -> Void
    /// Told of every mount and unmount, related or not, before the sync request is considered (the folder watcher
    /// recreates the stream of a root on a volume that came back).
    private let mountChanged: (MountEvent) -> Void

    private var stopObserving: (@MainActor () -> Void)?
    private var pending: Pending?
    /// When the earliest wake-up still outstanding fires; nil when none is.
    private var wakeAt: Date?

    init(
        source: any MountEventSource, settings: @escaping () -> Settings,
        isReadable: @escaping (_ mountPath: String) -> Bool, now: @escaping () -> Date,
        schedule: @escaping (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void,
        syncNeeded: @escaping () -> Void, mountChanged: @escaping (MountEvent) -> Void = { _ in }
    ) {
        self.source = source
        self.settings = settings
        self.isReadable = isReadable
        self.now = now
        self.schedule = schedule
        self.syncNeeded = syncNeeded
        self.mountChanged = mountChanged
    }

    /// The real "can the folder be listed" check: the names are listed, no file is opened.
    nonisolated static func canList(_ path: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    /// Starts observing. Creating the watcher observes nothing.
    func start() {
        guard stopObserving == nil else { return }
        stopObserving = source.observe { [weak self] event in self?.received(event) }
    }

    /// Stops observing and drops a pending request. A second call does nothing more.
    func stop() {
        pending = nil
        guard let stopObserving else { return }
        self.stopObserving = nil
        stopObserving()
    }

    private func received(_ event: MountEvent) {
        guard stopObserving != nil else { return }
        mountChanged(event)
        guard isRelated(event.path) else { return }
        let arrived = now()
        pending = Pending(
            event: event, due: arrived.addingTimeInterval(Self.quiet), giveUpAt: arrived.addingTimeInterval(Self.giveUp))
        if let wakeAt, wakeAt <= pending!.due { return }
        wake(at: pending!.due)
    }

    private func wake(at due: Date) {
        wakeAt = due
        schedule(due.timeIntervalSince(now())) { [weak self] in self?.wakeUp() }
    }

    private func wakeUp() {
        wakeAt = nil
        guard stopObserving != nil, var request = pending else { return }
        let current = now()
        if current < request.due {
            wake(at: request.due)
            return
        }
        switch request.event.kind {
        case .unmounted:
            pending = nil
            syncNeeded()
        case .mounted:
            if isReadable(request.event.path) {
                pending = nil
                syncNeeded()
            } else if current < request.giveUpAt {
                request.due = current.addingTimeInterval(Self.pollEvery)
                pending = request
                wake(at: request.due)
            } else {
                pending = nil
            }
        }
    }

    /// A volume is related when a folder being read lies at or under its mount point, or the mount point lies at or under
    /// that folder, compared on path components.
    private func isRelated(_ mountPath: String) -> Bool {
        let mount = Self.components(mountPath)
        for folder in settings().folders where folder.reading {
            let root = Self.components(folder.path)
            if root.starts(with: mount) || mount.starts(with: root) { return true }
        }
        return false
    }

    private static func components(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }
}

/// When the folder watcher and the volume watcher exist: exactly while the person wants indexing (Start pressed, the
/// index not deleted) and the app is not quitting. A pause is not an input: a paused app keeps watching, because the
/// supervisor remembers that a sync is needed.
struct WatcherPlan: Equatable {
    var folders: Bool
    var volumes: Bool

    static func decide(settings: Settings, quitting: Bool) -> WatcherPlan {
        let wanted = settings.startPressed && !settings.indexDeleted && !quitting
        return WatcherPlan(folders: wanted, volumes: wanted)
    }
}

/// The real source: the `NSWorkspace` mount and unmount notifications, delivered on the main queue. The unmount is
/// reported once the volume is gone.
@MainActor
final class WorkspaceMountSource: MountEventSource {
    init() {}

    func observe(_ onEvent: @escaping @MainActor (MountEvent) -> Void) -> @MainActor () -> Void {
        let center = NSWorkspace.shared.notificationCenter
        let named: [(Notification.Name, MountEvent.Kind)] = [
            (NSWorkspace.didMountNotification, .mounted), (NSWorkspace.didUnmountNotification, .unmounted),
        ]
        let tokens = named.map { name, kind in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                guard let path = url?.path ?? note.userInfo?["NSDevicePath"] as? String else { return }
                MainActor.assumeIsolated { onEvent(MountEvent(kind: kind, path: path)) }
            }
        }
        var stopped = false
        return {
            guard !stopped else { return }
            stopped = true
            for token in tokens { center.removeObserver(token) }
        }
    }
}
