import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SesameEngine
@testable import SesameHelper

// plan-2-t34, tester step (carry-over F8). Written from the t34 entry, design sections 1, 3 and 8 and the t33 report
// only; no product source read. The harness (`At...` names: AtDB, AtWorld, atStartHelper, atIndexedWorld, atWrite,
// AtPoller ...) is the one IndexAttemptTests.swift holds.
//
// What the entry fixes (expected values; none comes from the code under test):
// - The cap is 850,000,000 bytes and the constant is not above it. Below the cap nothing happens (no exit, no write).
//   At the cap or above it, the FIRST trip on a file (a row that holds neither `hint:solo` nor `hint:memory`) writes the
//   hint `hint:solo` on that row and sets `tries` back to 0 in the same committed write, then calls the injected exit.
//   The file stays `pending`. Seen from outside: the exit closure reads the row at the moment it is called, and a second
//   read-only connection polls while 150 trips run and must never see `hint:solo` with `tries` above 0, nor a row whose
//   `tries` is 0 with no hint (the other order of a two-step write).
// - A trip during the solo read (the row holds `hint:solo`, `tries` 1 after the attempt marker) leaves `tries` 1 and
//   writes the hint `hint:memory`, then exits. The next run reads the file once more (tries 1), a trip there leaves
//   `hint:memory` and `tries` 2 (never a new solo, never 0: a bad file blocks nothing for more than two deaths), and the
//   run after that ends it in the store as `could_not_read` "needed too much memory" (the queue rule of t33, seen through
//   the built helper).
// - After a first trip the restarted helper reads that file alone, before any other work: of 12 pending files the oldest
//   (normally read last) must be the first one written. An ordinary large file read alone and within the cap is never
//   marked: it ends `done`, `tries` 0, and its reason is never the memory hint or "needed too much memory".
// - The sampler checks the footprint about every 250 ms on its own thread; the interval is injected.
// - `FootprintReader.current()` is the real physical footprint of this process: positive, under the cap, and it follows a
//   real allocation.
// The real watchdog trip is NOT provoked (no memory is pushed past 850 MB, no environment variable is added); a trip is
// made only through the injected footprint source. Wall-clock figures have at least 4x slack.
//
// SHAPES THESE TESTS PIN (the entry gives the names `Watchdog` and `FootprintReader.current()` only; if a shape is wrong,
// ask for a test change; every construction is in `wdMake` below, one place to edit):
//   `Watchdog.capBytes`                          static constant, an integer, bytes
//   `Watchdog(store: IndexStore, interval: TimeInterval = 0.25, footprint: @Sendable () -> UInt64, exit: @Sendable () -> Void)`
//   `watchdog.watch(_ files: [IndexStore.PendingPhoto])`   the unit now being read, as `pendingPhotos(limit:)` returned
//        it BEFORE `beginAttempt` (the row's `reason` tells a solo read from a first read)
//   `watchdog.sample()`                          one check on the caller's thread: reads the footprint once; at or above
//        the cap it applies the trip rule and calls exit; below it does nothing. Never throws.
//   `watchdog.start()` / `watchdog.stop()`       the sampler thread: `start` samples every `interval` seconds on its own
//        thread, `stop` returns once that thread has finished (at most one more sample may land after it returns)
//   `FootprintReader.current()`                  an integer, bytes
//   After a trip the sampler may sample again before the process dies: a later sample must leave the store as the trip
//   left it (a second sample must not turn `hint:solo` into `hint:memory`).

// MARK: the injected footprint source and exit

private final class WdFootprint: @unchecked Sendable {
    private let lock = NSLock()
    private var level: UInt64
    private var script: [UInt64]
    private var count = 0
    private var threads = Set<UInt32>()

    /// Answers `script` first, one value per call, then `level`.
    init(_ level: UInt64, first script: [UInt64] = []) {
        self.level = level
        self.script = script
    }

    func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        count += 1
        threads.insert(pthread_mach_thread_np(pthread_self()))
        return script.isEmpty ? level : script.removeFirst()
    }

    func set(_ value: UInt64) { lock.lock(); level = value; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var callingThreads: Set<UInt32> { lock.lock(); defer { lock.unlock() }; return threads }
}

