import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t3, tester step (R3 and F13: the panel and the menu read cached state; the main thread never waits on the
// matrix load). Written from the t3 entry, design sections 3 and 8 (the open path does no disk work), plan-1's
// `PanelSnapshot` (names only, read from the compiled module's symbols, no product source) and the t2 controller
// addition (the permission note is drawn as its own line). Every expected value is written here by hand.
//
// NO WINDOW IS SHOWN. The entry says "`Panel.show()` makes zero source calls"; the plan's Conventions forbid a Swift
// test from ordering a window front or making one key. So no test here calls `Panel.show()`. The open path is read
// through the other offscreen entries (attach, a typed key, a `changed` event), each of which draws the panel from the
// cached snapshot; the `show()` reading itself is the accept stage's block E (the entry says so).
//
// SUITE PLACEMENT. The panel tests set HOME (process-wide), so the suite is nested in `ModelDownloadTests` and runs one
// at a time with the others, as FocusStabilityTests does.
//
// API SHAPES these tests pin (the entry gives names, not signatures; if a shape is wrong, ask for a test change):
//   1. `struct StatusSources: Sendable` holds `@Sendable` closures and has the memberwise init
//        `StatusSources(settings: () -> Settings, counts: () -> IndexCounts, meta: (String) -> String?,
//                        modelState: () -> ModelState)`
//      `meta` is the one closure that answers `meta("walk_done_at")` and `meta("vector_source")` (the reader's `meta(_:)`).
//   2. `final class StatusCache` (not tied to the main actor for its reads): `init(sources: StatusSources,
//      queue: DispatchQueue)`; `var onChange: (@Sendable () -> Void)?`; `func snapshot() -> PanelSnapshot`;
//      `func refresh()`; `func helperChanged()`; `func settingsChanged()`; `func panelOpened()`. `refresh()` returns at
//      once (it schedules); every source runs on the given serial queue, never on the main thread.
//   3. `PanelSnapshot` gets `Equatable` (the cache needs it to know "changed"); these tests compare field by field
//      and do not rely on it. The mapping the tests read: `model` from `modelState`; `startPressed`, `indexDeleted`,
//      `kindsOn` = the kinds `settings.kindsOn` has as true; `counts` from `counts`; `walkDone` = `meta("walk_done_at") != nil`.
//      (`vectorSourceOK` is not asserted: the entry does not fix how `meta("vector_source")` becomes it.)
//   4. `Panel.attach(status: StatusCache)` (main actor) gives the panel its cache in place of the one `Panel.init`
//      makes; after it the panel draws from `status.snapshot()` and never calls a source itself. The panel's
//      `HelperEventRelay` sends a `changed` event to `status.helperChanged()`; the relay is the `delegate` of the
//      `HelperClient` given to `attach(helper:)`, as plan 1 wires it. The panel re-draws when the cache's value changes.
//   5. The permission note is drawn on the panel as a visible text of exactly the note, separate from the banner and from
//      "Still ranking", and some view under the panel's content view has an accessibility label containing the note.

// MARK: the queue, the gate and the fake sources

private let scQueueKey = DispatchSpecificKey<String>()
private let scQueueLabel = "sesame.statuscache.test.queue"

private func scMakeQueue() -> DispatchQueue {
    let queue = DispatchQueue(label: scQueueLabel, qos: .utility)
    queue.setSpecific(key: scQueueKey, value: scQueueLabel)
    return queue
}

private func scDrain(_ queue: DispatchQueue) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        queue.async { continuation.resume() }
    }
}

/// A count that any thread may add to and the test reads.
private final class SCCount: @unchecked Sendable {
    private let lock = NSLock()
    private var number = 0
    func add() { lock.lock(); number += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return number }
}

/// Stands in for the matrix load that holds the reader: a source that reaches `pass()` while the gate is armed waits
/// there. A watchdog opens the gate after `seconds` so a call that is stuck behind the gate returns instead of hanging
/// the run, and the test then sees `fired` and fails with a message (the "10 s timeout that fails the test").
private final class SCGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var blocking: Bool
    private var inside = 0
    private var watchdog = false

    init(armed: Bool) { blocking = armed }

    func arm(watchdogSeconds: Double = 10) {
        lock.lock(); blocking = true; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + watchdogSeconds) { [self] in
            lock.lock()
            if blocking { watchdog = true }
            lock.unlock()
            open()
        }
    }

    func pass() {
        lock.lock()
        let wait = blocking
        if wait { inside += 1 }
        lock.unlock()
        if wait { _ = semaphore.wait(timeout: .now() + 60) }   // 60 s is only a backstop for a lost signal
    }

    func open() {
        lock.lock(); blocking = false; lock.unlock()
        for _ in 0..<50 { semaphore.signal() }
    }

    var entered: Bool { lock.lock(); defer { lock.unlock() }; return inside > 0 }
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return watchdog }
}

