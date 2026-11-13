import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t37, tester step (2 of 2): `FolderWatcher`, which watches the folders being read and tells the helper
// supervisor that a sync is needed (S7.6, S7.7, S7.15). Written from the t37 entry (its Tests paragraph), design
// sections 2 ("Folder watcher: keep file-level FSEvents [read]"), 3 ("Folder changes") and 8 ("FSEvents, 2 s debounce, a
// file modified under 2 s ago waits"), the t31 tester pins (`HelperSupervisor.syncNeeded()`) and the existing test files as
// the one place existing names are read (`Settings`, `Settings.Folder` as the JSON keys `path`, `code`, `reading`).
// No product source was read. Every count, path and flag below is written by hand from what each test builds.
//
// API SHAPES these tests pin (ChangeEvent, ChangeDebouncer: see ChangeDebouncerTests.swift, pins 1 to 3). The entry names
// `FolderWatcher`, `ChangeSource`, `HelperSupervisor.syncNeeded()`, "a manual clock" and `FSEventStreamCreate` with the
// file-level flag, and fixes no signatures. If a shape below is wrong, ask for a test change rather than guessing.
//   4. `ChangeSource` (new, in the `Sesame` target): the seam over the system file events.
//        @MainActor protocol ChangeSource: AnyObject {
//            func watch(path: String, onEvent: @escaping @MainActor (ChangeEvent) -> Void) -> @MainActor () -> Void
//        }
//      `watch` starts one stream for one folder (everything under it, subfolders included, file-level events) and returns
//      the closure that stops it; the closure is called at most once per stream. `onEvent` is called on the main actor,
//      one call per changed path (a batch of system events is several calls); the real source gets this by giving
//      `FSEventStreamSetDispatchQueue` the main queue. `ChangeEvent.path` is the full path of the changed item, and
//      `modified` is its modified time read when the event is delivered, nil when the item is gone. The source reads no
//      file content (a stat is not a read).
//   5. `FSEventsChangeSource` (new, in the `Sesame` target): the real `ChangeSource`, `init()` with no arguments, built
//      on `FSEventStreamCreate` with the file-level flag (`kFSEventStreamCreateFlagFileEvents`).
//   6. `@MainActor final class FolderWatcher`:
//        init(source: any ChangeSource,
//             settings: @escaping () -> Settings,       // the app passes `{ (try? SettingsFile().read()) ?? Settings() }`
//             now: @escaping () -> Date,
//             schedule: @escaping (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void,
//             syncNeeded: @escaping () -> Void)         // the app passes `{ supervisor.syncNeeded() }`
//        func start()            // reads `settings()` once and starts one stream per folder whose `reading` is true,
//                                // with the folder's `path` exactly as `settings.json` holds it. Creating the watcher
//                                // starts nothing.
//        func settingsChanged()  // reads `settings()` again: starts a stream for a folder that is reading and not yet
//                                // watched, stops the stream of a folder that is no longer reading or no longer in the
//                                // list; a folder whose state did not change keeps its stream (no second stream, no stop).
//                                // The watcher's `ChangeDebouncer` roots follow the same list. (The app calls it where it
//                                // calls `StatusCache.settingsChanged()`: after every write of `settings.json`.)
//        func stop()             // stops every stream once, drops a pending request, and later events call nothing
//      `schedule(delay, work)` means "run `work` on the main actor after `delay` seconds"; the watcher uses it, with
//      `now`, as its only clock (no `Timer`, no `Date()`, no sleep of its own): it may ask for wake-ups as often as it
//      likes, and a wake-up that finds nothing due must leave a later wake-up in place. It calls `syncNeeded` once per
//      due request (the debouncer's `takeDue`), never before the request is due, and records each event at `now()` of
//      its arrival. The manual clock below runs every wake-up that is due, in time order, as time is moved.
// Not pinned, on purpose: what the watcher does with a stream that fails to start, a folder that does not exist, the
// stream's latency, `start()` called twice, `settingsChanged()` before `start()`, and the type of `Settings` construction
// (the tests decode it from JSON, the way SettingsModelTests does).
//
// SUITE. No test sets HOME. The fake-source tests are synchronous. The real tests make a temp folder under TMPDIR, use
// the real system file events and the real clock, start no app and no helper, and allow 15 s per observation (the 2 s
// debounce is asserted with the manual clock, not there).