private final class WdExit: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [AtRow?] = []
    private let observe: @Sendable () -> AtRow?

    /// `observe` runs at the moment the watchdog calls exit and its answer is kept.
    init(observe: @escaping @Sendable () -> AtRow? = { nil }) { self.observe = observe }

    func fire() {
        let row = observe()
        lock.lock(); seen.append(row); lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return seen.count }
    var rowsAtExit: [AtRow?] { lock.lock(); defer { lock.unlock() }; return seen }
}

/// The one place that builds a Watchdog.
private func wdMake(_ store: IndexStore, _ footprint: WdFootprint, _ exit: WdExit, interval: TimeInterval? = nil) -> Watchdog {
    if let interval {
        return Watchdog(store: store, interval: interval, footprint: { footprint.next() }, exit: { exit.fire() })
    }
    return Watchdog(store: store, footprint: { footprint.next() }, exit: { exit.fire() })
}

private var wdCap: UInt64 { UInt64(Watchdog.capBytes) }

// MARK: the store, as the helper would use it

private let wdDevice: Int64 = 16_777_220

private func wdIndexPath(_ t: TempHome) -> String {
    t.folder.appendingPathComponent("index.sqlite").path
}

private func wdRow(_ t: TempHome, _ name: String) -> AtRow? {
    AtDB(path: wdIndexPath(t)).flatMap(atRows)?[name + ".jpg"]
}

private func wdAddPending(_ store: IndexStore, count: Int) throws {
    for number in 1...count {
        _ = try store.addFile(path: "/photos/w-\(String(format: "%04d", number)).jpg", kind: "photo",
                              size: Int64(1000 + number), mtimeNs: 1_700_000_000_000_000_000 + Int64(number) * 1_000_000_000,
                              inode: Int64(7000 + number), device: wdDevice, status: "pending")
    }
}

private func wdPhoto(_ store: IndexStore, _ name: String) throws -> IndexStore.PendingPhoto {
    try #require(try store.pendingPhotos(limit: 500).first { ($0.path as NSString).lastPathComponent == name + ".jpg" },
                 "pendingPhotos does not list \(name).jpg")
}

/// What one helper run does to a file that is too big: take the unit, mark the attempt, watch it, and the footprint is at
/// the cap. Returns how many times the injected exit was called.
@discardableResult
private func wdReadAndTrip(_ store: IndexStore, _ name: String) throws -> Int {
    let photo = try wdPhoto(store, name)
    try store.beginAttempt([photo])
    let exit = WdExit()
    let dog = wdMake(store, WdFootprint(wdCap), exit)
    dog.watch([photo])
    dog.sample()
    return exit.count
}

/// An in-process store on the index of a world whose helper is not running. HOME points at the world only while the store
/// is opened and used.
private func wdWithStore(_ world: AtWorld, _ body: (IndexStore) throws -> Void) throws {
    homeLock.lock()
    defer { homeLock.unlock() }
    let previous = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", world.home.path, 1)
    defer { if let previous { setenv("HOME", previous, 1) } else { unsetenv("HOME") } }
    let store = try IndexStore()
    defer { store.close() }
    try body(store)
}

/// One helper run over the world's folder: waits for `until`, then ends stdin and expects exit 0.
private func wdRunHelper(_ world: AtWorld, until: ([String: Int]) -> Bool) throws -> AtWait {
    let helper = try atStartHelper(world)
    defer { helper.stop() }
    helper.send(atFoldersLine([world.photos]))
    let wait = atWaitStatuses(world, helper, until: until)
    #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")
    return wait
}

private func wdLargePhoto(_ url: URL, side: Int, seed: Int, modified: Date) throws {
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    var state = UInt64(truncatingIfNeeded: seed) &* 2_654_435_761 &+ 12_345
    for index in stride(from: 0, to: pixels.count, by: 4) {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        pixels[index] = UInt8(truncatingIfNeeded: state >> 33)
        pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 41)
        pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 49)
        pixels[index + 3] = 255
    }
    let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
    let data = NSMutableData()
    guard let image, let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
        throw AtError("the test could not draw the large photo")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw AtError("the test could not encode the large photo") }
    try (data as Data).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
}

extension EncodeHelperTests {
@Suite("WatchdogTests", .serialized)
struct WatchdogTests {

    // MARK: the cap and the real footprint

