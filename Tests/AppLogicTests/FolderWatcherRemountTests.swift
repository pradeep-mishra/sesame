import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2 fix round A, tester step: item A11 (S7.8). Written from the fix-round entry A11, the reviewer's finding ("after an
// unplug and replug, the folder watcher's stream is not recreated"; low confidence about FSEvents after a remount) and the
// sealed FolderWatcherTests.swift (shapes and the fake source, own copies below). No product source read beyond
// FolderWatcher.swift, which the entry names.
//
// What the entry fixes (written by hand): "an unmount then a mount event for the volume holding a root stops and
// recreates that root's stream once". One stream per root at all times; a root on another volume is not touched.
//
// SHAPE THESE TESTS PIN (new, on `FolderWatcher`; the entry says "a mount event" and does not say how the watcher hears of
// one, and the watcher today has no volume input. The smallest way is two calls the app makes from the notifications it
// already listens to (NSWorkspace did-unmount and did-mount, as `VolumeWatcher` does). If a shape is wrong, ask for a
// test change rather than guessing):
//     func volumeUnmounted(_ mountPoint: String)   // a volume went away; `mountPoint` is its mount path, e.g. "/Volumes/Photos"
//     func volumeMounted(_ mountPoint: String)     // a volume came back (or a new one appeared)
// A root is "on" a volume when it equals the mount point or lies under it (a path component boundary:
// "/Volumes/PhotosBackup/x" is not on "/Volumes/Photos"; a mount point written with a trailing slash means the same).
// The rule: after `volumeUnmounted(v)` followed by `volumeMounted(v)` the stream of every reading root on v has been stopped
// exactly once and a new one started exactly once (stop and start may happen at either call; both have happened by the end
// of `volumeMounted`); streams of roots on other volumes are untouched; a `volumeMounted` for a volume that was not
// unmounted, a repeated `volumeMounted`, and a mount of an unrelated volume change nothing; a root that was unticked or
// removed while its volume was away gets no new stream. After the remount the new stream works and the old one is
// ignored (an event from it makes no request), as for any stopped stream.
// Red today: none of these compiles (the two methods do not exist).

private let rmPhotos = "/Volumes/Photos/pics"
private let rmArchive = "/Volumes/Photos/archive/old"
private let rmScans = "/w/scans"
private let rmOther = "/Volumes/PhotosBackup/x"

private func rmSettings(_ paths: [String]) throws -> Settings {
    let entries = paths.map { "{\"path\": \"\($0)\", \"code\": false, \"reading\": true}" }.joined(separator: ", ")
    let json = """
    {
      "version": 3, "startPressed": true, "indexDeleted": false, "folders": [\(entries)],
      "codeSearchOn": false,
      "kindsOn": {"photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true},
      "hotkey": "cmd+opt+k",
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
      "speeds": {"photo": 3.0}, "loginDefaultApplied": true
    }
    """
    return try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
}

@MainActor private final class RMSource: ChangeSource {
    private struct Stream {
        let path: String
        let onEvent: @MainActor (ChangeEvent) -> Void
        var stops = 0
    }
    private var streams: [Stream] = []
    private(set) var started: [String] = []
    private(set) var stopped: [String] = []
    private(set) var doubleStops: [String] = []

    func watch(path: String, onEvent: @escaping @MainActor (ChangeEvent) -> Void) -> @MainActor () -> Void {
        let index = streams.count
        streams.append(Stream(path: path, onEvent: onEvent))
        started.append(path)
        return { [self] in
            streams[index].stops += 1
            if streams[index].stops == 1 { stopped.append(path) } else { doubleStops.append(path) }
        }
    }

    var live: [String] { streams.filter { $0.stops == 0 }.map(\.path) }

    func emit(on path: String, _ event: ChangeEvent) {
        guard let stream = streams.last(where: { $0.path == path && $0.stops == 0 }) else {
            Issue.record("the test emitted on \(path) but no live stream watches it (live: \(live))")
            return
        }
        stream.onEvent(event)
    }

    func emitFromStopped(on path: String, _ event: ChangeEvent) {
        guard let stream = streams.last(where: { $0.path == path && $0.stops > 0 }) else {
            Issue.record("the test emitted from a stopped stream of \(path) but none was stopped (stopped: \(stopped))")
            return
        }
        stream.onEvent(event)
    }
}