/// What the fake sources answer (change it between refreshes) and what they were asked.
private final class SCWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var settingsValue: Settings
    private var countsValue: IndexCounts
    private var walkDoneAtValue: String?
    private var vectorSourceValue: String?
    private var modelValue: ModelState
    private var settingsCalls = 0
    private var countsCalls = 0
    private var modelCalls = 0
    private var metaAsked: [String] = []
    private var onMain = 0
    private var offQueue = 0
    let gate: SCGate

    init(settings: Settings = scSettings(), counts: IndexCounts = scCounts(done: 8, pending: 1, needs: 1),
         walkDoneAt: String? = "1700000000", vectorSource: String? = "fake-source", model: ModelState = .whole,
         gate: SCGate = SCGate(armed: false)) {
        settingsValue = settings
        countsValue = counts
        walkDoneAtValue = walkDoneAt
        vectorSourceValue = vectorSource
        modelValue = model
        self.gate = gate
    }

    func set(settings: Settings? = nil, counts: IndexCounts? = nil, walkDoneAt: String?? = nil, model: ModelState? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let settings { settingsValue = settings }
        if let counts { countsValue = counts }
        if let walkDoneAt { walkDoneAtValue = walkDoneAt }
        if let model { modelValue = model }
    }

    // Every source notes where it ran. The gate sits in `counts` after the value is read, so a refresh that is held
    // there holds the value it read before the gate, which is how a matrix load holding the reader looks from outside.
    private func note() {
        lock.lock()
        if Thread.isMainThread { onMain += 1 }
        if DispatchQueue.getSpecific(key: scQueueKey) != scQueueLabel { offQueue += 1 }
        lock.unlock()
    }

    func sources() -> StatusSources {
        StatusSources(
            settings: { [self] in
                note()
                lock.lock(); settingsCalls += 1; let value = settingsValue; lock.unlock()
                return value
            },
            counts: { [self] in
                note()
                lock.lock(); countsCalls += 1; let value = countsValue; lock.unlock()
                gate.pass()
                return value
            },
            meta: { [self] key in
                note()
                lock.lock()
                metaAsked.append(key)
                let value = key == "walk_done_at" ? walkDoneAtValue : (key == "vector_source" ? vectorSourceValue : nil)
                lock.unlock()
                return value
            },
            modelState: { [self] in
                note()
                lock.lock(); modelCalls += 1; let value = modelValue; lock.unlock()
                return value
            })
    }

    var settingsCallCount: Int { lock.lock(); defer { lock.unlock() }; return settingsCalls }
    var countsCallCount: Int { lock.lock(); defer { lock.unlock() }; return countsCalls }
    var modelCallCount: Int { lock.lock(); defer { lock.unlock() }; return modelCalls }
    var metaKeys: [String] { lock.lock(); defer { lock.unlock() }; return metaAsked }
    var mainThreadCalls: Int { lock.lock(); defer { lock.unlock() }; return onMain }
    var callsOffTheGivenQueue: Int { lock.lock(); defer { lock.unlock() }; return offQueue }
    var totalCalls: Int { lock.lock(); defer { lock.unlock() }; return settingsCalls + countsCalls + modelCalls + metaAsked.count }
}

private func scSettings(startPressed: Bool = true, indexDeleted: Bool = false, codeSearchOn: Bool = false,
                        kindsOn: [String: Bool] = ["photo": true], folders: [Settings.Folder]? = nil) -> Settings {
    var settings = Settings()
    settings.startPressed = startPressed
    settings.indexDeleted = indexDeleted
    settings.codeSearchOn = codeSearchOn
    settings.kindsOn = kindsOn
    settings.folders = folders ?? [Settings.Folder(path: "/photos", code: false, reading: true)]
    return settings
}

/// The kinds the helper reads in plan 5 (the ones the panel's "May be missing" text may name).
private let scReaderKinds: Set<String> = ["photo", "pdf", "doc", "audio", "video"]

private func scCounts(done: Int, pending: Int = 0, needs: Int = 0) -> IndexCounts {
    IndexCounts(done: done, pending: pending == 0 ? [:] : ["photo": pending], partial: [:], needsPermission: needs)
}