    @Test func theCapIsNotAbove850MillionBytes() throws {
        #expect(UInt64(Watchdog.capBytes) <= 850_000_000, "the cap is \(Watchdog.capBytes) bytes, the design's table allows 850,000,000")
        #expect(UInt64(Watchdog.capBytes) > 0, "a cap of 0 trips on every sample")
    }

    @Test func theRealFootprintIsPositiveUnderTheCapAndFollowsARealAllocation() throws {
        let before = UInt64(truncatingIfNeeded: FootprintReader.current())
        #expect(before > 0, "the footprint of this process is \(before)")
        #expect(before < UInt64(Watchdog.capBytes), "the test process is at \(before) bytes, not under the cap \(Watchdog.capBytes)")

        // 300 MB of touched memory must show as at least 200 MB more: a constant or an unrelated figure cannot pass.
        let size = 300 * 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        memset(buffer, 0xA5, size)
        let during = UInt64(truncatingIfNeeded: FootprintReader.current())
        withExtendedLifetime(buffer) {}
        #expect(during >= before + 200 * 1024 * 1024,
                "after touching 300 MB the footprint went from \(before) to \(during) bytes, expected a rise of at least 200 MB")
    }

    // MARK: below the cap nothing happens

    @Test func belowTheCapNothingIsWrittenAndExitIsNotCalled() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try #require(wdCap > 100_000_000, "the cap is too small to test below it")
            try wdAddPending(store, count: 3)
            let victim = try wdPhoto(store, "w-0002")
            try store.beginAttempt([victim])
            #expect(wdRow(t, "w-0002")?.tries == 1 && wdRow(t, "w-0002")?.reason == nil, "setup: \(atDescribe(AtDB(path: wdIndexPath(t)).flatMap(atRows)))")

            let exit = WdExit()
            let footprint = WdFootprint(0, first: [0, 1, 1_000_000, wdCap - 100_000_000, wdCap - 1_000, wdCap - 1])
            let dog = wdMake(store, footprint, exit)
            dog.watch([victim])
            for _ in 0..<10 { dog.sample() }

