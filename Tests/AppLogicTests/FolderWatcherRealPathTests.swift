import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2 fix round A, tester step: item A3 (S7.6, S7.7, S7.15). Written from the fix-round entry A3, the reviewer's finding
// ("the folder watcher drops every event when a ticked folder is spelled through a symlink", measured: a stream on
// /var/folders/.../T/x reports /private/var/folders/.../T/x/new.jpg) and the sealed ChangeDebouncerTests.swift and
// FolderWatcherTests.swift (shapes and the manual clock, own copies below; FolderWatcherTests.swift line 445 says the
// symlinked root "is not part of this test"). The rest of FSEvents' reporting was measured by the reviewer, not here.
// No product source was read beyond FolderWatcher.swift, which the entry names (for the names `ChangeSource`, `watch`).
//
// What the entry fixes (expected values written by hand):
//   - the watched roots are resolved to their real path ONCE (`realpath(3)`; `resolvingSymlinksInPath` maps /private/var
//     back to /var and cannot be used), and that real path is what both the stream (`ChangeSource.watch(path:)`) and the
//     debouncer use; an event path is compared as a real path. The `settings.json` spelling is never changed.
//   - a root that does not exist (an unplugged drive, `/w/photos` in the sealed tests) cannot be resolved by `realpath`:
//     it is resolved as far as it exists (`/var/x` -> `/private/var/x`) and otherwise kept as written. PINNED SHAPE, because
//     the entry's own debouncer test uses a root `/var/x` that does not exist.
// Debouncer tests: root `/var/x`, event `/private/var/x/a.jpg` keeps the event (and the other spelling too); `/private/var/xy/...`
// (a sibling sharing the text) and `/private/var/other/...` are still dropped.
// Watcher tests with the fake `ChangeSource`: a root spelled through a symlink starts its stream on the real path, one stream
// per root however often `settingsChanged()` runs, and an event reported under the real path makes a sync request 2 s later.
// Real tests (real FSEvents, headless, the real clock, a temp folder under TMPDIR, no app, no helper): a root spelled
// `/var/folders/...` and a root that is a symlink each deliver a sync request after a create.
// Red today: every test but the sibling and the existence guards.

private let rpBase = Date(timeIntervalSinceReferenceDate: 100_000)

private func rpAt(_ seconds: Double) -> Date { rpBase.addingTimeInterval(seconds) }

private func rpDue(_ d: ChangeDebouncer) -> Double? { d.dueDate.map { $0.timeIntervalSince(rpBase) } }

private func rpEvent(_ path: String) -> ChangeEvent { ChangeEvent(path: path, modified: rpAt(-60)) }