private func scSame(_ a: PanelSnapshot, _ b: PanelSnapshot) -> Bool {
    a.model == b.model && a.startPressed == b.startPressed && a.indexDeleted == b.indexDeleted
        && a.walkDone == b.walkDone && a.counts == b.counts && a.vectorSourceOK == b.vectorSourceOK
        && a.kindsOn == b.kindsOn
}

// MARK: the panel rig (never shown)

private let scSilentHelper = """
#!/bin/sh
while IFS= read -r line; do :; done
"""

/// A temp HOME with a settings file, the real `Panel` (never shown) given `world`'s cache before its helper client,
/// and the search box focused. With `silentHelper` the helper file is a script that reads and answers nothing, so a
/// typed text is never ranked.
@MainActor
private func scWithPanel(world: SCWorld, queue: DispatchQueue, silentHelper: Bool = false,
                         _ body: @MainActor (Panel, StatusCache, HelperClient) async throws -> Void) async throws {
    _ = NSApplication.shared
    try await spWithHome { home in
        try SettingsFile().write(scSettings())
        let panel = Panel()
        let cache = StatusCache(sources: world.sources(), queue: queue)
        panel.attach(status: cache)
        var helperFile = home.appendingPathComponent("no-such-helper")
        if silentHelper {
            helperFile = home.appendingPathComponent("silent-helper")
            try scSilentHelper.write(to: helperFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperFile.path)
        }
        let client = HelperClient(helper: helperFile, textModel: home, mmModel: home)
        panel.attach(helper: client)
        _ = panel.makeFirstResponder(panel.queryBox.field)
        try await body(panel, cache, client)
    }
}

@MainActor
private func scShown(_ panel: Panel) -> [String] {
    guard let root = panel.contentView else { return [] }
    return prShownTexts(root)
}

@MainActor
private func scLabels(_ panel: Panel) -> [String] {
    guard let root = panel.contentView else { return [] }
    return prAccessibilityLabels(root)
}

/// Loads the cache once from `world` and waits until the panel could draw it.
@MainActor
private func scLoad(_ cache: StatusCache, _ panel: Panel, until ready: @escaping @Sendable (PanelSnapshot) -> Bool) async -> Bool {
    cache.refresh()
    return await spEventually { ready(cache.snapshot()) }
}

// MARK: the suite

extension ModelDownloadTests {
    @Suite("StatusCacheTests", .serialized)
    struct StatusCacheTests {

        // MARK: the cache alone

        @MainActor
        @Test func beforeTheFirstRefreshSnapshotIsThePlan1DefaultAndCallsNoSource() {
            let world = SCWorld()
            let cache = StatusCache(sources: world.sources(), queue: scMakeQueue())
            for _ in 0..<25 {
                #expect(scSame(cache.snapshot(), PanelSnapshot()), "the first snapshot is not the plan-1 default")
            }
            #expect(world.totalCalls == 0, "snapshot() called a source \(world.totalCalls) times")
        }

        @MainActor
        @Test func snapshotNeverCallsASourceAfterARefreshEither() async {
            let world = SCWorld()
            let queue = scMakeQueue()
            let cache = StatusCache(sources: world.sources(), queue: queue)
            cache.refresh()
            #expect(await spEventually { cache.snapshot().counts.needsPermission == 1 }, "the refresh never stored its result")
            await scDrain(queue)
            await spWait(0.2)
            let calls = world.totalCalls
            #expect(calls > 0)
            for _ in 0..<25 {
                let snapshot = cache.snapshot()
                #expect(snapshot.counts == scCounts(done: 8, pending: 1, needs: 1))
            }
            #expect(world.totalCalls == calls, "snapshot() called a source: \(world.totalCalls - calls) extra calls")
        }

        @MainActor
        @Test func refreshRunsEverySourceOffTheMainThreadOnTheGivenQueue() async {
            let world = SCWorld()
            let queue = scMakeQueue()
            let cache = StatusCache(sources: world.sources(), queue: queue)
            cache.refresh()   // called here, on the main thread
            #expect(await spEventually { cache.snapshot().counts.needsPermission == 1 })
            await scDrain(queue)
            #expect(world.settingsCallCount >= 1, "settings was never read")
            #expect(world.countsCallCount >= 1, "the index counts were never read")
            #expect(world.modelCallCount >= 1, "the model state was never read")
            #expect(world.metaKeys.contains("walk_done_at"), "meta(walk_done_at) was never read: \(world.metaKeys)")
            #expect(world.metaKeys.contains("vector_source"), "meta(vector_source) was never read: \(world.metaKeys)")
            #expect(world.mainThreadCalls == 0, "\(world.mainThreadCalls) source calls ran on the main thread")
            #expect(world.callsOffTheGivenQueue == 0, "\(world.callsOffTheGivenQueue) source calls ran off the given queue")
        }