@MainActor private final class RMClock {
    private(set) var now: Date
    private var pending: [(at: Date, work: @MainActor () -> Void)] = []
    init(_ start: Date) { now = start }
    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) { pending.append((now.addingTimeInterval(max(delay, 0)), work)) }
    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        var runs = 0
        while let next = pending.indices.filter({ pending[$0].at <= target }).min(by: { pending[$0].at < pending[$1].at }) {
            let item = pending.remove(at: next)
            if item.at > now { now = item.at }
            item.work()
            runs += 1
            if runs > 100_000 { Issue.record("the watcher kept scheduling wake-ups without end"); break }
        }
        now = target
    }
}

@MainActor private final class RMBox {
    var settings: Settings
    var syncs = 0
    init(_ settings: Settings) { self.settings = settings }
}

@MainActor private struct RMWorld {
    let source = RMSource()
    let clock = RMClock(Date(timeIntervalSinceReferenceDate: 100_000))
    let box: RMBox
    let watcher: FolderWatcher

    init(roots: [String]) throws {
        let box = RMBox(try rmSettings(roots))
        let clock = clock
        self.box = box
        watcher = FolderWatcher(source: source, settings: { box.settings }, now: { clock.now },
                                schedule: { delay, work in clock.schedule(delay, work) }, syncNeeded: { box.syncs += 1 })
    }

    func change(_ roots: [String]) throws {
        box.settings = try rmSettings(roots)
        watcher.settingsChanged()
    }

    func event(_ root: String, _ name: String) -> ChangeEvent {
        ChangeEvent(path: "\(root)/\(name)", modified: clock.now.addingTimeInterval(-60))
    }
}

@Suite("FolderWatcherRemountTests", .serialized)
@MainActor
struct FolderWatcherRemountTests {

    @Test func anUnmountThenAMountOfTheVolumeHoldingARootStopsAndRecreatesThatRootsStreamOnce() throws {
        let w = try RMWorld(roots: [rmPhotos, rmScans])
        w.watcher.start()
        #expect(w.source.started == [rmPhotos, rmScans], "setup: started \(w.source.started)")

        w.watcher.volumeUnmounted("/Volumes/Photos")
        w.watcher.volumeMounted("/Volumes/Photos")

        #expect(w.source.started == [rmPhotos, rmScans, rmPhotos], "started \(w.source.started), expected the photos stream once more and nothing else")
        #expect(w.source.stopped == [rmPhotos], "stopped \(w.source.stopped), expected the old photos stream once")
        #expect(w.source.doubleStops.isEmpty, "a stream was stopped twice: \(w.source.doubleStops)")
        #expect(Set(w.source.live) == [rmPhotos, rmScans] && w.source.live.count == 2, "live streams \(w.source.live), expected one per root")
    }

    @Test func theNewStreamWorksAndTheOldOneIsIgnored() throws {
        let w = try RMWorld(roots: [rmPhotos, rmScans])
        w.watcher.start()
        w.watcher.volumeUnmounted("/Volumes/Photos")
        w.watcher.volumeMounted("/Volumes/Photos")

        w.source.emitFromStopped(on: rmPhotos, w.event(rmPhotos, "late-from-old.jpg"))
        w.clock.advance(by: 60)
        #expect(w.box.syncs == 0, "an event from the stream of the volume that went away made \(w.box.syncs) requests")

        w.source.emit(on: rmPhotos, w.event(rmPhotos, "back.jpg"))
        w.clock.advance(by: 1.999)
        #expect(w.box.syncs == 0, "a request before 2 s")
        w.clock.advance(by: 0.002)
        #expect(w.box.syncs == 1, "an event on the new stream made \(w.box.syncs) requests, expected 1")

        w.source.emit(on: rmScans, w.event(rmScans, "other.jpg"))
        w.clock.advance(by: 2.001)
        #expect(w.box.syncs == 2, "the root on the other volume stopped working: \(w.box.syncs) requests")
    }