private let fwRoot = "/w/photos"
private let fwScans = "/w/scans"
private let fwOld = "/w/old"

// MARK: building `Settings`

private func fwSettings(_ folders: [(path: String, reading: Bool)]) throws -> Settings {
    let entries = folders.map { "{\"path\": \"\($0.path)\", \"code\": false, \"reading\": \($0.reading)}" }.joined(separator: ", ")
    let json = """
    {
      "version": 3,
      "startPressed": true,
      "indexDeleted": false,
      "folders": [\(entries)],
      "codeSearchOn": false,
      "kindsOn": {"photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true},
      "hotkey": "cmd+opt+k",
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
      "speeds": {"photo": 3.0},
      "loginDefaultApplied": true
    }
    """
    return try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
}

// MARK: the fake source

@MainActor private final class FWSource: ChangeSource {
    private struct Stream {
        let path: String
        let onEvent: @MainActor (ChangeEvent) -> Void
        var stops = 0
    }

    private var streams: [Stream] = []
    private(set) var started: [String] = []        // one entry per `watch` call, in order
    private(set) var stopped: [String] = []        // one entry per stream stopped, in order
    private(set) var doubleStops: [String] = []    // a stream whose stop closure ran a second time

    func watch(path: String, onEvent: @escaping @MainActor (ChangeEvent) -> Void) -> @MainActor () -> Void {
        let index = streams.count
        streams.append(Stream(path: path, onEvent: onEvent))
        started.append(path)
        return { [self] in
            streams[index].stops += 1
            if streams[index].stops == 1 { stopped.append(path) } else { doubleStops.append(path) }
        }
    }

    var live: [String] { streams.filter { $0.stops == 0 }.map { $0.path } }

    // An event on the newest stream for `root` that has not been stopped.
    func emit(on root: String, _ event: ChangeEvent) {
        guard let stream = streams.last(where: { $0.path == root && $0.stops == 0 }) else {
            Issue.record("the test emitted on \(root) but no live stream watches it (live: \(live))")
            return
        }
        stream.onEvent(event)
    }

    // An event from the newest stream for `root` that was stopped: a delivery that raced with the stop.
    func emitFromStopped(on root: String, _ event: ChangeEvent) {
        guard let stream = streams.last(where: { $0.path == root && $0.stops > 0 }) else {
            Issue.record("the test emitted from a stopped stream of \(root) but none was stopped (stopped: \(stopped))")
            return
        }
        stream.onEvent(event)
    }
}

// MARK: the manual clock

@MainActor private final class FWClock {
    private(set) var now: Date
    private var pending: [(at: Date, work: @MainActor () -> Void)] = []

    init(_ start: Date) { now = start }

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        pending.append((now.addingTimeInterval(max(delay, 0)), work))
    }

    // Moves time forward, running every wake-up that falls due on the way, oldest first, with `now` at its time.
    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        var runs = 0
        while let next = pending.indices.filter({ pending[$0].at <= target }).min(by: { pending[$0].at < pending[$1].at }) {
            let item = pending.remove(at: next)
            if item.at > now { now = item.at }
            item.work()
            runs += 1
            if runs > 200_000 {
                Issue.record("the watcher kept scheduling wake-ups without end (\(runs) runs in \(seconds) s of manual time)")
                break
            }
        }
        now = target
    }
}

@MainActor private final class FWCount { var value = 0 }

@MainActor private final class FWSettingsBox {
    var settings: Settings
    init(_ settings: Settings) { self.settings = settings }
}

// MARK: the world

@MainActor private struct FWWorld {
    let source = FWSource()
    let clock = FWClock(Date(timeIntervalSinceReferenceDate: 100_000))
    let syncs = FWCount()
    let box: FWSettingsBox
    let watcher: FolderWatcher