/// `realpath(3)` of an existing path, nil when it does not exist.
private func rpReal(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A real folder under the person's TMPDIR, spelled the way `FileManager` spells TMPDIR (`/var/folders/...`).
private func rpTempFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sesame-realpath-\(name)-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: building `Settings`

private func rpSettings(_ paths: [String]) throws -> Settings {
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

// MARK: the fake source and the manual clock (as in FolderWatcherTests, own copies)

@MainActor private final class RPSource: ChangeSource {
    private struct Stream {
        let path: String
        let onEvent: @MainActor (ChangeEvent) -> Void
        var stops = 0
    }
    private var streams: [Stream] = []
    private(set) var started: [String] = []
    private(set) var stopped: [String] = []

    func watch(path: String, onEvent: @escaping @MainActor (ChangeEvent) -> Void) -> @MainActor () -> Void {
        let index = streams.count
        streams.append(Stream(path: path, onEvent: onEvent))
        started.append(path)
        return { [self] in
            streams[index].stops += 1
            if streams[index].stops == 1 { stopped.append(path) }
        }
    }

    /// An event on the newest live stream for `path` (the path the stream was started with).
    @discardableResult
    func emit(on path: String, _ event: ChangeEvent) -> Bool {
        guard let stream = streams.last(where: { $0.path == path && $0.stops == 0 }) else { return false }
        stream.onEvent(event)
        return true
    }
}

@MainActor private final class RPClock {
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

@MainActor private final class RPCount { var value = 0 }

@MainActor private struct RPWorld {
    let source = RPSource()
    let clock = RPClock(Date(timeIntervalSinceReferenceDate: 100_000))
    let syncs = RPCount()
    let watcher: FolderWatcher

    init(roots: [String]) throws {
        let settings = try rpSettings(roots)
        let clock = clock, syncs = syncs
        watcher = FolderWatcher(source: source, settings: { settings }, now: { clock.now },
                                schedule: { delay, work in clock.schedule(delay, work) }, syncNeeded: { syncs.value += 1 })
    }
}

// MARK: the debouncer, by hand

@Suite("FolderWatcherRealPathTests", .serialized)
@MainActor
struct FolderWatcherRealPathTests {

    @Test func aRootSpelledThroughVarKeepsAnEventReportedUnderPrivateVar() {
        var d = ChangeDebouncer(roots: ["/var/x"])
        d.record(rpEvent("/private/var/x/a.jpg"), at: rpAt(0))
        #expect(rpDue(d).map { abs($0 - 2) < 0.0005 } == true, "root /var/x, event /private/var/x/a.jpg: due \(String(describing: rpDue(d))), expected 2 s (the event was dropped)")
        var nested = ChangeDebouncer(roots: ["/var/x"])
        nested.record(rpEvent("/private/var/x/sub/deeper/b.png"), at: rpAt(0))
        #expect(rpDue(nested) != nil, "an event in a subfolder of the root, reported under /private/var, was dropped")
        var itself = ChangeDebouncer(roots: ["/var/x"])
        itself.record(rpEvent("/private/var/x"), at: rpAt(0))
        #expect(rpDue(itself) != nil, "an event for the root itself, reported under /private/var, was dropped")
    }

    @Test func aRootWrittenAsThePrivatePathKeepsAnEventSpelledThroughVar() {
        var d = ChangeDebouncer(roots: ["/private/var/x"])
        d.record(rpEvent("/var/x/a.jpg"), at: rpAt(0))
        #expect(rpDue(d).map { abs($0 - 2) < 0.0005 } == true, "root /private/var/x, event /var/x/a.jpg: due \(String(describing: rpDue(d))), expected 2 s (an event path is compared as a real path)")
    }

    @Test func aSiblingThatSharesTheTextAndAnotherFolderAreStillDroppedWhateverTheSpelling() {
        var d = ChangeDebouncer(roots: ["/var/x"])
        for path in ["/private/var/xy/a.jpg", "/private/var/x-old/a.jpg", "/private/var/other/a.jpg", "/private/var/a.jpg", "/private/var",
                     "/var/xy/a.jpg", "/elsewhere/private/var/x/a.jpg"] {
            d.record(rpEvent(path), at: rpAt(0))
        }
        #expect(d.dueDate == nil, "an event outside the root made a request due at \(String(describing: rpDue(d))) s")
    }

    @Test func aRootThatIsASymlinkKeepsEventsReportedUnderTheRealFolderAndUnderItsOwnSpelling() throws {
        let parent = try rpTempFolder("link")
        defer { try? FileManager.default.removeItem(at: parent) }
        let real = parent.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        let realPath = try #require(rpReal(real.path), "setup: no realpath for the real folder")

        var d = ChangeDebouncer(roots: [link.path])
        d.record(rpEvent(realPath + "/a.jpg"), at: rpAt(0))
        #expect(rpDue(d).map { abs($0 - 2) < 0.0005 } == true, "root \(link.path) is a symlink to \(realPath); an event under the real folder: due \(String(describing: rpDue(d))), expected 2 s")
        var spelled = ChangeDebouncer(roots: [link.path])
        spelled.record(rpEvent(link.path + "/b.jpg"), at: rpAt(0))
        #expect(rpDue(spelled) != nil, "an event spelled through the symlink itself was dropped")
        var outside = ChangeDebouncer(roots: [link.path])
        outside.record(rpEvent(realPath + "-other/a.jpg"), at: rpAt(0))
        outside.record(rpEvent(parent.path + "/not-the-link/a.jpg"), at: rpAt(1))
        #expect(outside.dueDate == nil, "an event outside the link's target made a request")
    }

    // MARK: the watcher with the fake source

    @Test func aRootSpelledThroughASymlinkStartsItsStreamOnTheRealPathAndAnEventThereMakesASyncRequest() throws {
        let parent = try rpTempFolder("fake")
        defer { try? FileManager.default.removeItem(at: parent) }
        let real = parent.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        let realPath = try #require(rpReal(real.path), "setup: no realpath for the real folder")

        let w = try RPWorld(roots: [link.path])
        w.watcher.start()
        #expect(w.source.started == [realPath], "the stream was started on \(w.source.started), expected the real path [\(realPath)] (the root is resolved once)")
        for _ in 0..<3 { w.watcher.settingsChanged() }
        #expect(w.source.started == [realPath] && w.source.stopped.isEmpty,
                "settings that did not change made another stream or stopped one: started \(w.source.started), stopped \(w.source.stopped)")
        let delivered = w.source.emit(on: realPath, rpEvent(realPath + "/a.jpg"))
        #expect(delivered, "no live stream on \(realPath) to deliver the event")
        w.clock.advance(by: 1.999)
        #expect(w.syncs.value == 0, "a request before 2 s")
        w.clock.advance(by: 0.002)
        #expect(w.syncs.value == 1, "an event under the real folder of a symlinked root made \(w.syncs.value) requests, expected 1")
    }

    @Test func aRootSpelledThroughVarStartsItsStreamOnThePrivatePathAndAnEventThereMakesASyncRequest() throws {
        let folder = try rpTempFolder("var")
        defer { try? FileManager.default.removeItem(at: folder) }
        let realPath = try #require(rpReal(folder.path), "setup: no realpath")
        guard realPath != folder.path else {
            Issue.record("TMPDIR is already a real path (\(folder.path)), so this test cannot show the /var against /private/var case on this Mac")
            return
        }
        let w = try RPWorld(roots: [folder.path])
        w.watcher.start()
        #expect(w.source.started == [realPath], "the stream was started on \(w.source.started), expected [\(realPath)]")
        w.source.emit(on: realPath, rpEvent(realPath + "/a.jpg"))
        w.clock.advance(by: 2.001)
        #expect(w.syncs.value == 1, "an event reported under /private/var for a root spelled /var made \(w.syncs.value) requests, expected 1")
    }

    @Test func aRootThatDoesNotExistIsKeptAsWrittenAndStillWorks() throws {
        let w = try RPWorld(roots: ["/w/photos"])
        w.watcher.start()
        #expect(w.source.started == ["/w/photos"], "an unplugged or missing root changed spelling: \(w.source.started)")
        w.source.emit(on: "/w/photos", rpEvent("/w/photos/a.jpg"))
        w.clock.advance(by: 2.001)
        #expect(w.syncs.value == 1, "an event of a root that does not exist (yet) made \(w.syncs.value) requests")
    }

    // MARK: real system file events (headless, TMPDIR, the real clock)

    @MainActor private final class Syncs { var value = 0 }

    private func realWatcher(root: String, syncs: Syncs) throws -> FolderWatcher {
        let settings = try rpSettings([root])
        return FolderWatcher(
            source: FSEventsChangeSource(), settings: { settings }, now: { Date() },
            schedule: { delay, work in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                    work()
                }
            },
            syncNeeded: { syncs.value += 1 })
    }

    @Test func aRootSpelledThroughVarDeliversASyncRequestAfterACreate() async throws {
        let folder = try rpTempFolder("real-var")
        defer { try? FileManager.default.removeItem(at: folder) }
        let realPath = try #require(rpReal(folder.path), "setup: no realpath")
        guard realPath != folder.path else {
            Issue.record("TMPDIR is already a real path (\(folder.path)), so this test cannot show the /var against /private/var case on this Mac")
            return
        }
        let syncs = Syncs()
        let watcher = try realWatcher(root: folder.path, syncs: syncs)
        watcher.start()
        defer { watcher.stop() }
        await spWait(2)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("new.txt"))
        let made = await spEventually(timeout: 15) { syncs.value >= 1 }
        #expect(made, "a file created in \(folder.path) (real path \(realPath)) made no sync request within 15 s")
    }

    @Test func aRootThatIsASymlinkDeliversASyncRequestAfterACreate() async throws {
        let parent = try rpTempFolder("real-link")
        defer { try? FileManager.default.removeItem(at: parent) }
        let real = parent.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        let syncs = Syncs()
        let watcher = try realWatcher(root: link.path, syncs: syncs)
        watcher.start()
        defer { watcher.stop() }
        await spWait(2)
        try Data("hello".utf8).write(to: real.appendingPathComponent("new.txt"))
        let made = await spEventually(timeout: 15) { syncs.value >= 1 }
        #expect(made, "a file created in the real folder behind the symlinked root \(link.path) made no sync request within 15 s")
    }
}
