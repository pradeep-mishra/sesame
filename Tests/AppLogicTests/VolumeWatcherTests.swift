import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t38, tester step: `VolumeWatcher`, which watches for a drive being unplugged and plugged back in and tells the
// helper supervisor that a sync is needed (S7.8), and `WatcherPlan`, the pure decision of when the folder watcher and the
// volume watcher exist. Written from the t38 entry (its Tests paragraph), the t37 tester pins (FolderWatcherTests.swift,
// ChangeDebouncerTests.swift: the `settings`, `now`, `schedule`, `syncNeeded` seams), the t31 pins
// (`HelperSupervisor.syncNeeded()`), spec section "A deleted, moved or renamed file and every file on an unplugged drive
// disappear ... when the drive returns, its files are read again without any press", design sections 3 and 8, and the
// sealed HelperClientTests (`sendFolders()` as the one place the `folders` line is made) only. No product source was read.
// Every count, path and flag below is written by hand from what each test builds.
//
// API SHAPES these tests pin. The entry names `VolumeWatcher`, "a fake mount-event source", "a manual clock",
// `HelperSupervisor.syncNeeded()`, "the app delegate creates ... when indexing is wanted and drops them at Quit and at
// Delete index (a test of the wiring decision, no launch)" and fixes no signatures. If a shape below is wrong, ask for a
// test change rather than guessing. All new names go in `Sources/Sesame/VolumeWatcher.swift`.
//   1. `MountEvent` (new, `Sesame` target):
//        struct MountEvent: Equatable, Sendable {
//            enum Kind: Equatable, Sendable { case mounted, unmounted }
//            var kind: Kind
//            var path: String                  // the volume's mount point, e.g. "/Volumes/Photos"
//        }
//      memberwise init `MountEvent(kind:path:)`.
//   2. `MountEventSource` (new, `Sesame` target), the seam over the system's mount notifications, shaped like `ChangeSource`:
//        @MainActor protocol MountEventSource: AnyObject {
//            func observe(_ onEvent: @escaping @MainActor (MountEvent) -> Void) -> @MainActor () -> Void
//        }
//      `observe` starts delivery to `onEvent`, on the main actor, one call per volume mounted or unmounted, and returns the
//      closure that stops it (called at most once per `observe`).
//   3. `WorkspaceMountSource` (new, `Sesame` target): the real `MountEventSource`, `init()` with no arguments, over the
//      `NSWorkspace` mount and unmount notifications. Only a headless construction is tested here: make it, observe, stop.
//   4. `@MainActor final class VolumeWatcher`:
//        init(source: any MountEventSource,
//             settings: @escaping () -> Settings,       // the app passes `{ (try? SettingsFile().read()) ?? Settings() }`
//             isReadable: @escaping (_ mountPath: String) -> Bool,   // the app passes a real "can the folder be listed" check
//             now: @escaping () -> Date,
//             schedule: @escaping (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void,
//             syncNeeded: @escaping () -> Void)         // the app passes `{ supervisor.syncNeeded() }`
//        func start()   // calls `source.observe` once. Creating the watcher observes nothing.
//        func stop()    // runs the observe-stop closure once (a second stop() does nothing more), drops a pending request,
//                       // and later events call nothing
//      `now` and `schedule` are the only clock, as in FolderWatcher (no Timer, no Date(), no sleep of its own); a wake-up
//      that finds nothing due must leave a later one in place. `settings()` is read afresh at every event (there is no
//      `settingsChanged()`): the folders that count are those whose `reading` is true, with `path` as settings.json holds it.
//   5. The rule. A volume is RELATED when a ticked (reading) folder's root lies at or under the volume's mount path, or the
//      mount path lies at or under a ticked root (a drive mounted inside a ticked folder), compared on path components
//      ("/Volumes/Photos2" is not "/Volumes/Photos"; a trailing slash on either side changes nothing).
//        - A RELATED `.unmounted` event makes one `syncNeeded()` 2 s after the last related event (a new related event
//          restarts the wait, as in ChangeDebouncer). It does not ask `isReadable`: the volume is gone.
//        - A RELATED `.mounted` event does the same, but the request is made only when `isReadable(mountPath)` is true,
//          asked with the event's `path` exactly. It is first asked when the 2 s are over; while it says false the watcher
//          asks again on its own, and once it says true the request is made within 10 s of manual time of that change.
//          A volume that never becomes readable makes no request. Mounting never touches `settings.json`, never sets
//          `startPressed`, and needs no click: the watcher has no write seam at all.
//        - An UNRELATED event (another volume, a volume that holds only unticked folders, no folder at all) causes at most
//          one `syncNeeded()` in all, however many such events come within a burst: the entry says "at most one", so
//          these tests allow 0 or 1 and never more.
//        - Nothing here deletes or reads a file: the only thing that touches the disk is the injected `isReadable`.
//   6. `WatcherPlan` (new, `Sesame` target): the pure wiring decision of the app delegate.
//        struct WatcherPlan: Equatable {
//            var folders: Bool    // the FolderWatcher exists
//            var volumes: Bool    // the VolumeWatcher exists
//            static func decide(settings: Settings, quitting: Bool) -> WatcherPlan
//        }
//      Both exist exactly when indexing is wanted by the person: `startPressed` true, `indexDeleted` false, and not
//      quitting. Both are dropped at Quit (`quitting`) and at Delete index (`indexDeleted` true). A pause is not an input:
//      a paused app keeps watching, because the supervisor remembers the need (t31 pin 6). `decide` writes nothing and the
//      same input gives the same answer. The app delegate applies the plan after every launch, Start, Delete index and Quit.
//      Not pinned: what `decide` says for `startPressed` true with no folder ticked, and the model being whole or not.
// Not pinned, on purpose: the poll interval of an unreadable mount (only the 10 s bound above), `start()` twice, an event
// before `start()`, what `.mounted` and `.unmounted` for the same volume in one burst do beyond making at most one request
// per 2 s of quiet, and which of the system's will-unmount and did-unmount the real source forwards.
//
// SUITES. No test here launches an app or a helper of the real product. The manual-clock tests are synchronous. One
// suite sets HOME (process-wide, as the other Setup and Settings suites do), so it is nested inside `ModelDownloadTests`
// and runs one at a time with the other HOME suites; side effect: `swift test --filter ModelDownloadTests` also runs it.
// It starts a stub helper (a shell script that records the lines it is sent) through the real `HelperClient`.