    init(folders: [(path: String, reading: Bool)] = [(fwRoot, true), (fwScans, true)]) throws {
        let box = FWSettingsBox(try fwSettings(folders))
        let clock = clock
        let syncs = syncs
        self.box = box
        watcher = FolderWatcher(
            source: source,
            settings: { box.settings },
            now: { clock.now },
            schedule: { delay, work in clock.schedule(delay, work) },
            syncNeeded: { syncs.value += 1 })
    }

    // The person changed settings.json (an untick, a removal, a Start): the file is rewritten, then the watcher told.
    func change(_ folders: [(path: String, reading: Bool)]) throws {
        box.settings = try fwSettings(folders)
        watcher.settingsChanged()
    }

    // A file event at the current manual time. `modified` is an offset from now (negative = in the past).
    func emit(_ name: String, in root: String = fwRoot, modified: TimeInterval? = -60) {
        send(path: "\(root)/\(name)", on: root, modified: modified)
    }

    func send(path: String, on root: String, modified: TimeInterval? = -60) {
        source.emit(on: root, ChangeEvent(path: path, modified: modified.map { clock.now.addingTimeInterval($0) }))
    }
}

@Suite("FolderWatcherTests", .serialized)
@MainActor
struct FolderWatcherTests {

    // MARK: which folders are watched

    @Test func creatingTheWatcherStartsNothingAndStartWatchesOnlyTheFoldersThatAreReading() throws {
        let w = try FWWorld(folders: [(fwRoot, true), (fwOld, false), (fwScans, true)])
        #expect(w.source.started.isEmpty, "creating the watcher started streams: \(w.source.started)")
        w.watcher.start()
        #expect(w.source.started.count == 2, "started \(w.source.started)")
        #expect(Set(w.source.started) == [fwRoot, fwScans], "a folder that is not reading was watched, or a reading one was not: \(w.source.started)")
        #expect(w.source.stopped.isEmpty)
        #expect(Set(w.source.live) == [fwRoot, fwScans])
    }

    @Test func noFolderIsReadingSoNothingIsWatched() throws {
        let w = try FWWorld(folders: [(fwRoot, false), (fwScans, false)])
        w.watcher.start()
        #expect(w.source.started.isEmpty, "started \(w.source.started)")
        let empty = try FWWorld(folders: [])
        empty.watcher.start()
        #expect(empty.source.started.isEmpty)
    }

    @Test func settingsThatDidNotChangeStartNoSecondStreamAndStopNone() throws {
        let w = try FWWorld(folders: [(fwRoot, true), (fwOld, false), (fwScans, true)])
        w.watcher.start()
        for _ in 0..<3 { w.watcher.settingsChanged() }
        try w.change([(fwRoot, true), (fwOld, false), (fwScans, true)])
        #expect(w.source.started.count == 2, "started \(w.source.started)")
        #expect(w.source.stopped.isEmpty, "stopped \(w.source.stopped)")
    }

    @Test func unticksAFolderStopsItsStreamAndNoOther() throws {
        let w = try FWWorld()
        w.watcher.start()
        try w.change([(fwRoot, false), (fwScans, true)])
        #expect(w.source.stopped == [fwRoot], "stopped \(w.source.stopped)")
        #expect(w.source.live == [fwScans], "live \(w.source.live)")
        #expect(w.source.started.count == 2, "a stream was started again: \(w.source.started)")
        #expect(w.source.doubleStops.isEmpty)
    }

    @Test func removingAFolderFromTheListStopsItsStream() throws {
        let w = try FWWorld()
        w.watcher.start()
        try w.change([(fwScans, true)])
        #expect(w.source.stopped == [fwRoot], "stopped \(w.source.stopped)")
        #expect(w.source.live == [fwScans])
        try w.change([])
        #expect(Set(w.source.stopped) == [fwRoot, fwScans], "stopped \(w.source.stopped)")
        #expect(w.source.live.isEmpty)
        #expect(w.source.doubleStops.isEmpty, "a stream was stopped twice: \(w.source.doubleStops)")
    }