        @MainActor
        @Test func theStoredSnapshotCarriesWhatTheSourcesSaid() async {
            let folders = [
                Settings.Folder(path: "/a", code: false, reading: true),
                Settings.Folder(path: "/r1", code: true, reading: true),
                Settings.Folder(path: "/r2", code: true, reading: true),
            ]
            let world = SCWorld(
                settings: scSettings(startPressed: true, indexDeleted: false, codeSearchOn: true,
                                     kindsOn: ["photo": true, "pdf": false, "code": true], folders: folders),
                counts: IndexCounts(done: 8, pending: ["photo": 1], partial: ["pdf": 2], needsPermission: 3),
                walkDoneAt: "1700000000", model: .damaged)
            let cache = StatusCache(sources: world.sources(), queue: scMakeQueue())
            cache.refresh()
            #expect(await spEventually { cache.snapshot().counts.needsPermission == 3 })
            let first = cache.snapshot()
            #expect(first.model == .damaged)
            #expect(first.startPressed)
            #expect(!first.indexDeleted)
            // plan-5-t7 AMENDMENT of the sealed `first.kindsOn == ["photo", "code"]`. Reason: that line pinned "the kinds settings.json
            // has as true", which is what made a default settings.json (a `kindsOn` holding only `photo`) name Photos alone in the
            // panel's "May be missing" text, although PDFs, Documents, Audio and Video are read too. The entry (StateViews.swift
            // line 118) builds it from every reader kind whose key is not false, a missing key meaning on as in `Visible`. Here
            // pdf is false (not listed), photo is true, doc, audio and video have no key (listed). Code is no reader kind in
            // plan 5 and whether the `code` entry appears is plan 6's: it is not pinned, so the readers are compared alone.
            #expect(first.kindsOn.intersection(scReaderKinds) == ["photo", "doc", "audio", "video"], "kindsOn is \(first.kindsOn)")
            #expect(first.walkDone)
            #expect(first.counts == IndexCounts(done: 8, pending: ["photo": 1], partial: ["pdf": 2], needsPermission: 3))

            // the other way round: no walk finished, Start not pressed, the index deleted
            world.set(settings: scSettings(startPressed: false, indexDeleted: true), counts: scCounts(done: 0),
                      walkDoneAt: .some(nil), model: .whole)
            cache.refresh()
            #expect(await spEventually { cache.snapshot().counts.done == 0 })
            let second = cache.snapshot()
            #expect(second.model == .whole)
            #expect(!second.startPressed)
            #expect(second.indexDeleted)
            #expect(!second.walkDone, "no walk_done_at must read as no walk finished")
            // plan-5-t7 AMENDMENT of the sealed `second.kindsOn == ["photo"]` (same reason). The settings of this snapshot are the
            // default ones (`kindsOn` holds only `photo`): the panel's "May be missing" list names Photos, PDFs, Documents, Audio
            // and Video, not Photos alone.
            #expect(second.kindsOn.intersection(scReaderKinds) == ["photo", "pdf", "doc", "audio", "video"], "kindsOn is \(second.kindsOn)")
        }

        @MainActor
        @Test func onChangeIsCalledOnlyWhenTheValueChanged() async {
            let world = SCWorld()
            let queue = scMakeQueue()
            let cache = StatusCache(sources: world.sources(), queue: queue)
            let changes = SCCount()
            cache.onChange = { changes.add() }

            cache.refresh()   // the default becomes the sources' value: a change
            #expect(await spEventually { changes.value == 1 }, "no change reported for the first real value")

            cache.refresh()   // the same values again: not a change
            #expect(await spEventually { world.countsCallCount == 2 }, "the second refresh never ran")
            await scDrain(queue)
            await spWait(0.3)
            #expect(changes.value == 1, "onChange fired for a refresh that found the same value: \(changes.value) calls")

            world.set(counts: scCounts(done: 9, pending: 0, needs: 1))   // pending went to done: a change
            cache.refresh()
            #expect(await spEventually { changes.value == 2 }, "no change reported when the counts changed")
            #expect(cache.snapshot().counts == scCounts(done: 9, pending: 0, needs: 1))
            await spWait(0.3)
            #expect(changes.value == 2)
        }