private let vwPhotos = "/Volumes/Photos/Pictures"      // on the volume /Volumes/Photos
private let vwScans = "/Volumes/Backup/Scans"          // on the volume /Volumes/Backup
private let vwOld = "/Volumes/Old/Stuff"               // on the volume /Volumes/Old, not ticked
private let vwHome = "/Users/test/Pictures"            // an internal folder

private let vwDefaultFolders: [(path: String, reading: Bool)] = [
    (vwPhotos, true), (vwScans, true), (vwOld, false), (vwHome, true),
]

// MARK: building `Settings`

private func vwSettings(_ folders: [(path: String, reading: Bool)], startPressed: Bool = true) throws -> Settings {
    let entries = folders.map { "{\"path\": \"\($0.path)\", \"code\": false, \"reading\": \($0.reading)}" }.joined(separator: ", ")
    let json = """
    {
      "version": 3,
      "startPressed": \(startPressed),
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

@MainActor private final class VWSource: MountEventSource {
    private struct Observation {
        let onEvent: @MainActor (MountEvent) -> Void
        var stops = 0
    }

    private var observations: [Observation] = []
    var observeCalls: Int { observations.count }
    var stopCalls: Int { observations.reduce(0) { $0 + $1.stops } }
    var live: Int { observations.filter { $0.stops == 0 }.count }

    func observe(_ onEvent: @escaping @MainActor (MountEvent) -> Void) -> @MainActor () -> Void {
        let index = observations.count
        observations.append(Observation(onEvent: onEvent))
        return { [self] in observations[index].stops += 1 }
    }

    func emit(_ kind: MountEvent.Kind, _ path: String) {
        guard let observation = observations.last(where: { $0.stops == 0 }) else {
            Issue.record("the test emitted \(kind) \(path) but nothing observes the source")
            return
        }
        observation.onEvent(MountEvent(kind: kind, path: path))
    }

    // A delivery that raced with the stop.
    func emitAfterStop(_ kind: MountEvent.Kind, _ path: String) {
        guard let observation = observations.last(where: { $0.stops > 0 }) else {
            Issue.record("the test emitted after a stop but no observation was stopped")
            return
        }
        observation.onEvent(MountEvent(kind: kind, path: path))
    }
}

// MARK: the manual clock

@MainActor private final class VWClock {
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

@MainActor private final class VWCount { var value = 0 }

@MainActor private final class VWSettingsBox {
    var settings: Settings
    init(_ settings: Settings) { self.settings = settings }
}

// What the readability seam was asked, and what it answers.
@MainActor private final class VWReadable {
    var answer = true
    private(set) var asked: [String] = []
    func check(_ path: String) -> Bool {
        asked.append(path)
        return answer
    }
}

// MARK: the world

@MainActor private struct VWWorld {
    let source = VWSource()
    let clock = VWClock(Date(timeIntervalSinceReferenceDate: 100_000))
    let syncs = VWCount()
    let readable = VWReadable()
    let box: VWSettingsBox
    let watcher: VolumeWatcher

    init(folders: [(path: String, reading: Bool)] = vwDefaultFolders, readable startReadable: Bool = true, started: Bool = true) throws {
        let box = VWSettingsBox(try vwSettings(folders))
        let clock = clock
        let syncs = syncs
        let readable = readable
        readable.answer = startReadable
        self.box = box
        watcher = VolumeWatcher(
            source: source,
            settings: { box.settings },
            isReadable: { readable.check($0) },
            now: { clock.now },
            schedule: { delay, work in clock.schedule(delay, work) },
            syncNeeded: { syncs.value += 1 })
        if started { watcher.start() }
    }

    func unmount(_ path: String) { source.emit(.unmounted, path) }
    func mount(_ path: String) { source.emit(.mounted, path) }
}

// Volumes that hold a ticked folder, as (name, mount path). Each is related by the rule.
private let vwRelatedVolumes: [(String, String)] = [
    ("the volume that holds a ticked root", "/Volumes/Photos"),
    ("the same volume written with a trailing slash", "/Volumes/Photos/"),
    ("the second ticked root's volume", "/Volumes/Backup"),
    ("a mount point that is the ticked root itself", vwPhotos),
    ("a mount point under a ticked root", "\(vwPhotos)/2024"),
    ("a drive mounted inside a ticked folder", "\(vwHome)/External"),
    ("a mount point that is the internal ticked folder", vwHome),
]

// Volumes that hold no ticked folder.
private let vwUnrelatedVolumes: [(String, String)] = [
    ("another volume", "/Volumes/Other"),
    ("a volume whose name only starts like a ticked one", "/Volumes/Photos2"),
    ("a volume whose root is not ticked", "/Volumes/Old"),
    ("a folder next to a ticked root", "/Volumes/Photos/Movies"),
    ("an internal folder next to a ticked one", "/Users/test/PicturesX"),
]

@Suite("VolumeWatcherTests", .serialized)
@MainActor
struct VolumeWatcherTests {

    // MARK: start and stop

    @Test func creatingTheWatcherObservesNothingAndStartObservesOnce() throws {
        let w = try VWWorld(started: false)
        #expect(w.source.observeCalls == 0, "creating the watcher began observing")
        w.watcher.start()
        #expect(w.source.observeCalls == 1, "start() observed \(w.source.observeCalls) times")
        #expect(w.source.stopCalls == 0)
        #expect(w.syncs.value == 0, "starting made a sync request")
    }

    @Test func stopStopsObservingOnceAndDropsAPendingRequestAndLaterEvents() throws {
        let w = try VWWorld()
        w.unmount("/Volumes/Photos")
        w.watcher.stop()
        w.watcher.stop()
        #expect(w.source.stopCalls == 1, "the observation was stopped \(w.source.stopCalls) times")
        #expect(w.source.live == 0)
        w.clock.advance(by: 60)
        #expect(w.syncs.value == 0, "a request was made after stop(): \(w.syncs.value)")
        w.source.emitAfterStop(.unmounted, "/Volumes/Photos")
        w.source.emitAfterStop(.mounted, "/Volumes/Backup")
        w.clock.advance(by: 60)
        #expect(w.syncs.value == 0, "an event after stop() made a request")
    }

    @Test func aMountPendingOnAnUnreadableVolumeDoesNotRequestAfterStop() throws {
        let w = try VWWorld(readable: false)
        w.mount("/Volumes/Photos")
        w.clock.advance(by: 5)
        w.watcher.stop()
        w.readable.answer = true
        w.clock.advance(by: 60)
        #expect(w.syncs.value == 0, "a stopped watcher made \(w.syncs.value) requests once the volume became readable")
    }

    // MARK: an unplugged drive

    @Test func anUnmountOfAVolumeWithATickedFolderMakesOneRequestTwoSecondsLaterAndNotBefore() throws {
        for (name, path) in vwRelatedVolumes {
            let w = try VWWorld()
            w.unmount(path)
            #expect(w.syncs.value == 0, "\(name): a request came with the event itself")
            w.clock.advance(by: 1.999)
            #expect(w.syncs.value == 0, "\(name): a request after 1.999 s, before the 2 s were over")
            w.clock.advance(by: 0.002)
            #expect(w.syncs.value == 1, "\(name): no request 2 s after the unmount")
            w.clock.advance(by: 300)
            #expect(w.syncs.value == 1, "\(name): the one unmount made \(w.syncs.value) requests")
        }
    }

    @Test func anUnmountNeverAsksWhetherTheVolumeIsReadable() throws {
        let w = try VWWorld(readable: false)
        w.unmount("/Volumes/Photos")
        w.clock.advance(by: 120)
        #expect(w.syncs.value == 1, "an unmount made \(w.syncs.value) requests; the volume being unreadable is the point")
        #expect(w.readable.asked.isEmpty, "an unmount asked about readability: \(w.readable.asked)")
    }

    @Test func aRootWrittenWithATrailingSlashInSettingsStillMatches() throws {
        let w = try VWWorld(folders: [("/Volumes/Photos/Pictures/", true)])
        w.unmount("/Volumes/Photos")
        w.clock.advance(by: 2.001)
        #expect(w.syncs.value == 1, "made \(w.syncs.value) requests")
    }

    @Test func twoUnmountsInOneBurstMakeOneRequestAndANewEventRestartsTheWait() throws {
        let w = try VWWorld()
        w.unmount("/Volumes/Photos")
        w.clock.advance(by: 1.5)
        w.unmount("/Volumes/Backup")
        w.clock.advance(by: 0.501)                         // 2.001 s after the first
        #expect(w.syncs.value == 0, "the first event's 2 s ended it, the second did not restart the wait")
        w.clock.advance(by: 1.497)                         // 1.998 s after the second
        #expect(w.syncs.value == 0, "a request before 2 s after the second event")
        w.clock.advance(by: 0.004)
        #expect(w.syncs.value == 1, "no request 2 s after the second event")
        w.clock.advance(by: 300)
        #expect(w.syncs.value == 1, "one burst made \(w.syncs.value) requests")
    }

    @Test func aDriveThatFlapsManyTimesInsideTwoSecondsMakesOneRequest() throws {
        let w = try VWWorld()
        for i in 0..<100 {
            w.clock.advance(by: 0.0199)                    // 1.99 s in all
            if i % 2 == 0 { w.unmount("/Volumes/Photos") } else { w.mount("/Volumes/Photos") }
        }
        #expect(w.syncs.value == 0, "\(w.syncs.value) requests came while the drive was still flapping")
        w.clock.advance(by: 300)
        #expect(w.syncs.value == 1, "100 events made \(w.syncs.value) requests, expected 1")
    }

    @Test func twoUnplugsMoreThanTwoSecondsApartMakeTwoRequests() throws {
        let w = try VWWorld()
        w.unmount("/Volumes/Photos")
        w.clock.advance(by: 2.5)
        #expect(w.syncs.value == 1, "first unplug made \(w.syncs.value)")
        w.clock.advance(by: 30)
        w.unmount("/Volumes/Backup")
        w.clock.advance(by: 1.9)
        #expect(w.syncs.value == 1)
        w.clock.advance(by: 0.2)
        #expect(w.syncs.value == 2, "second unplug: \(w.syncs.value) requests in all, expected 2")
        w.clock.advance(by: 300)
        #expect(w.syncs.value == 2)
    }

    // MARK: the drive comes back

    @Test func aMountOfAReadableVolumeWithATickedFolderMakesOneRequestTwoSecondsLaterWithoutAClick() throws {
        for (name, path) in vwRelatedVolumes {
            let w = try VWWorld()
            w.mount(path)
            #expect(w.syncs.value == 0, "\(name): a request came with the event itself")
            w.clock.advance(by: 1.999)
            #expect(w.syncs.value == 0, "\(name): a request after 1.999 s, before the 2 s were over")
            w.clock.advance(by: 0.002)
            #expect(w.syncs.value == 1, "\(name): no request 2 s after the mount")
            w.clock.advance(by: 300)
            #expect(w.syncs.value == 1, "\(name): the one mount made \(w.syncs.value) requests")
            #expect(!w.readable.asked.isEmpty, "\(name): the volume was never asked whether it is readable")
            #expect(Set(w.readable.asked) == [path], "\(name): readability was asked about \(w.readable.asked), expected only the mount path")
        }
    }

    @Test func aMountWaitsUntilTheVolumeIsReadableAndThenMakesExactlyOneRequest() throws {
        let w = try VWWorld(readable: false)
        w.mount("/Volumes/Photos")
        w.clock.advance(by: 60)
        #expect(w.syncs.value == 0, "a request was made while the volume was not readable")
        w.readable.answer = true
        w.clock.advance(by: 10)
        #expect(w.syncs.value == 1, "the volume became readable and \(w.syncs.value) requests followed within 10 s, expected 1")
        w.clock.advance(by: 600)
        #expect(w.syncs.value == 1, "one mount made \(w.syncs.value) requests")
    }

    @Test func aVolumeThatIsNeverReadableMakesNoRequestAndANewUnplugStillDoes() throws {
        let w = try VWWorld(readable: false)
        w.mount("/Volumes/Photos")
        w.clock.advance(by: 600)
        #expect(w.syncs.value == 0, "a volume that never became readable made \(w.syncs.value) requests")
        w.unmount("/Volumes/Photos")
        w.clock.advance(by: 2.001)
        #expect(w.syncs.value == 1, "the unplug after a never-readable mount made \(w.syncs.value) requests in all, expected 1")
    }

    @Test func aMountThenAnUnplugAndANewMountEachGetTheirOwnRequest() throws {
        // S7.8: the drive goes, its rows are removed; the drive returns, its files are read again.
        let w = try VWWorld()
        w.unmount("/Volumes/Photos")
        w.clock.advance(by: 30)
        #expect(w.syncs.value == 1, "the unplug made \(w.syncs.value)")
        w.mount("/Volumes/Photos")
        w.clock.advance(by: 30)
        #expect(w.syncs.value == 2, "the return made \(w.syncs.value) requests in all, expected 2")
    }

    // MARK: settings are read at the event, and only reading folders count

    @Test func aFolderThatIsTickedAndReadingAfterStartIsHonouredWithoutAnyNotice() throws {
        let w = try VWWorld(folders: [(vwHome, true)])
        w.unmount("/Volumes/Photos")
        w.clock.advance(by: 120)
        let before = w.syncs.value
        #expect(before <= 1, "an unrelated unmount made \(before) requests")
        // Start indexing / a folder is added: settings.json now holds the photo folder with `reading` true.
        w.box.settings = try vwSettings([(vwHome, true), (vwPhotos, true)])
        w.unmount("/Volumes/Photos")
        w.clock.advance(by: 2.001)
        #expect(w.syncs.value == before + 1, "after the folder was added, an unplug made \(w.syncs.value - before) requests, expected 1")
    }

    @Test func aVolumeThatHoldsOnlyAFolderThatIsNotReadingCausesAtMostOneRequest() throws {
        let w = try VWWorld(folders: [(vwOld, false), (vwHome, true)])
        w.unmount("/Volumes/Old")
        w.clock.advance(by: 120)
        w.mount("/Volumes/Old")
        w.clock.advance(by: 120)
        #expect(w.syncs.value <= 1, "events of a volume with no reading folder made \(w.syncs.value) requests, at most 1 allowed")
    }

    // MARK: unrelated volumes

    @Test func aMountOrUnmountOfAnUnrelatedVolumeCausesAtMostOneRequest() throws {
        for (name, path) in vwUnrelatedVolumes {
            let unplug = try VWWorld()
            unplug.unmount(path)
            unplug.clock.advance(by: 300)
            #expect(unplug.syncs.value <= 1, "\(name): an unmount made \(unplug.syncs.value) requests, at most 1 allowed")

            let plug = try VWWorld()
            plug.mount(path)
            plug.clock.advance(by: 300)
            #expect(plug.syncs.value <= 1, "\(name): a mount made \(plug.syncs.value) requests, at most 1 allowed")
        }
    }

    @Test func aBurstOfUnrelatedEventsCausesAtMostOneRequestInAll() throws {
        let w = try VWWorld()
        for i in 0..<40 {
            let path = vwUnrelatedVolumes[i % vwUnrelatedVolumes.count].1
            if i % 2 == 0 { w.unmount(path) } else { w.mount(path) }
            w.clock.advance(by: 0.05)
        }
        w.clock.advance(by: 300)
        #expect(w.syncs.value <= 1, "40 unrelated events made \(w.syncs.value) requests, at most 1 allowed")
    }

    @Test func noTickedFolderMeansAtMostOneRequestWhateverHappens() throws {
        let w = try VWWorld(folders: [])
        w.unmount("/Volumes/Photos")
        w.mount("/Volumes/Photos")
        w.unmount("/Volumes/Backup")
        w.clock.advance(by: 300)
        #expect(w.syncs.value <= 1, "with nothing ticked the events made \(w.syncs.value) requests, at most 1 allowed")
    }

    // MARK: nothing here deletes or reads a file

    private struct Snapshot: Equatable {
        var entries: [String]
    }

    private static func snapshot(_ root: URL) throws -> Snapshot {
        let fm = FileManager.default
        var entries: [String] = []
        let urls = try fm.subpathsOfDirectory(atPath: root.path).sorted()
        for relative in urls + [""] {
            let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            let bytes = isDir.boolValue ? "" : (try Data(contentsOf: url)).base64EncodedString()
            entries.append("\(relative)|\(attrs[.size] ?? "")|\(modified)|\(bytes)")
        }
        return Snapshot(entries: entries)
    }

    @Test func plugAndUnplugOverARealFolderDeletesCreatesAndChangesNothingInIt() throws {
        let fm = FileManager.default
        let volume = fm.temporaryDirectory.appendingPathComponent("sesame-volumewatcher-test-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: volume) }
        let root = volume.appendingPathComponent("Pictures", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: root.appendingPathComponent("a.jpg"))
        try Data("two two".utf8).write(to: root.appendingPathComponent("sub/b.pdf"))
        try Data("three".utf8).write(to: volume.appendingPathComponent("notes.txt"))
        let before = try Self.snapshot(volume)

        let w = try VWWorld(folders: [(root.path, true)], readable: true, started: false)
        // The readability seam of this test is a real check; the watcher itself is given a path and nothing else.
        let syncs = VWCount()
        let clock = w.clock
        let box = VWSettingsBox(try vwSettings([(root.path, true)]))
        let watcher = VolumeWatcher(
            source: w.source,
            settings: { box.settings },
            isReadable: { fm.isReadableFile(atPath: $0) },
            now: { clock.now },
            schedule: { delay, work in clock.schedule(delay, work) },
            syncNeeded: { syncs.value += 1 })
        watcher.start()
        for _ in 0..<3 {
            w.source.emit(.unmounted, volume.path)
            clock.advance(by: 5)
            w.source.emit(.mounted, volume.path)
            clock.advance(by: 5)
        }
        #expect(syncs.value >= 1, "the real folder's plug and unplug made no request")
        #expect(try Self.snapshot(volume) == before, "a file or folder under the volume was created, deleted, changed or touched")
        watcher.stop()
    }

    // MARK: the real mount source, headless

    @Test func theRealMountSourceBuildsObservesAndStopsHeadless() async throws {
        let source = WorkspaceMountSource()
        let stop = source.observe { _ in }
        try? await Task.sleep(nanoseconds: 300_000_000)
        stop()
        // Putting the watcher on top of it: start and stop, nothing ticked, no crash.
        let watcher = VolumeWatcher(
            source: WorkspaceMountSource(),
            settings: { Settings() },
            isReadable: { _ in true },
            now: { Date() },
            schedule: { delay, work in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                    work()
                }
            },
            syncNeeded: {})
        watcher.start()
        watcher.stop()
    }
}

// MARK: the wiring decision: when the watchers exist

@Suite("VolumeWatcherTests wiring")
@MainActor
struct VolumeWatcherWiringTests {

    private func settings(startPressed: Bool, indexDeleted: Bool, ticked: Bool = true) -> Settings {
        var settings = Settings()
        settings.startPressed = startPressed
        settings.indexDeleted = indexDeleted
        settings.folders = ticked ? [Settings.Folder(path: "/Users/test/Pictures", code: false, reading: true)] : []
        return settings
    }

    private struct Row {
        let name: String
        let startPressed: Bool
        let indexDeleted: Bool
        let quitting: Bool
        let exist: Bool
    }

    private static let table: [Row] = [
        Row(name: "a fresh install, nothing pressed", startPressed: false, indexDeleted: false, quitting: false, exist: false),
        Row(name: "Start was pressed (a launch that resumes indexing, or the press itself)", startPressed: true, indexDeleted: false, quitting: false, exist: true),
        Row(name: "Quit while indexing", startPressed: true, indexDeleted: false, quitting: true, exist: false),
        Row(name: "Quit before Start", startPressed: false, indexDeleted: false, quitting: true, exist: false),
        Row(name: "Delete index while Start is still recorded", startPressed: true, indexDeleted: true, quitting: false, exist: false),
        Row(name: "Delete index done, Start cleared", startPressed: false, indexDeleted: true, quitting: false, exist: false),
        Row(name: "Delete index and Quit together", startPressed: true, indexDeleted: true, quitting: true, exist: false),
    ]

    @Test func bothWatchersExistExactlyWhenStartWasPressedTheIndexIsNotDeletedAndTheAppIsNotQuitting() {
        for row in Self.table {
            let plan = WatcherPlan.decide(settings: settings(startPressed: row.startPressed, indexDeleted: row.indexDeleted),
                                          quitting: row.quitting)
            #expect(plan.folders == row.exist, "\(row.name): the folder watcher should \(row.exist ? "exist" : "not exist"); plan \(plan)")
            #expect(plan.volumes == row.exist, "\(row.name): the volume watcher should \(row.exist ? "exist" : "not exist"); plan \(plan)")
        }
    }

    @Test func theDecisionIsPureTheSameInputGivesTheSameAnswerAndTheSettingsAreNotChanged() {
        var input = settings(startPressed: true, indexDeleted: false)
        let first = WatcherPlan.decide(settings: input, quitting: false)
        let second = WatcherPlan.decide(settings: input, quitting: false)
        #expect(first == second)
        #expect(input.startPressed == true && input.indexDeleted == false && input.folders.count == 1,
                "decide changed the settings it was given")
        input.startPressed = false
        let stopped = WatcherPlan.decide(settings: input, quitting: false)
        #expect(stopped != first, "the decision did not follow the settings")
    }

    @Test func aLifeOfTheAppCreatesThenDropsThenCreatesTheWatchers() {
        // launch before Start
        var current = settings(startPressed: false, indexDeleted: false, ticked: false)
        #expect(WatcherPlan.decide(settings: current, quitting: false) == WatcherPlan(folders: false, volumes: false),
                "watchers existed before Start")
        // setup: Start indexing
        current = settings(startPressed: true, indexDeleted: false)
        #expect(WatcherPlan.decide(settings: current, quitting: false) == WatcherPlan(folders: true, volumes: true),
                "no watchers after Start")
        // Delete index
        current.indexDeleted = true
        #expect(WatcherPlan.decide(settings: current, quitting: false) == WatcherPlan(folders: false, volumes: false),
                "watchers survived Delete index")
        // Start again after the delete
        current.indexDeleted = false
        current.startPressed = true
        #expect(WatcherPlan.decide(settings: current, quitting: false) == WatcherPlan(folders: true, volumes: true),
                "no watchers after Start again")
        // Quit
        #expect(WatcherPlan.decide(settings: current, quitting: true) == WatcherPlan(folders: false, volumes: false),
                "watchers survived Quit")
    }
}

// MARK: a mount through the real settings file and the real client: the folders sent, nothing written

private let vwStubScript = #"""
#!/bin/sh
# Stub helper for VolumeWatcherTests. Records its start and every stdin line it is sent.
dir=$(dirname "$0")
echo "$$" >> "$dir/pids"
echo "$1" >> "$dir/starts"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$dir/stdin"
done
"""#

@MainActor
private final class VWStubEnv {
    let dir: URL
    let helper: URL
    let textModel: URL
    let mmModel: URL
    let home: URL
    var settingsFile: URL { home.appendingPathComponent("Library/Application Support/Sesame/settings.json") }

    init(home: URL) throws {
        let fm = FileManager.default
        self.home = home
        dir = fm.temporaryDirectory.appendingPathComponent("sesame-volumewatcher-stub-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        helper = dir.appendingPathComponent("stub-helper")
        try vwStubScript.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        textModel = dir.appendingPathComponent("text-model.gguf")
        mmModel = dir.appendingPathComponent("mm-model.gguf")
        fm.createFile(atPath: textModel.path, contents: Data("t".utf8))
        fm.createFile(atPath: mmModel.path, contents: Data("m".utf8))
    }

    private func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    var lines: [String] { read("stdin").split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
    var foldersLines: [String] { lines.filter { $0.contains("\"folders\"") } }
    var starts: Int { read("starts").split(separator: "\n", omittingEmptySubsequences: true).count }

    func cleanup() {
        for pid in read("pids").split(separator: "\n").compactMap({ Int($0) }) { _ = Darwin.kill(pid_t(pid), SIGKILL) }
        try? FileManager.default.removeItem(at: dir)
    }
}

// The paths of a `folders` line, sorted; nil when the line is not one.
private func vwFolderPaths(_ line: String) -> [String]? {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          obj["cmd"] as? String == "folders", let list = obj["folders"] as? [[String: Any]] else { return nil }
    let paths = list.compactMap { $0["path"] as? String }
    return paths.count == list.count ? paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.sorted() : nil
}

@MainActor
private func vwEventually(timeout: Double = 15, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

extension ModelDownloadTests {
    @Suite("VolumeWatcherTests", .serialized)
    struct VolumeWatcherTests {

        // The drive returns with settings.json holding Start pressed: the app reads the folders again, with no click, and
        // sends only the folders whose `reading` is true; settings.json is not rewritten, `startPressed` is still true.
        @MainActor
        @Test func aReturningDriveSendsTheReadingFoldersOnceAndLeavesSettingsJSONAlone() async throws {
            let fm = FileManager.default
            let home = fm.temporaryDirectory.appendingPathComponent("sesame-volumewatcher-home-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            let previousHome = getenv("HOME").map { String(cString: $0) }
            setenv("HOME", home.path, 1)
            let env = try VWStubEnv(home: home)
            defer {
                env.cleanup()
                if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
                try? fm.removeItem(at: home)
            }
            _ = try SesameFolder.create()
            guard fm.fileExists(atPath: env.settingsFile.deletingLastPathComponent().path) else {
                Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before touching anything")
                return
            }

            let base = home.resolvingSymlinksInPath()
            let pictures = base.appendingPathComponent("Pictures").path
            let scans = base.appendingPathComponent("Scans").path
            let later = base.appendingPathComponent("Added Later").path
            for path in [pictures, scans, later] { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
            let json = try String(data: JSONSerialization.data(withJSONObject: [
                "version": 3, "startPressed": true, "indexDeleted": false,
                "folders": [
                    ["path": pictures, "code": false, "reading": true],
                    ["path": scans, "code": false, "reading": true],
                    ["path": later, "code": false, "reading": false],
                ],
                "codeSearchOn": false,
                "kindsOn": ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true],
                "hotkey": "cmd+opt+k",
                "openWith": ["pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"],
                "speeds": ["photo": 3.0],
                "loginDefaultApplied": true,
            ] as [String: Any], options: [.sortedKeys]), encoding: .utf8) ?? ""
            try json.write(to: env.settingsFile, atomically: true, encoding: .utf8)
            let bytesBefore = try Data(contentsOf: env.settingsFile)
            let modifiedBefore = try fm.attributesOfItem(atPath: env.settingsFile.path)[.modificationDate] as? Date

            let client = HelperClient(helper: env.helper, textModel: env.textModel, mmModel: env.mmModel)
            let source = VWSource()
            let clock = VWClock(Date(timeIntervalSinceReferenceDate: 100_000))
            let watcher = VolumeWatcher(
                source: source,
                settings: { (try? SettingsFile().read()) ?? Settings() },
                isReadable: { fm.isReadableFile(atPath: $0) },
                now: { clock.now },
                schedule: { delay, work in clock.schedule(delay, work) },
                syncNeeded: { client.sendFolders() })
            watcher.start()
            defer { watcher.stop() }

            // the drive comes back: the volume holding the folders is mounted, nobody clicks anything
            source.emit(.mounted, base.path)
            clock.advance(by: 1.999)
            try? await Task.sleep(nanoseconds: 400_000_000)
            #expect(env.foldersLines.isEmpty, "folders were sent before the 2 s debounce: \(env.lines)")
            clock.advance(by: 0.002)
            let sent = await vwEventually { env.foldersLines.count >= 1 }
            #expect(sent, "no folders line reached the helper after the mount; it got \(env.lines)")
            try? await Task.sleep(nanoseconds: 800_000_000)
            #expect(env.foldersLines.count == 1, "one mount sent \(env.foldersLines.count) folders lines: \(env.foldersLines)")
            #expect(env.foldersLines.last.flatMap(vwFolderPaths) == [pictures, scans].sorted(),
                    "the folders sent were \(env.foldersLines.last ?? "none"); expected only the two folders whose reading is true")
            #expect(env.starts == 1, "the helper was started \(env.starts) times")

            // the drive goes again: a second line, the same whole list
            source.emit(.unmounted, base.path)
            clock.advance(by: 2.001)
            let second = await vwEventually { env.foldersLines.count >= 2 }
            #expect(second, "no folders line after the unplug; it got \(env.lines)")
            #expect(env.foldersLines.last.flatMap(vwFolderPaths) == [pictures, scans].sorted(),
                    "the second list was \(env.foldersLines.last ?? "none")")

            // nothing was written: Start is still pressed, the file is the same bytes
            #expect((try? Data(contentsOf: env.settingsFile)) == bytesBefore, "settings.json changed")
            #expect((try? fm.attributesOfItem(atPath: env.settingsFile.path)[.modificationDate] as? Date) == modifiedBefore,
                    "settings.json was rewritten")
            #expect((try? SettingsFile().read())?.startPressed == true, "startPressed is no longer true")
            for line in env.lines {
                #expect(line.contains("\"folders\""), "the watcher caused a line that is not a folders line: \(line)")
            }
        }
    }
}