    @Test func aFolderThatBecomesReadingGetsAStreamOnce() throws {
        // Start indexing: the folders that were ticked get `reading` true in settings.json.
        let w = try FWWorld(folders: [(fwRoot, false), (fwScans, false)])
        w.watcher.start()
        #expect(w.source.started.isEmpty)
        try w.change([(fwRoot, true), (fwScans, false)])
        #expect(w.source.started == [fwRoot], "started \(w.source.started)")
        w.watcher.settingsChanged()
        w.watcher.settingsChanged()
        try w.change([(fwRoot, true), (fwScans, true)])
        #expect(w.source.started == [fwRoot, fwScans], "started \(w.source.started)")
        #expect(w.source.stopped.isEmpty)
    }

    @Test func aFolderAddedToTheListAndReadingIsWatchedAndOneStillWaitingForStartIsNot() throws {
        let w = try FWWorld(folders: [(fwRoot, true)])
        w.watcher.start()
        try w.change([(fwRoot, true), (fwScans, false), (fwOld, true)])
        #expect(w.source.started == [fwRoot, fwOld], "started \(w.source.started)")
        #expect(Set(w.source.live) == [fwRoot, fwOld])
    }

    @Test func aFolderUntickedAndTickedAgainGetsAFreshStreamThatWorks() throws {
        let w = try FWWorld()
        w.watcher.start()
        try w.change([(fwRoot, false), (fwScans, true)])
        try w.change([(fwRoot, true), (fwScans, true)])
        #expect(w.source.started == [fwRoot, fwScans, fwRoot], "started \(w.source.started)")
        #expect(w.source.stopped == [fwRoot])
        w.emit("a.jpg")
        w.clock.advance(by: 2.001)
        #expect(w.syncs.value == 1, "the new stream's event made \(w.syncs.value) requests")
    }

    // MARK: stop

    @Test func stopStopsEveryStreamOnceAndDropsAPendingRequest() throws {
        let w = try FWWorld()
        w.watcher.start()
        w.emit("a.jpg")
        w.watcher.stop()
        w.watcher.stop()
        #expect(Set(w.source.stopped) == [fwRoot, fwScans] && w.source.stopped.count == 2, "stopped \(w.source.stopped)")
        #expect(w.source.doubleStops.isEmpty, "a stream was stopped twice: \(w.source.doubleStops)")
        w.clock.advance(by: 30)
        #expect(w.syncs.value == 0, "a request was made after stop(): \(w.syncs.value)")
        w.source.emitFromStopped(on: fwRoot, ChangeEvent(path: "\(fwRoot)/late.jpg", modified: nil))
        w.clock.advance(by: 30)
        #expect(w.syncs.value == 0, "an event after stop() made a request")
    }

    // MARK: events and the debounce, through the watcher

    @Test func anEventMakesOneSyncRequestTwoSecondsLaterAndNotBefore() throws {
        let w = try FWWorld()
        w.watcher.start()
        w.emit("a.jpg")
        #expect(w.syncs.value == 0, "a request came with the event itself")
        w.clock.advance(by: 1.999)
        #expect(w.syncs.value == 0, "a request after 1.999 s, before the 2 s were over")
        w.clock.advance(by: 0.002)
        #expect(w.syncs.value == 1, "no request 2 s after the event")
        w.clock.advance(by: 120)
        #expect(w.syncs.value == 1, "the one event made \(w.syncs.value) requests")
    }

    @Test func aThousandEventsInsideTwoSecondsMakeOneRequest() throws {
        let w = try FWWorld()
        w.watcher.start()
        for i in 0..<1000 {
            w.clock.advance(by: 0.0019)                    // 1.9 s in all
            w.emit("img-\(i).jpg", in: i % 2 == 0 ? fwRoot : fwScans)
        }
        #expect(w.syncs.value == 0, "\(w.syncs.value) requests came while the events were still arriving")
        w.clock.advance(by: 1.998)
        #expect(w.syncs.value == 0, "a request before 2 s of quiet")
        w.clock.advance(by: 0.003)
        #expect(w.syncs.value == 1, "1,000 events made \(w.syncs.value) requests, expected 1")
        w.clock.advance(by: 120)
        #expect(w.syncs.value == 1, "1,000 events made \(w.syncs.value) requests, expected 1")
    }