        @MainActor
        @Test func helperChangedSettingsChangedAndPanelOpenedEachScheduleOneRefresh() async {
            let triggers: [(name: String, fire: @MainActor (StatusCache) -> Void)] = [
                ("helperChanged", { $0.helperChanged() }),
                ("settingsChanged", { $0.settingsChanged() }),
                ("panelOpened", { $0.panelOpened() }),
            ]
            for trigger in triggers {
                let world = SCWorld()
                let queue = scMakeQueue()
                let cache = StatusCache(sources: world.sources(), queue: queue)
                trigger.fire(cache)
                #expect(await spEventually { world.countsCallCount >= 1 }, "\(trigger.name) scheduled no refresh")
                await scDrain(queue)
                await spWait(0.3)
                #expect(world.countsCallCount == 1, "\(trigger.name) ran \(world.countsCallCount) refreshes, not one")
                #expect(world.settingsCallCount == 1)
                #expect(cache.snapshot().counts.needsPermission == 1, "\(trigger.name) refreshed but stored nothing")
            }
        }

        @MainActor
        @Test func fiveCallsWhileARefreshRunsCauseAtMostOneMoreAndTheLastValueWins() async {
            let gate = SCGate(armed: false)
            let world = SCWorld(counts: scCounts(done: 8, pending: 1, needs: 1), gate: gate)
            let queue = scMakeQueue()
            let cache = StatusCache(sources: world.sources(), queue: queue)
            gate.arm()
            defer { gate.open() }

            cache.refresh()
            #expect(await spEventually { gate.entered }, "the first refresh never reached its source")

            // the data changes while that refresh is held (it already read the old counts), then five calls arrive
            world.set(counts: scCounts(done: 20, pending: 0, needs: 2))
            cache.helperChanged()
            cache.settingsChanged()
            cache.panelOpened()
            cache.helperChanged()
            cache.settingsChanged()
            gate.open()

            #expect(await spEventually { cache.snapshot().counts == scCounts(done: 20, pending: 0, needs: 2) },
                    "the refresh the calls asked for never stored the new counts; snapshot is \(cache.snapshot().counts)")
            await scDrain(queue)
            await spWait(0.4)
            #expect(!gate.fired)
            #expect(world.countsCallCount == 2, "five calls during one refresh made \(world.countsCallCount) refreshes in all, not two")
            #expect(world.settingsCallCount == 2)
        }