            #expect(footprint.calls == 10, "ten samples read the footprint \(footprint.calls) times")
            #expect(exit.count == 0, "exit was called \(exit.count) times with the footprint below the cap")
            let rows = AtDB(path: wdIndexPath(t)).flatMap(atRows)
            #expect(rows?["w-0002.jpg"]?.status == "pending" && rows?["w-0002.jpg"]?.reason == nil && rows?["w-0002.jpg"]?.tries == 1,
                    "a sample below the cap changed the row: \(atDescribe(rows))")
            #expect(rows?["w-0001.jpg"]?.tries == 0 && rows?["w-0003.jpg"]?.tries == 0, "a neighbour changed: \(atDescribe(rows))")
        }
    }

    // MARK: the first trip on a file

    @Test(arguments: [UInt64(0), 1, 1_000_000_000])
    func atTheCapOrAboveTheFirstTripWritesHintSoloWithTriesZeroThenExits(above: UInt64) throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try wdAddPending(store, count: 3)
            let victim = try wdPhoto(store, "w-0002")
            try store.beginAttempt([victim])
            #expect(wdRow(t, "w-0002")?.tries == 1 && wdRow(t, "w-0002")?.reason == nil, "setup: attempt marker not set")

            let path = wdIndexPath(t)
            let exit = WdExit { AtDB(path: path).flatMap(atRows)?["w-0002.jpg"] }
            let dog = wdMake(store, WdFootprint(wdCap + above), exit)
            dog.watch([victim])
            dog.sample()

            #expect(exit.count == 1, "exit was called \(exit.count) times at the cap + \(above), expected once")
            // The row is already whole when exit runs: the hint and tries 0 were committed before the process left.
            let atExit = try #require(exit.rowsAtExit.first ?? nil, "exit was called with the row unreadable")
            #expect(atExit.status == "pending" && atExit.reason == "hint:solo" && atExit.tries == 0,
                    "when exit ran the row was \(atExit.status) reason \(atExit.reason ?? "nil") tries \(atExit.tries), expected pending, hint:solo, 0")
            let rows = AtDB(path: path).flatMap(atRows)
            #expect(rows?["w-0002.jpg"]?.status == "pending" && rows?["w-0002.jpg"]?.reason == "hint:solo" && rows?["w-0002.jpg"]?.tries == 0,
                    "after the first trip: \(atDescribe(rows))")
            #expect(rows?["w-0001.jpg"]?.reason == nil && rows?["w-0001.jpg"]?.tries == 0 && rows?["w-0003.jpg"]?.reason == nil && rows?["w-0003.jpg"]?.tries == 0,
                    "a file that was not being read was marked: \(atDescribe(rows))")
            #expect(IndexStore.soloHint == "hint:solo" && IndexStore.memoryHint == "hint:memory",
                    "the hint constants are \(IndexStore.soloHint) and \(IndexStore.memoryHint)")
        }
    }

    @Test func aFileThatDiedOnceBeforeStillGetsTheFreeSoloRetryOnItsFirstTrip() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try wdAddPending(store, count: 2)
            let first = try wdPhoto(store, "w-0001")
            try store.beginAttempt([first])                // the first read died (a crash): tries 1, no hint
            let again = try wdPhoto(store, "w-0001")       // the helper came back and reads it once more
            try store.beginAttempt([again])
            #expect(wdRow(t, "w-0001")?.tries == 2 && wdRow(t, "w-0001")?.reason == nil, "setup: expected tries 2 and no hint")

            let exit = WdExit()
            let dog = wdMake(store, WdFootprint(wdCap), exit)
            dog.watch([again])
            dog.sample()

            let row = wdRow(t, "w-0001")
            #expect(exit.count == 1, "exit was called \(exit.count) times")
            #expect(row?.status == "pending" && row?.reason == "hint:solo" && row?.tries == 0,
                    "a first memory trip is not a try: expected pending, hint:solo, tries 0, got \(atDescribe(AtDB(path: wdIndexPath(t)).flatMap(atRows)))")
        }
    }

    @Test func theHintAndTheTriesResetAreOneCommittedWrite() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let total = 150
            try wdAddPending(store, count: total)
            let photos = try store.pendingPhotos(limit: total + 10)
            #expect(photos.count == total, "setup: pendingPhotos listed \(photos.count) of \(total)")
            guard photos.count == total else { return }
            try store.beginAttempt(photos)
            #expect(AtDB(path: wdIndexPath(t))?.int("select count(*) from files where tries = 1") == total, "setup: not every file is marked")

            // Every row starts as (tries 1, no hint) and must end as (tries 0, hint:solo). A write in two steps shows a
            // second connection one of two states in between: the hint with tries above 0, or tries 0 with no hint.
            let poller = AtPoller()
            poller.start(path: wdIndexPath(t), sql: """
                select coalesce(sum(reason = 'hint:solo' and tries > 0), 0), coalesce(sum(tries = 0 and reason is null), 0) from files
                """) { rows in
                guard let row = rows.first, let hintFirst = Int(row[0] ?? ""), let triesFirst = Int(row[1] ?? "") else { return "unreadable" }
                if hintFirst > 0 { return "\(hintFirst) rows hold hint:solo with tries still above 0" }
                if triesFirst > 0 { return "\(triesFirst) rows have tries 0 and no hint yet" }
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
            for photo in photos {
                let dog = wdMake(store, WdFootprint(wdCap), WdExit())
                dog.watch([photo])
                dog.sample()
            }
            Thread.sleep(forTimeInterval: 0.1)
            let seen = poller.stop()
            #expect(seen.problems.isEmpty, "the trip is not one committed write: \(seen.problems)")
            #expect(seen.snapshots > 0, "the polling connection read nothing, so it proved nothing")
            let rows = AtDB(path: wdIndexPath(t)).flatMap(atRows)
            #expect(rows?.count == total && rows?.values.allSatisfy { $0.status == "pending" && $0.reason == "hint:solo" && $0.tries == 0 } == true,
                    "after \(total) trips some row is not pending, hint:solo, tries 0: \(atDescribe(rows).prefix(300))")
        }
    }

    @Test func aSecondSampleAfterTheTripLeavesTheStoreAsTheTripLeftIt() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try wdAddPending(store, count: 2)
            let victim = try wdPhoto(store, "w-0001")
            try store.beginAttempt([victim])
            let exit = WdExit()
            let dog = wdMake(store, WdFootprint(wdCap + 100_000_000), exit)
            dog.watch([victim])
            for _ in 0..<5 { dog.sample() }

            #expect(exit.count >= 1, "exit was never called")
            let row = wdRow(t, "w-0001")
            #expect(row?.status == "pending" && row?.reason == "hint:solo" && row?.tries == 0,
                    "five samples over the cap in one process turned the first trip into something else: \(atDescribe(AtDB(path: wdIndexPath(t)).flatMap(atRows)))")
        }
    }

    // MARK: the trip during the solo read

    @Test func afterAFirstTripTheRowIsListedWithTheSoloHintAndATripDuringTheSoloReadLeavesTriesOneAndHintMemory() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try wdAddPending(store, count: 3)

            #expect(try wdReadAndTrip(store, "w-0002") == 1, "the first trip did not call exit once")
            // The restarted helper's queue: the row carries the hint and no attempt.
            let queued = try wdPhoto(store, "w-0002")
            #expect(queued.reason == "hint:solo" && queued.tries == 0,
                    "the restarted helper lists the file with reason \(queued.reason ?? "nil") and tries \(queued.tries), expected hint:solo and 0")

            // The solo read: the marker goes on (tries 1), then the footprint is at the cap again.
            try store.beginAttempt([queued])
            #expect(wdRow(t, "w-0002")?.tries == 1 && wdRow(t, "w-0002")?.reason == "hint:solo", "setup: the solo read's marker")
            let path = wdIndexPath(t)
            let exit = WdExit { AtDB(path: path).flatMap(atRows)?["w-0002.jpg"] }
            let dog = wdMake(store, WdFootprint(wdCap), exit)
            dog.watch([queued])
            dog.sample()

            #expect(exit.count == 1, "exit was called \(exit.count) times for the trip during the solo read")
            let atExit = try #require(exit.rowsAtExit.first ?? nil, "exit was called with the row unreadable")
            #expect(atExit.status == "pending" && atExit.reason == "hint:memory" && atExit.tries == 1,
                    "when exit ran the row was \(atExit.status) reason \(atExit.reason ?? "nil") tries \(atExit.tries), expected pending, hint:memory, 1")
            let rows = AtDB(path: path).flatMap(atRows)
            #expect(rows?["w-0002.jpg"]?.status == "pending" && rows?["w-0002.jpg"]?.reason == "hint:memory" && rows?["w-0002.jpg"]?.tries == 1,
                    "after the trip during the solo read: \(atDescribe(rows))")
            #expect(rows?["w-0001.jpg"]?.reason == nil && rows?["w-0003.jpg"]?.reason == nil && rows?["w-0001.jpg"]?.tries == 0,
                    "a neighbour was marked: \(atDescribe(rows))")
        }
    }

    @Test func aTripOnTheReadOnceMoreKeepsHintMemoryAndSpendsTheTryNeverASecondSolo() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try wdAddPending(store, count: 2)
            try wdReadAndTrip(store, "w-0001")      // run 1: first trip, solo hint, tries 0
            try wdReadAndTrip(store, "w-0001")      // run 2: the solo read trips, hint:memory, tries 1
            #expect(wdRow(t, "w-0001")?.reason == "hint:memory" && wdRow(t, "w-0001")?.tries == 1, "setup: after the solo trip")

            // Run 3: tries 1 is read once more (the attempt marker makes it 2) and the footprint is at the cap again.
            #expect(try wdReadAndTrip(store, "w-0001") == 1, "the trip on the read once more did not call exit once")
            let row = wdRow(t, "w-0001")
            #expect(row?.status == "pending" && row?.reason == "hint:memory" && row?.tries == 2,
                    "a trip on a file that already holds hint:memory must leave hint:memory and tries 2 (a death spends a try), got \(atDescribe(AtDB(path: wdIndexPath(t)).flatMap(atRows)))")
        }
    }

    @Test func aLargeFileReadAloneAndWithinTheCapIsNeverMarked() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try wdAddPending(store, count: 2)
            try wdReadAndTrip(store, "w-0001")      // the first read tripped; the file is now due for its solo read
            let queued = try wdPhoto(store, "w-0001")
            #expect(queued.reason == "hint:solo", "setup: the file is not marked for a solo read")
            try store.beginAttempt([queued])

            // A big file, but the footprint stays within the cap for the whole read.
            let exit = WdExit()
            let footprint = WdFootprint(wdCap - 1, first: [wdCap - 200_000_000, wdCap - 100_000_000, wdCap - 1_000])
            let dog = wdMake(store, footprint, exit)
            dog.watch([queued])
            for _ in 0..<8 { dog.sample() }
            #expect(exit.count == 0, "exit was called \(exit.count) times with the footprint within the cap")
            let during = wdRow(t, "w-0001")
            #expect(during?.reason == "hint:solo" && during?.tries == 1, "a sample within the cap changed the row: \(atDescribe(AtDB(path: wdIndexPath(t)).flatMap(atRows)))")

            #expect(try store.completePhoto(queued, nameWords: "large scan", ocrText: "", vector: (0..<768).map { Float(sin(Double($0) * 0.37) * 0.9) }),
                    "completePhoto of the large file changed nothing")
            let row = wdRow(t, "w-0001")
            #expect(row?.status == "done" && row?.tries == 0, "after the solo read: \(atDescribe(AtDB(path: wdIndexPath(t)).flatMap(atRows)))")
            #expect(row?.reason != "hint:memory" && row?.reason != "needed too much memory",
                    "an ordinary large file was marked as needing too much memory: reason \(row?.reason ?? "nil")")
        }
    }

    // MARK: the sampler thread

    @Test func theSamplerChecksOnItsOwnThreadAtTheInjectedInterval() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try wdAddPending(store, count: 1)
            let photo = try wdPhoto(store, "w-0001")
            try store.beginAttempt([photo])
            let testThread = pthread_mach_thread_np(pthread_self())

            // An interval of 0.1 s over 1 s is about 10 samples; 3 to 25 only rules out a stuck sampler and a busy loop.
            let footprint = WdFootprint(1_000_000)
            let exit = WdExit()
            let dog = wdMake(store, footprint, exit, interval: 0.1)
            dog.watch([photo])
            dog.start()
            Thread.sleep(forTimeInterval: 1.0)
            dog.stop()
            let calls = footprint.calls
            #expect((3...25).contains(calls), "an interval of 0.1 s gave \(calls) samples in 1 s, expected about 10")
            #expect(!footprint.callingThreads.contains(testThread), "the sampler ran on the test's own thread")
            #expect(footprint.callingThreads.count == 1, "the sampler used \(footprint.callingThreads.count) threads, expected one of its own")
            #expect(exit.count == 0, "exit was called below the cap")

            // A short interval gives many more samples in the same time: the interval is the one injected.
            let fast = WdFootprint(1_000_000)
            let quick = wdMake(store, fast, WdExit(), interval: 0.02)
            quick.watch([photo])
            quick.start()
            Thread.sleep(forTimeInterval: 0.6)
            quick.stop()
            #expect(fast.calls >= 5, "an interval of 0.02 s gave \(fast.calls) samples in 0.6 s, expected about 30")
        }
    }

    @Test func theDefaultIntervalIsAboutTwoHundredAndFiftyMilliseconds() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try wdAddPending(store, count: 1)
            let photo = try wdPhoto(store, "w-0001")
            try store.beginAttempt([photo])
            let footprint = WdFootprint(1_000_000)
            let dog = wdMake(store, footprint, WdExit())
            dog.watch([photo])
            dog.start()
            Thread.sleep(forTimeInterval: 1.3)
            dog.stop()
            // 250 ms over 1.3 s is 5 or 6 samples; 3 to 12 rules out a 1 s sampler and a busy loop.
            #expect((3...12).contains(footprint.calls), "the default interval gave \(footprint.calls) samples in 1.3 s, expected about 5")
        }
    }

    @Test func aTripFoundByTheSamplerThreadWritesTheHintAndCallsExit() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try wdAddPending(store, count: 2)
            let victim = try wdPhoto(store, "w-0002")
            try store.beginAttempt([victim])
            let path = wdIndexPath(t)
            let exit = WdExit { AtDB(path: path).flatMap(atRows)?["w-0002.jpg"] }
            let footprint = WdFootprint(wdCap + 50_000_000, first: [1_000_000, 2_000_000, 3_000_000])
            let dog = wdMake(store, footprint, exit, interval: 0.02)
            dog.watch([victim])
            dog.start()
            let deadline = Date().addingTimeInterval(10)
            while exit.count == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            dog.stop()

            #expect(exit.count >= 1, "the sampler never found the footprint at the cap within 10 s (\(footprint.calls) samples)")
            #expect(footprint.calls >= 4, "the trip came after \(footprint.calls) samples, but the first three were below the cap")
            let atExit = try #require(exit.rowsAtExit.first ?? nil, "exit was called with the row unreadable")
            #expect(atExit.reason == "hint:solo" && atExit.tries == 0, "when exit ran the row was reason \(atExit.reason ?? "nil") tries \(atExit.tries)")
            let row = wdRow(t, "w-0002")
            #expect(row?.status == "pending" && row?.reason == "hint:solo" && row?.tries == 0,
                    "after the sampler's trip: \(atDescribe(AtDB(path: path).flatMap(atRows)))")
        }
    }

    @Test func afterStopTheSamplerDoesNotCheckAgain() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try wdAddPending(store, count: 1)
            let photo = try wdPhoto(store, "w-0001")
            let footprint = WdFootprint(1_000_000)
            let dog = wdMake(store, footprint, WdExit(), interval: 0.02)
            dog.watch([photo])
            dog.start()
            Thread.sleep(forTimeInterval: 0.3)
            dog.stop()
            let atStop = footprint.calls
            #expect(atStop >= 2, "setup: the sampler took \(atStop) samples before stop")
            Thread.sleep(forTimeInterval: 0.4)
            #expect(footprint.calls <= atStop + 1, "the sampler kept checking after stop: \(atStop) samples at stop, \(footprint.calls) 0.4 s later")
        }
    }

    // MARK: through the built helper (SESAME_FAKE_EMBEDDER=1, a throwaway HOME)

    // The watchdog's own trip puts the first file into the state the store holds after a first trip (reason hint:solo,
    // tries 0); the restarted helper then reads that file alone and first. The oldest of 12 pending files is normally read
    // last, so it must be the first one written, ahead of all eleven others, and it ends done.
    @Test func afterAWatchdogTripTheRestartedHelperReadsThatFileFirstAndAloneAndItEndsDone() throws {
        let names = atNames("q", 1...12)
        let world = try atIndexedWorld(names)
        defer { world.remove() }
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0") == nil)
        try wdWithStore(world) { store in
            let exits = try wdReadAndTrip(store, "q-012")
            #expect(exits == 1, "the watchdog did not call exit once for q-012")
        }
        let tripped = world.db().flatMap(atRows)
        #expect(tripped?["q-012.jpg"]?.status == "pending" && tripped?["q-012.jpg"]?.reason == "hint:solo" && tripped?["q-012.jpg"]?.tries == 0,
                "setup: after the trip: \(atDescribe(tripped))")

        let wait = try wdRunHelper(world, until: { $0 == ["done": 12] })
        #expect(wait.met, "the twelve files did not all end done: \(wait.statuses)")

        let db = try #require(world.db())
        let after = try #require(atPassageIDs(db))
        let newest = before.values.flatMap { $0 }.max() ?? 0
        let order = after.compactMap { (name, ids) -> (String, Int)? in ids.min().map { (name, $0) } }.sorted { $0.1 < $1.1 }
        #expect(order.count == 12 && order.allSatisfy { $0.1 > newest }, "every file should have been read again (new ids above \(newest)): \(order)")
        #expect(order.first?.0 == "q-012.jpg",
                "the file the watchdog marked must be read before every other file, but the order of writes is \(order.map(\.0))")
        let rows = atRows(db)
        #expect(rows?["q-012.jpg"]?.status == "done" && rows?["q-012.jpg"]?.tries == 0, "q-012 ended \(atDescribe(rows))")
        #expect(rows?["q-012.jpg"]?.reason != "hint:memory" && rows?["q-012.jpg"]?.reason != "needed too much memory",
                "a file read alone within the cap was marked: reason \(rows?["q-012.jpg"]?.reason ?? "nil")")
        #expect(rows?.values.allSatisfy { $0.tries == 0 } == true, "every row should end with tries 0: \(atDescribe(rows))")
        #expect(atWholeProblems(db).isEmpty, "the index is not whole: \(atWholeProblems(db))")
    }

    // Three runs that trip: the first (solo hint), the solo read (hint:memory, tries 1), the read once more (tries 2). The
    // next helper ends the file as could_not_read "needed too much memory" without reading it, and finishes the rest.
    @Test func afterTheTripsOfTheSoloReadAndTheReadOnceMoreTheNextHelperEndsTheFileCouldNotReadNeededTooMuchMemory() throws {
        let names = atNames("q", 1...12)
        let world = try atIndexedWorld(names)
        defer { world.remove() }
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0") == nil)
        try wdWithStore(world) { store in
            for run in 1...3 {
                let exits = try wdReadAndTrip(store, "q-012")
                #expect(exits == 1, "run \(run): the watchdog did not call exit once for q-012")
            }
        }
        let tripped = world.db().flatMap(atRows)
        #expect(tripped?["q-012.jpg"]?.status == "pending" && tripped?["q-012.jpg"]?.reason == "hint:memory" && tripped?["q-012.jpg"]?.tries == 2,
                "setup: after three tripping runs: \(atDescribe(tripped))")

        let wait = try wdRunHelper(world, until: { $0 == ["done": 11, "could_not_read": 1] })
        #expect(wait.met, "expected 11 done and 1 could_not_read, got \(wait.statuses)")

        let db = try #require(world.db())
        let rows = atRows(db)
        #expect(rows?["q-012.jpg"]?.status == "could_not_read" && rows?["q-012.jpg"]?.reason == "needed too much memory",
                "q-012 must end could_not_read with reason needed too much memory, got \(atDescribe(rows))")
        #expect(rows?.values.allSatisfy { $0.tries == 0 } == true, "every row should end with tries 0: \(atDescribe(rows))")
        let after = try #require(atPassageIDs(db))
        #expect(Set(after["q-012.jpg"] ?? []).isSubset(of: Set(before["q-012.jpg"] ?? [])),
                "q-012.jpg was read again: ids \(before["q-012.jpg"] ?? []) then \(after["q-012.jpg"] ?? [])")
        for name in names.map({ $0 + ".jpg" }) where name != "q-012.jpg" {
            #expect(after[name] != nil && after[name] != before[name], "\(name) was pending and was not read")
        }
        #expect(atWholeProblems(db).isEmpty, "the index is not whole: \(atWholeProblems(db))")
    }

    // An ordinary large photo, read alone because the row holds hint:solo, with the real watchdog running in the helper and
    // the real footprint far under the cap: it ends done with tries 0 and is never marked.
    @Test func anOrdinaryLargePhotoReadAloneByTheHelperIsNeverMarked() throws {
        _ = atHelperWarm
        let world = try AtWorld()
        defer { world.remove() }
        try atMakePhotos(in: world.photos, names: atNames("s", 1...5), seedBase: 100)
        try wdLargePhoto(world.photos.appendingPathComponent("big-001.jpg"), side: 2000, seed: 777,
                         modified: Date(timeIntervalSince1970: atPast - 1000))

        var wait = try wdRunHelper(world, until: { $0 == ["done": 6] })
        #expect(wait.met, "the five small photos and the large one did not all end done: \(wait.statuses)")
        let first = try #require(world.db().flatMap(atRows), "setup: the index cannot be read")
        #expect(first.values.allSatisfy { $0.status == "done" && $0.tries == 0 && $0.reason != "needed too much memory" && $0.reason != "hint:memory" },
                "after the first run: \(atDescribe(first))")
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")

        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0, reason = 'hint:solo' where path like '%/big-001.jpg'") == nil)
        wait = try wdRunHelper(world, until: { $0 == ["done": 6] })
        #expect(wait.met, "the large photo did not end done after its solo read: \(wait.statuses)")

        let db = try #require(world.db())
        let rows = atRows(db)
        #expect(rows?["big-001.jpg"]?.status == "done" && rows?["big-001.jpg"]?.tries == 0, "the large photo ended \(atDescribe(rows))")
        #expect(rows?["big-001.jpg"]?.reason != "hint:memory" && rows?["big-001.jpg"]?.reason != "needed too much memory",
                "the large photo was marked: reason \(rows?["big-001.jpg"]?.reason ?? "nil")")
        let after = try #require(atPassageIDs(db))
        #expect(after["big-001.jpg"] != nil && after["big-001.jpg"] != before["big-001.jpg"], "the large photo was not read again: ids \(before["big-001.jpg"] ?? []) then \(after["big-001.jpg"] ?? [])")
        for name in atNames("s", 1...5).map({ $0 + ".jpg" }) {
            #expect(after[name] == before[name], "\(name) was done and was read again")
        }
        #expect(atWholeProblems(db).isEmpty, "the index is not whole: \(atWholeProblems(db))")
    }
}
}