    @Test func aNewEventRestartsTheWait() throws {
        let w = try FWWorld()
        w.watcher.start()
        w.emit("a.jpg")
        w.clock.advance(by: 1.5)
        w.emit("b.jpg")
        w.clock.advance(by: 0.501)                         // 2.001 s after the first event
        #expect(w.syncs.value == 0, "the first event's 2 s ended it, the second event did not restart the wait")
        w.clock.advance(by: 1.497)                         // 1.998 s after the second
        #expect(w.syncs.value == 0, "a request before 2 s after the second event")
        w.clock.advance(by: 0.004)                         // 2.002 s after the second
        #expect(w.syncs.value == 1, "no request 2 s after the second event")
    }

    @Test func aFileModifiedUnderTwoSecondsBeforeTheDecisionWaitsUntilItsModifiedTimePlusTwo() throws {
        let w = try FWWorld()
        w.watcher.start()
        // plan-2 fix round A, A4 (re-sealed by that round's tester): a modified time later than the event's arrival counts as
        // the arrival, so this file (1.5 s after the event) is due 2 s after the event, not 3.5 s (the old value pinned
        // finding A4(a): a modified time years ahead held the request for years).
        w.emit("a.jpg", modified: 1.5)                     // modified 1.5 s after the event arrived
        w.clock.advance(by: 1.999)
        #expect(w.syncs.value == 0, "a request before 2 s after the event")
        w.clock.advance(by: 0.002)
        #expect(w.syncs.value == 1, "no request 2 s after the event: a modified time after the event's arrival counts as the arrival")
    }

    @Test func aFileThatIsGoneHasNoModifiedTimeAndTheRequestIsDueTwoSecondsAfterTheEvent() throws {
        let w = try FWWorld()
        w.watcher.start()
        w.emit("gone.jpg", modified: nil)
        w.clock.advance(by: 1.999)
        #expect(w.syncs.value == 0)
        w.clock.advance(by: 0.002)
        #expect(w.syncs.value == 1)
    }

    @Test func twoBurstsMoreThanTwoSecondsApartMakeTwoRequests() throws {
        let w = try FWWorld()
        w.watcher.start()
        w.emit("a.jpg")
        w.emit("b.jpg", in: fwScans)
        w.clock.advance(by: 2.5)
        #expect(w.syncs.value == 1, "first burst made \(w.syncs.value)")
        w.clock.advance(by: 30)
        w.emit("c.jpg")
        w.clock.advance(by: 1.9)
        #expect(w.syncs.value == 1)
        w.clock.advance(by: 0.2)
        #expect(w.syncs.value == 2, "second burst: \(w.syncs.value) requests in all, expected 2")
        w.clock.advance(by: 300)
        #expect(w.syncs.value == 2)
    }

    @Test func anEventOutsideTheWatchedFoldersMakesNoRequest() throws {
        let w = try FWWorld()
        w.watcher.start()
        w.send(path: "/w/other/a.jpg", on: fwRoot)
        w.send(path: "/w/photosX/a.jpg", on: fwRoot)
        w.send(path: "/w", on: fwScans)
        w.clock.advance(by: 120)
        #expect(w.syncs.value == 0, "an event for an unwatched folder made \(w.syncs.value) requests")
        w.emit("a.jpg")
        w.clock.advance(by: 2.001)
        #expect(w.syncs.value == 1, "a real event after the strays")
    }

    // MARK: untick or remove: late events are ignored

    @Test func aLateEventFromAStreamStoppedByAnUntickMakesNoRequest() throws {
        let w = try FWWorld()
        w.watcher.start()
        try w.change([(fwRoot, false), (fwScans, true)])
        w.source.emitFromStopped(on: fwRoot, ChangeEvent(path: "\(fwRoot)/a.jpg", modified: nil))
        w.clock.advance(by: 120)
        #expect(w.syncs.value == 0, "an event of an unticked folder made \(w.syncs.value) requests")
        w.emit("b.jpg", in: fwScans)
        w.clock.advance(by: 2.001)
        #expect(w.syncs.value == 1, "the folder still ticked stopped working")
    }