        @MainActor
        @Test func aSourceBlockedOnTheMatrixLoadDoesNotStopSnapshotFromReturning() async {
            let gate = SCGate(armed: false)
            let world = SCWorld(counts: scCounts(done: 8, pending: 1, needs: 1), gate: gate)
            let queue = scMakeQueue()
            let cache = StatusCache(sources: world.sources(), queue: queue)
            cache.refresh()
            #expect(await spEventually { cache.snapshot().counts == scCounts(done: 8, pending: 1, needs: 1) })
            await scDrain(queue)

            // the next refresh is held inside a source, as a refresh behind the matrix load would be
            world.set(counts: scCounts(done: 30, pending: 0, needs: 0))
            gate.arm()
            defer { gate.open() }
            cache.refresh()
            #expect(await spEventually { gate.entered }, "the refresh never reached the blocked source")

            // these run on the main thread; a snapshot() that waited for the refresh would not return until the
            // watchdog (10 s) opens the gate, and `fired` then fails the test
            let first = cache.snapshot()
            let second = cache.snapshot()
            #expect(!gate.fired, "snapshot() waited for the blocked refresh")
            #expect(first.counts == scCounts(done: 8, pending: 1, needs: 1), "snapshot during the refresh is \(first.counts)")
            #expect(scSame(first, second), "two snapshots during one refresh differ")

            gate.open()
            #expect(await spEventually { cache.snapshot().counts == scCounts(done: 30, pending: 0, needs: 0) },
                    "the held refresh never stored its value after the gate opened")
        }

        // The function a background source calls stays as plan 1 left it (a guard: it passes before the change too).
        @MainActor
        @Test func panelSnapshotReadStillReadsTheIndexForABackgroundSource() async throws {
            try await spWithHome { _ in
                try SettingsFile().write(scSettings(startPressed: true))
                let store = try IndexStore()
                for (position, status) in ["done", "done", "needs_permission"].enumerated() {
                    _ = try store.addFile(path: "/photos/f\(position).jpg", kind: "photo", size: 1000,
                                          mtimeNs: 1_700_000_000_000_000_000, inode: Int64(900 + position),
                                          device: 16_777_220, status: status)
                }
                store.close()
                let reader = IndexReader()
                defer { reader.close() }
                let snapshot = PanelSnapshot.read(reader: reader, model: .whole)
                #expect(snapshot.counts.done == 2, "done is \(snapshot.counts.done)")
                #expect(snapshot.counts.needsPermission == 1, "needsPermission is \(snapshot.counts.needsPermission)")
                #expect(snapshot.model == .whole)
                #expect(snapshot.startPressed)
            }
        }

        // MARK: through the real Panel (never shown)

        @MainActor
        @Test func theAttachedPanelDrawsFromTheCacheAndNoSourceRunsOnTheMainThread() async throws {
            let world = SCWorld(counts: scCounts(done: 8, pending: 1, needs: 1))
            let queue = scMakeQueue()
            try await scWithPanel(world: world, queue: queue) { panel, cache, _ in
                await prType("a", into: panel)
                #expect(world.mainThreadCalls == 0, "the panel called a source on the main thread while drawing a key")

                #expect(await scLoad(cache, panel, until: { $0.counts.needsPermission == 1 }))
                await prType("b", into: panel, pauseMilliseconds: 20)
                let drawn = await spEventually { scShown(panel).contains("Still indexing (88%)") }
                #expect(drawn, "the panel did not draw the cached state; it shows \(scShown(panel))")
                #expect(world.mainThreadCalls == 0, "\(world.mainThreadCalls) source calls ran on the main thread")
                #expect(world.callsOffTheGivenQueue == 0)
            }
        }

        @MainActor
        @Test func thePanelDrawsThePermissionNoteAsItsOwnLineWithAnAccessibilityLabel() async throws {
            // indexing: the banner and the note are two lines
            let busy = SCWorld(counts: scCounts(done: 8, pending: 1, needs: 1))
            try await scWithPanel(world: busy, queue: scMakeQueue()) { panel, cache, _ in
                #expect(await scLoad(cache, panel, until: { $0.counts.needsPermission == 1 }))
                await prType("ab", into: panel, pauseMilliseconds: 20)
                let note = "1 file needs permission to be read"
                #expect(await spEventually { scShown(panel).contains(note) },
                        "no visible line holds the note; the panel shows \(scShown(panel))")
                let shown = scShown(panel)
                #expect(shown.contains("Still indexing (88%)"), "the banner is gone: \(shown)")
                #expect(!shown.contains { $0.contains("Still indexing") && $0.contains("permission") },
                        "the banner and the note share one line: \(shown)")
                #expect(scLabels(panel).contains { $0.contains(note) },
                        "no view has an accessibility label holding the note; labels: \(scLabels(panel))")
            }

            // ready: no banner, the note alone, with the file count of the second state
            let ready = SCWorld(counts: scCounts(done: 10, pending: 0, needs: 2))
            try await scWithPanel(world: ready, queue: scMakeQueue()) { panel, cache, _ in
                #expect(await scLoad(cache, panel, until: { $0.counts.needsPermission == 2 }))
                await prType("ab", into: panel, pauseMilliseconds: 20)
                let note = "2 files need permission to be read"
                #expect(await spEventually { scShown(panel).contains(note) },
                        "no visible line holds the note when ready; the panel shows \(scShown(panel))")
                #expect(!scShown(panel).contains { $0.contains("Still indexing") }, "a banner shows for a ready index")
                #expect(scLabels(panel).contains { $0.contains(note) },
                        "no accessibility label holds the note; labels: \(scLabels(panel))")
            }
        }

        @MainActor
        @Test func thePanelDrawsNoNoteWhenNoFileNeedsPermission() async throws {
            // pending 1 puts the banner on screen, so the draw has happened when the absence is checked
            let world = SCWorld(counts: scCounts(done: 8, pending: 1, needs: 0))
            try await scWithPanel(world: world, queue: scMakeQueue()) { panel, cache, _ in
                #expect(await scLoad(cache, panel, until: { $0.counts.pending == ["photo": 1] }))
                await prType("ab", into: panel, pauseMilliseconds: 20)
                #expect(await spEventually { scShown(panel).contains("Still indexing (88%)") },
                        "the panel never drew the cached state: \(scShown(panel))")
                #expect(!scShown(panel).contains { $0.contains("permission") }, "a note shows with no such file: \(scShown(panel))")
                #expect(!scLabels(panel).contains { $0.contains("permission") }, "a label mentions permission: \(scLabels(panel))")
            }
        }

        @MainActor
        @Test func theNoteAndStillRankingAreTwoVisibleLines() async throws {
            let world = SCWorld(counts: scCounts(done: 10, pending: 0, needs: 2))
            // the helper reads and answers nothing, so the typed text is never ranked and Enter waits its 2 s
            try await scWithPanel(world: world, queue: scMakeQueue(), silentHelper: true) { panel, cache, _ in
                #expect(await scLoad(cache, panel, until: { $0.counts.needsPermission == 2 }))
                await prType("a dog", into: panel, pauseMilliseconds: 20)
                let note = "2 files need permission to be read"
                #expect(await spEventually { scShown(panel).contains(note) }, "the note is not drawn: \(scShown(panel))")

                panel.sendEvent(prKey("\r", in: panel, keyCode: 36))
                let ranking = await spEventually(timeout: 15) { scShown(panel).contains(PanelScreen.stillRankingText) }
                let shown = scShown(panel)
                #expect(ranking, "Still ranking never appeared; the panel shows \(shown)")
                #expect(shown.contains(note), "Still ranking replaced the note: \(shown)")
                #expect(!shown.contains { $0.contains(PanelScreen.stillRankingText) && $0.contains("permission") },
                        "the note and Still ranking share one line: \(shown)")
            }
        }

        @MainActor
        @Test func aChangedEventFromTheHelperGoesThroughTheCacheRefresh() async throws {
            let world = SCWorld()
            let queue = scMakeQueue()
            try await scWithPanel(world: world, queue: queue) { panel, cache, client in
                #expect(await scLoad(cache, panel, until: { $0.counts.needsPermission == 1 }))
                await scDrain(queue)
                await spWait(0.3)
                let before = world.countsCallCount

                guard let delegate = client.delegate else {
                    Issue.record("the helper client has no delegate, so the panel does not hear `changed` events")
                    return
                }
                delegate.helperClient(client, didReceive: .changed)
                #expect(await spEventually { world.countsCallCount > before },
                        "a `changed` event did not refresh the cache (counts read \(world.countsCallCount) times, was \(before))")
                #expect(world.mainThreadCalls == 0)
            }
        }

        @MainActor
        @Test func aRefreshHeldOnTheReaderDoesNotFreezeTheOpenPanel() async throws {
            let gate = SCGate(armed: false)
            let world = SCWorld(counts: scCounts(done: 8, pending: 1, needs: 1), gate: gate)
            let queue = scMakeQueue()
            try await scWithPanel(world: world, queue: queue) { panel, cache, _ in
                #expect(await scLoad(cache, panel, until: { $0.counts.needsPermission == 1 }))
                await scDrain(queue)

                world.set(counts: scCounts(done: 9, pending: 0, needs: 1))
                gate.arm()
                defer { gate.open() }
                cache.refresh()
                #expect(await spEventually { gate.entered })

                // keys go through the panel on the main thread while the refresh is held; if drawing one waited
                // for the refresh the main thread would stop until the watchdog (10 s) opens the gate
                await prType("abc", into: panel, pauseMilliseconds: 10)
                #expect(!gate.fired, "the panel waited for the held refresh")
                #expect(panel.queryBox.text == "abc", "the box holds \(panel.queryBox.text)")
                #expect(world.mainThreadCalls == 0)

                gate.open()
                #expect(await spEventually { cache.snapshot().counts.done == 9 })
            }
        }
    }
}