    @Test func everyRootOnTheVolumeIsRecreatedOnceAndNoRootOnAnotherVolumeIs() throws {
        let w = try RMWorld(roots: [rmPhotos, rmArchive, rmScans, rmOther])
        w.watcher.start()
        w.watcher.volumeUnmounted("/Volumes/Photos")
        w.watcher.volumeMounted("/Volumes/Photos")

        #expect(Set(w.source.stopped) == [rmPhotos, rmArchive] && w.source.stopped.count == 2, "stopped \(w.source.stopped)")
        #expect(w.source.started.count == 6 && Set(w.source.started.suffix(2)) == [rmPhotos, rmArchive],
                "started \(w.source.started), expected the two roots of /Volumes/Photos once more (/Volumes/PhotosBackup and /w are not on it)")
        #expect(w.source.live.count == 4, "live \(w.source.live), expected one stream per root")
    }

    @Test func aRepeatedMountEventAndAMountOfAnUnrelatedVolumeChangeNothing() throws {
        let w = try RMWorld(roots: [rmPhotos, rmScans])
        w.watcher.start()
        w.watcher.volumeMounted("/Volumes/Photos")                      // never unmounted
        w.watcher.volumeMounted("/Volumes/Elsewhere")
        #expect(w.source.started == [rmPhotos, rmScans] && w.source.stopped.isEmpty,
                "a mount event for a volume that did not go away changed streams: started \(w.source.started), stopped \(w.source.stopped)")

        w.watcher.volumeUnmounted("/Volumes/Photos")
        w.watcher.volumeMounted("/Volumes/Elsewhere")                    // another volume came back, not this one
        w.watcher.volumeMounted("/Volumes/Photos")
        w.watcher.volumeMounted("/Volumes/Photos")
        w.watcher.volumeMounted("/Volumes/Photos/")                      // the same mount point with a trailing slash
        #expect(w.source.started == [rmPhotos, rmScans, rmPhotos], "started \(w.source.started), expected one new photos stream in all")
        #expect(w.source.stopped == [rmPhotos] && w.source.doubleStops.isEmpty, "stopped \(w.source.stopped), double \(w.source.doubleStops)")
    }

    @Test func anUnmountOfAnUnrelatedVolumeAndOfASiblingThatSharesTheTextTouchesNothing() throws {
        let w = try RMWorld(roots: [rmPhotos, rmScans, rmOther])
        w.watcher.start()
        w.watcher.volumeUnmounted("/Volumes/Elsewhere")
        w.watcher.volumeMounted("/Volumes/Elsewhere")
        w.watcher.volumeUnmounted("/Volumes/Photos")                     // "/Volumes/PhotosBackup/x" is not on it
        w.watcher.volumeMounted("/Volumes/Photos")
        #expect(w.source.started == [rmPhotos, rmScans, rmOther, rmPhotos], "started \(w.source.started)")
        #expect(w.source.stopped == [rmPhotos], "stopped \(w.source.stopped)")
    }

    @Test func settingsChangedAfterARemountMakesNoSecondStreamForTheRoot() throws {
        let w = try RMWorld(roots: [rmPhotos, rmScans])
        w.watcher.start()
        w.watcher.volumeUnmounted("/Volumes/Photos")
        w.watcher.volumeMounted("/Volumes/Photos")
        for _ in 0..<3 { w.watcher.settingsChanged() }
        try w.change([rmPhotos, rmScans])
        #expect(w.source.started == [rmPhotos, rmScans, rmPhotos], "started \(w.source.started), expected one stream per root and one recreation")
        #expect(w.source.live.count == 2, "live \(w.source.live)")
        #expect(w.source.stopped == [rmPhotos], "stopped \(w.source.stopped)")
    }

    @Test func aRootRemovedWhileItsVolumeWasAwayGetsNoNewStreamWhenTheVolumeReturns() throws {
        let w = try RMWorld(roots: [rmPhotos, rmScans])
        w.watcher.start()
        w.watcher.volumeUnmounted("/Volumes/Photos")
        try w.change([rmScans])                                          // the person removed the folder meanwhile
        w.watcher.volumeMounted("/Volumes/Photos")
        #expect(w.source.started == [rmPhotos, rmScans], "a removed root was given a stream again: \(w.source.started)")
        #expect(w.source.live == [rmScans], "live \(w.source.live)")
        #expect(w.source.doubleStops.isEmpty, "a stream was stopped twice: \(w.source.doubleStops)")
    }

    @Test func twoUnplugAndReplugRoundsRecreateTheStreamOncePerRound() throws {
        let w = try RMWorld(roots: [rmPhotos])
        w.watcher.start()
        for _ in 0..<2 {
            w.watcher.volumeUnmounted("/Volumes/Photos")
            w.watcher.volumeMounted("/Volumes/Photos")
        }
        #expect(w.source.started == [rmPhotos, rmPhotos, rmPhotos], "started \(w.source.started)")
        #expect(w.source.stopped == [rmPhotos, rmPhotos] && w.source.doubleStops.isEmpty, "stopped \(w.source.stopped), double \(w.source.doubleStops)")
        #expect(w.source.live == [rmPhotos], "live \(w.source.live)")
    }
}