    @Test func aLateEventFromARemovedFolderMakesNoRequest() throws {
        let w = try FWWorld()
        w.watcher.start()
        try w.change([(fwScans, true)])
        w.source.emitFromStopped(on: fwRoot, ChangeEvent(path: "\(fwRoot)/a.jpg", modified: w.clock.now))
        w.clock.advance(by: 120)
        #expect(w.syncs.value == 0, "an event of a removed folder made \(w.syncs.value) requests")
    }

    @Test func eventsOfTwoFoldersInOneBurstMakeOneRequest() throws {
        let w = try FWWorld()
        w.watcher.start()
        w.emit("a.jpg", in: fwRoot)
        w.clock.advance(by: 0.7)
        w.emit("b.pdf", in: fwScans)
        w.clock.advance(by: 0.7)
        w.emit("c.jpg", in: fwRoot)
        w.clock.advance(by: 5)
        #expect(w.syncs.value == 1, "one burst over two folders made \(w.syncs.value) requests")
    }
}

// MARK: the real system file events (headless, a temp folder under TMPDIR, the real clock)

private func fwTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-folderwatcher-test-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // The system file events report real paths (/private/var/...), and `resolvingSymlinksInPath()` turns that back into
    // /var/..., so the real path comes from realpath(3). A watched root is a real folder path (a symlinked root is not
    // part of this test).
    guard let resolved = realpath(url.path, nil) else { return url }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

@MainActor private final class FWEventLog {
    private(set) var events: [ChangeEvent] = []
    func add(_ event: ChangeEvent) { events.append(event) }
    func events(for path: String) -> [ChangeEvent] { events.filter { $0.path == path } }
}

private func fwWrite(_ url: URL, _ text: String = "hello") throws {
    try Data(text.utf8).write(to: url)
}

private func fwAppend(_ url: URL, _ text: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

// The real clock for the watcher: run `work` on the main actor after `delay` seconds.
@MainActor private func fwRealSchedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
        work()
    }
}

extension FolderWatcherTests {

    // The source alone: create, rename, edit and delete each arrive as events carrying the path and the modified time.
    @Test func theRealSourceDeliversCreateRenameEditAndDeleteWithPathAndModifiedTime() async throws {
        let root = try fwTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let keep = root.appendingPathComponent("keep.txt")
        let old = root.appendingPathComponent("old.txt")
        let gone = root.appendingPathComponent("gone.txt")
        for url in [keep, old, gone] { try fwWrite(url) }

        let log = FWEventLog()
        let source = FSEventsChangeSource()
        let stop = source.watch(path: root.path, onEvent: { log.add($0) })
        defer { stop() }
        await spWait(2)                                    // the setup's own events, if any, come and go

        // create, in a subfolder too
        let created = root.appendingPathComponent("new.txt")
        let nested = sub.appendingPathComponent("nested.txt")
        try fwWrite(created)
        try fwWrite(nested)
        let sawCreate = await spEventually(timeout: 15) {
            log.events(for: created.path).contains { $0.modified != nil } && log.events(for: nested.path).contains { $0.modified != nil }
        }
        #expect(sawCreate, "no create event with a modified time for new.txt and sub/nested.txt; events \(log.events.map(\.path))")
        if let modified = log.events(for: created.path).compactMap(\.modified).last {
            #expect(abs(modified.timeIntervalSinceNow) < 120, "new.txt was just made, its modified time is \(modified)")
        }

        // rename: the old name is gone (no modified time), the new name is there
        let renamed = root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: old, to: renamed)
        let sawRename = await spEventually(timeout: 15) {
            log.events(for: old.path).contains { $0.modified == nil } && log.events(for: renamed.path).contains { $0.modified != nil }
        }
        #expect(sawRename, "no rename events (old name with no modified time, new name with one); events \(log.events.map { "\($0.path) \($0.modified == nil ? "gone" : "there")" })")

        // edit
        let before = log.events(for: keep.path).count
        try fwAppend(keep, " and more")
        let sawEdit = await spEventually(timeout: 15) { log.events(for: keep.path).count > before }
        #expect(sawEdit, "no event for the edit of keep.txt; events \(log.events.map(\.path))")
        if let modified = log.events(for: keep.path).compactMap(\.modified).last {
            #expect(abs(modified.timeIntervalSinceNow) < 120, "keep.txt was just edited, its modified time is \(modified)")
        }