// MARK: plan-2 fix round E, tester step, item E5 (R4-07): `ModelStateSource`, the source of the status snapshot's `ModelState`
//
// Written from the fix-round document ("`ModelStateSource` tests: precedence `failed` over `damaged` over `downloading`,
// `retried()` clears failed, a whole model clears every flag") and the round D reports (`markDamaged()`, `markFailed()`,
// `retried()`, `state()`). The class had no test and no pinned init, so the one grep that listed its method names also showed its body (about 40 lines of
// StatusCache.swift); every expected value below comes from the document and the reports, none is copied from that code.
//
// SHAPE E5 pins here (new): the class decides "whole" by looking at the real model files in the user's Sesame folder, so a
// test cannot choose the answer. A seam is needed:
//   ModelStateSource.init(isWhole: @escaping @Sendable () -> Bool = { ModelStateSource.isWhole() })
// The default keeps `ModelStateSource()` and the real check as they are. `state()` asks the closure each time it is called.
// The rules pinned (all existing behaviour, so the tests of the rules are GUARDS that pass once the seam compiles):
//   - not whole, no flag: `.downloading`; after `markDamaged()`: `.damaged`; after `markFailed()`: `.failed`
//   - both flags: `.failed` (failed over damaged over downloading), whatever order they were set in
//   - `retried()` clears the failed flag only: failed + damaged then retried gives `.damaged`; failed alone then retried gives `.downloading`
//   - whole: `.whole` whatever flags are set, and it clears every flag: a later not-whole answer is `.downloading`, not `.failed`
//     or `.damaged`
//   - after a whole answer the flags can be set again and show again
// The stale doc comments (`ModelStateSource`, `ModelRecovery.watcherFailed`) are for the fixer; no test can read a comment.