        // delete
        try FileManager.default.removeItem(at: gone)
        let sawDelete = await spEventually(timeout: 15) { log.events(for: gone.path).contains { $0.modified == nil } }
        #expect(sawDelete, "no delete event with no modified time for gone.txt; events \(log.events.map { "\($0.path) \($0.modified == nil ? "gone" : "there")" })")
    }

    // The source's stop closure ends delivery.
    @Test func aStoppedRealStreamDeliversNothingMore() async throws {
        let root = try fwTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = FWEventLog()
        let stop = FSEventsChangeSource().watch(path: root.path, onEvent: { log.add($0) })
        await spWait(1.5)
        let first = root.appendingPathComponent("first.txt")
        try fwWrite(first)
        let saw = await spEventually(timeout: 15) { !log.events(for: first.path).isEmpty }
        #expect(saw, "the live stream saw nothing")
        stop()
        await spWait(1.5)
        let count = log.events.count
        try fwWrite(root.appendingPathComponent("second.txt"))
        await spWait(6)
        #expect(log.events.count == count, "events arrived after the stop closure ran: \(log.events.map(\.path))")
    }

    // The whole watcher on the real events: create, rename, edit and delete each make a sync request.
    @Test func createRenameEditAndDeleteOfAFileEachMakeASyncRequest() async throws {
        let root = try fwTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("keep.txt")
        let old = root.appendingPathComponent("old.txt")
        let gone = root.appendingPathComponent("gone.txt")
        for url in [keep, old, gone] { try fwWrite(url) }

        let syncs = FWCount()
        let settings = try fwSettings([(root.path, true)])
        let watcher = FolderWatcher(
            source: FSEventsChangeSource(),
            settings: { settings },
            now: { Date() },
            schedule: { delay, work in fwRealSchedule(delay, work) },
            syncNeeded: { syncs.value += 1 })
        watcher.start()
        defer { watcher.stop() }
        await spWait(6)                                    // the setup's own events and any request from them pass

        let steps: [(String, () throws -> Void)] = [
            ("create", { try fwWrite(root.appendingPathComponent("new.txt")) }),
            ("rename", { try FileManager.default.moveItem(at: old, to: root.appendingPathComponent("renamed.txt")) }),
            ("edit", { try fwAppend(keep, " and more") }),
            ("delete", { try FileManager.default.removeItem(at: gone) }),
        ]
        for (name, act) in steps {
            let before = syncs.value
            try act()
            let made = await spEventually(timeout: 15) { syncs.value > before }
            #expect(made, "\(name): no sync request within 15 s")
            await spWait(4)                                // quiet, so a straggler of this step cannot pass for the next
        }
    }

    // Untick: the real stream stops, so a file change in the folder makes no request.
    @Test func afterAnUntickTheRealWatcherMakesNoRequestForThatFolder() async throws {
        let root = try fwTempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = FWSettingsBox(try fwSettings([(root.path, true)]))
        let syncs = FWCount()
        let watcher = FolderWatcher(
            source: FSEventsChangeSource(),
            settings: { box.settings },
            now: { Date() },
            schedule: { delay, work in fwRealSchedule(delay, work) },
            syncNeeded: { syncs.value += 1 })
        watcher.start()
        defer { watcher.stop() }
        await spWait(2)

        // while it is ticked, a change makes a request
        try fwWrite(root.appendingPathComponent("a.txt"))
        let first = await spEventually(timeout: 15) { syncs.value >= 1 }
        #expect(first, "the ticked folder made no request")
        await spWait(4)

        box.settings = try fwSettings([(root.path, false)])
        watcher.settingsChanged()
        await spWait(1)
        let count = syncs.value
        try fwWrite(root.appendingPathComponent("b.txt"))
        try fwAppend(root.appendingPathComponent("a.txt"), " more")
        await spWait(6)
        #expect(syncs.value == count, "the unticked folder still made \(syncs.value - count) requests")
    }
}