private final class MSSWhole: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isWhole: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

@Suite("ModelStateSourceTests")
struct ModelStateSourceTests {

    private func rig(whole: Bool = false) -> (source: ModelStateSource, whole: MSSWhole) {
        let box = MSSWhole()
        box.isWhole = whole
        return (ModelStateSource(isWhole: { box.isWhole }), box)
    }

    @Test func aModelThatIsNotWholeAndHasNoFlagIsDownloading() {
        let (source, _) = rig()
        #expect(source.state() == .downloading)
        #expect(source.state() == .downloading)
    }

    @Test func aDamagedFileIsTheDamagedState() {
        let (source, _) = rig()
        source.markDamaged()
        #expect(source.state() == .damaged)
    }

    @Test func aGivenUpDownloadIsTheFailedState() {
        let (source, _) = rig()
        source.markFailed()
        #expect(source.state() == .failed)
    }

    @Test func failedIsOverDamagedWhicheverWasSetFirst() {
        let (first, _) = rig()
        first.markDamaged()
        first.markFailed()
        #expect(first.state() == .failed, "damaged then failed gave \(first.state())")

        let (second, _) = rig()
        second.markFailed()
        second.markDamaged()
        #expect(second.state() == .failed, "failed then damaged gave \(second.state())")
    }

    @Test func retriedClearsTheFailedFlagAndLeavesTheDamagedOne() {
        let (both, _) = rig()
        both.markFailed()
        both.markDamaged()
        both.retried()
        #expect(both.state() == .damaged, "failed and damaged, then retried gave \(both.state())")

        let (failedOnly, _) = rig()
        failedOnly.markFailed()
        failedOnly.retried()
        #expect(failedOnly.state() == .downloading, "failed, then retried gave \(failedOnly.state())")
    }

    @Test func retriedWithNothingFailedChangesNothing() {
        let (fresh, _) = rig()
        fresh.retried()
        #expect(fresh.state() == .downloading)
        let (damaged, _) = rig()
        damaged.markDamaged()
        damaged.retried()
        #expect(damaged.state() == .damaged, "retried cleared the damaged flag: \(damaged.state())")
    }

    @Test func aFailureAfterRetryShowsAgain() {
        let (source, _) = rig()
        source.markFailed()
        source.retried()
        #expect(source.state() == .downloading)
        source.markFailed()
        #expect(source.state() == .failed)
    }

    @Test func aWholeModelIsWholeWhateverFlagsAreSet() {
        let (source, whole) = rig()
        source.markDamaged()
        source.markFailed()
        whole.isWhole = true
        #expect(source.state() == .whole, "a whole model gave \(source.state())")
        #expect(source.state() == .whole)
    }

    @Test func aWholeAnswerClearsEveryFlagSoALaterNotWholeIsDownloading() {
        let (source, whole) = rig()
        source.markDamaged()
        source.markFailed()
        whole.isWhole = true
        _ = source.state()
        whole.isWhole = false
        #expect(source.state() == .downloading, "the flags came back after the model was whole: \(source.state())")
    }

    @Test func theFlagsCanBeSetAgainAfterTheModelWasWhole() {
        let (source, whole) = rig()
        source.markFailed()
        whole.isWhole = true
        _ = source.state()
        whole.isWhole = false
        source.markDamaged()
        #expect(source.state() == .damaged)
        source.markFailed()
        #expect(source.state() == .failed)
    }

    @Test func theDefaultSourceStillAnswersWithoutASeam() {
        // the real check looks at the real model files (read only); with no flag set it answers whole or downloading, never failed or damaged
        let source = ModelStateSource()
        let state = source.state()
        #expect([ModelState.whole, .downloading].contains(state), "a fresh default source answered \(state)")
    }
}
