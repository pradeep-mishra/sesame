import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SQLite3
import Testing
import Vision

// plan-1-t33, tester step. Written from the t33 entry, the Helper protocol table of the plan's Conventions and
// design sections 1, 2, 3 and 8 only; no product source read.
//
// These tests start the helper the way the app does (`SesameHelper index`, `HOME` at a throwaway folder, the fake
// embedder), send hand-written command lines on its stdin and read the JSON lines on its stdout. The index is looked
// at with this file's own read-only SQLite connection and with `FileManager`, so what is checked is what is on disk.
// Expected values come from this file's own inputs (the photos it draws, the counts it asked for), never from the
// code under test. The suite is nested in `EncodeHelperTests` (Reading.swift), so no other helper suite runs beside it.
//
// What the entry fixes, and how each clause is observed from outside:
// - "a `reset` line cancels any batch in flight, closes the connection and leaves no index.sqlite, index.sqlite-wal
//   or index.sqlite-shm": the three paths are polled until none exists and then watched for 3 more seconds (a batch
//   not cancelled would write again and bring a file back); `lsof` of the helper must list no index.sqlite after.
//   "deleted through SesameFolder.delete" is not observable from a process boundary: the static rule is Run line 2.
// - "a following `folders` line indexes the 40 photos again": same helper process, same folder, all 40 `done`, the
//   index whole, a `walked` event comes (a new index has no walk_done_at, so the walk reports again).
// - "a `panel` line with open true is answered by a `unit` event with size 4 and with open false by size 16": one
//   `unit` event per `panel` line, in order.
// - "a photo batch embedded between them uses no unit larger than the size in force (read from index.log `unit n=`
//   events)": panel open for a whole run, then closed for a whole run; each run's slice of the log (taken by line
//   offset) holds only typed `unit n=<k>` lines, each k from 1 to the size in force, adding up to the run's inputs.
//   The fake embedder goes per file, so a unit may hold fewer inputs than the size: only the ceiling is asserted,
//   plus a floor on the number of units that the ceiling itself forces (inputs / size, rounded up).

// MARK: raw read-only SQLite, independent of the product

private final class T33DB {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close_v2(db) }

    /// Every row as text (nil for NULL), or nil when the statement cannot run.
    func rows(_ sql: String) -> [[String?]]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var out: [[String?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            var row: [String?] = []
            for column in 0..<sqlite3_column_count(statement) {
                if sqlite3_column_type(statement, column) == SQLITE_NULL {
                    row.append(nil)
                } else if let text = sqlite3_column_text(statement, column) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }
            out.append(row)
        }
        return out
    }

    func int(_ sql: String) -> Int? {
        guard let result = rows(sql), let row = result.first, let cell = row.first, let text = cell else { return nil }
        return Int(text)
    }

    func integrity() -> String {
        guard let result = rows("pragma integrity_check") else { return "integrity_check could not run" }
        return result.compactMap { $0.first ?? nil }.joined(separator: " | ")
    }
}

/// What is wrong with an index that should hold `photos` finished photos: every file `done` with exactly one `name`
/// and one `image` passage, no other passage, nothing pending. Empty means whole.
private func t33Problems(_ db: T33DB, photos: Int) -> [String] {
    var problems: [String] = []
    guard let files = db.rows("""
        select f.path, f.status, coalesce(sum(p.source = 'name'), 0), coalesce(sum(p.source = 'image'), 0), count(p.id) \
        from files f left join passages p on p.file_id = f.id group by f.id
        """) else { return ["the files and passages tables cannot be read"] }
    if files.count != photos { problems.append("\(files.count) files rows, expected \(photos)") }
    for row in files {
        let name = ((row[0] ?? "") as NSString).lastPathComponent
        let status = row[1] ?? "nil"
        let names = Int(row[2] ?? "") ?? -1, images = Int(row[3] ?? "") ?? -1, all = Int(row[4] ?? "") ?? -1
        if status != "done" {
            problems.append("\(name): status \(status), expected done")
        } else if names != 1 || images != 1 || all != 2 {
            problems.append("\(name): \(names) name and \(images) image passages of \(all), expected 1, 1 and 2")
        }
    }
    let passages = db.int("select count(*) from passages") ?? -1
    if passages != 2 * photos { problems.append("\(passages) passages, expected \(2 * photos)") }
    let integrity = db.integrity()
    if integrity != "ok" { problems.append("integrity_check: \(integrity)") }
    return problems
}

// MARK: drawing the photos

private func t33Noise(seed: Int, side: Int) -> CGImage? {
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    var state = UInt64(truncatingIfNeeded: seed) &* 2_654_435_761 &+ 12_345
    for index in stride(from: 0, to: pixels.count, by: 4) {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        pixels[index] = UInt8(truncatingIfNeeded: state >> 33)
        pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 41)
        pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 49)
        pixels[index + 3] = 255
    }
    return pixels.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
}

private let t33Past = Date().timeIntervalSince1970.rounded(.down) - 3600

private let t33Words = [
    "amber", "basalt", "cedar", "dune", "ember", "fjord", "glacier", "harbor", "island", "jungle",
    "kelp", "lagoon", "meadow", "nebula", "orchid", "prairie", "quartz", "ridge", "savanna", "tundra",
    "umber", "valley", "willow", "xenon", "yarrow", "zenith", "alpine", "bramble", "canyon", "delta",
    "estuary", "fern", "grove", "heron", "iris", "juniper", "kestrel", "lotus", "moss", "nimbus",
]

/// `count` noise JPEGs in `directory`, one distinct picture and one word-and-number name each, an hour or more old.
private func t33MakePhotos(in directory: URL, count: Int, seedBase: Int = 0, side: Int = 160) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for number in 1...count {
        let url = directory.appendingPathComponent(
            String(format: "%@-%03d.jpg", t33Words[(number - 1) % t33Words.count], number + seedBase))
        let data = NSMutableData()
        guard let image = t33Noise(seed: number + seedBase, side: side),
              let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            Issue.record("the test could not draw \(url.lastPathComponent)")
            continue
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        try (data as Data).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: t33Past - Double(number + seedBase))], ofItemAtPath: url.path)
    }
}

// MARK: the throwaway world and the helper

private final class T33World {
    let root: URL
    let home: URL
    let photos: URL

    var support: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var indexFile: String { support.appendingPathComponent("index.sqlite").path }
    var indexLog: URL { sesameLogURL(support, "index.log") }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sesame-t33-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        photos = root.appendingPathComponent("photos", isDirectory: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        // The app makes this folder (mode 0700) before it ever starts a helper.
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Which of the three index files exist right now (names only), by path, never by opening one.
    func indexFilesPresent() -> [String] {
        ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm"].filter {
            FileManager.default.fileExists(atPath: support.appendingPathComponent($0).path)
        }
    }
}

/// The first text recognition on a Mac compiles its model (tens of seconds, kept for later processes); do it once
/// here so a helper's first photo is not mistaken for a stall.
private func t33WarmImage() -> CGImage? {
    let width = 600, height = 200
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 90, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.textPosition = CGPoint(x: 20, y: 60)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "WARM UP 0123", attributes: attributes)), context)
    return context.makeImage()
}

private let t33VisionWarm: Bool = {
    guard let image = t33WarmImage() else { return false }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return true
}()

/// Warming the test process does not warm the helper: the first text recognition in a freshly signed helper binary
/// compiles its model again, about 35 s measured (finding F19). Once per test process, one photo with text goes
/// through a real helper first, with up to 120 s allowed for it (cap 150 s); the tests' own stall limits then start
/// from a warm binary. The throwaway world is its own and nothing is asserted: a helper that never warms makes the
/// real test fail with its own message.
private let t33HelperWarm: Bool = {
    guard let world = try? T33World(), let image = t33WarmImage() else { return false }
    defer { world.remove() }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    let photo = world.photos.appendingPathComponent("warm-up-000.jpg")
    guard (try? (data as Data).write(to: photo)) != nil,
          (try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t33Past)],
                                                  ofItemAtPath: photo.path)) != nil,
          let helper = try? t33StartHelper(world) else { return false }
    defer { helper.stop() }
    helper.send(t33FoldersLine([world.photos]))
    return t33WaitDone(world, helper, target: 1, stall: 120, cap: 150).done >= 1
}()

private func t33WithWorld(_ body: (T33World) throws -> Void) throws {
    _ = t33VisionWarm
    _ = t33HelperWarm
    let world = try T33World()
    defer { world.remove() }
    try body(world)
}

private func t33StartHelper(_ world: T33World) throws -> HelperProcess {
    let executable = try #require(KitPaths.debugHelper(),
                                  "debug SesameHelper not found next to the test bundle or in .build/debug")
    homeLock.lock()
    defer { homeLock.unlock() }
    let previousHome = getenv("HOME").map { String(cString: $0) }
    let previousFake = getenv("SESAME_FAKE_EMBEDDER").map { String(cString: $0) }
    setenv("HOME", world.home.path, 1)
    setenv("SESAME_FAKE_EMBEDDER", "1", 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        if let previousFake { setenv("SESAME_FAKE_EMBEDDER", previousFake, 1) } else { unsetenv("SESAME_FAKE_EMBEDDER") }
    }
    return try HelperProcess(executable: executable, arguments: ["index"])
}

private func t33JSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

/// The hand-written `folders` line of the Helper protocol table: the whole list, `code` false.
private func t33FoldersLine(_ folders: [URL]) -> String {
    let items = folders.map { "{\"path\":\(t33JSONString($0.path)),\"code\":false}" }.joined(separator: ",")
    return "{\"cmd\":\"folders\",\"folders\":[\(items)]}"
}

private let t33Reset = "{\"cmd\":\"reset\"}"
private func t33Panel(open: Bool) -> String { "{\"cmd\":\"panel\",\"open\":\(open ? "true" : "false")}" }

// MARK: waiting, from outside

private struct T33Wait {
    let done: Int
    let seconds: Double
    let helperRunning: Bool

    func why(_ helper: HelperProcess) -> String {
        "\(done) files reached done after \(Int(seconds)) s, helper \(helperRunning ? "still running" : "exited"), stderr: \(helper.errors)"
    }
}

/// Polls the index (a fresh read-only connection each time, so none is held open) until at least `target` files are
/// `done`, until nothing has changed for `stall` seconds, until `cap` seconds in all, or until the helper is gone.
private func t33WaitDone(_ world: T33World, _ helper: HelperProcess, target: Int, interval: TimeInterval = 0.05,
                         stall: TimeInterval = 60, cap: TimeInterval = 300) -> T33Wait {
    let started = Date()
    var lastChange = started
    var last = -1
    while true {
        if let db = T33DB(path: world.indexFile), let done = db.int("select count(*) from files where status = 'done'") {
            if done != last { last = done; lastChange = Date() }
            if done >= target { break }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > stall || now.timeIntervalSince(started) > cap { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.2); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: interval)
    }
    return T33Wait(done: max(last, 0), seconds: Date().timeIntervalSince(started), helperRunning: helper.isRunning)
}

/// Reads and discards what the helper has written until it has been quiet for `quiet` seconds.
private func t33Drain(_ helper: HelperProcess, quiet: TimeInterval = 1) {
    while helper.nextLine(timeout: quiet) != nil {}
}

/// Reads lines until a `walked` event, for at most `timeout` seconds.
private func t33WaitWalked(_ helper: HelperProcess, timeout: TimeInterval = 120) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard let line = helper.nextLine(timeout: 1) else { if helper.isRunning { continue } else { return false } }
        if HelperReply(line.text)?.event == "walked" { return true }
    }
    return false
}

/// The size of the next `unit` event within `timeout` seconds (other events are skipped), or nil.
private func t33NextUnit(_ helper: HelperProcess, timeout: TimeInterval = 30) -> Int? {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let left = deadline.timeIntervalSinceNow
        if left <= 0 { return nil }
        guard let line = helper.nextLine(timeout: left) else { return nil }
        guard let reply = HelperReply(line.text), reply.event == "unit" else { continue }
        guard let size = (reply.object["size"] as? NSNumber), size.doubleValue == size.doubleValue.rounded() else {
            Issue.record("a `unit` event without a whole-number size: \(line.text.prefix(200))")
            return -1
        }
        return size.intValue
    }
}

private func t33LogLines(_ world: T33World) -> [String] {
    guard let text = try? String(contentsOf: world.indexLog, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

/// The k's of the `unit n=<k>` lines, or the lines that are not exactly that.
private func t33Units(_ lines: [String]) -> (units: [Int], odd: [String]) {
    var units: [Int] = []
    var odd: [String] = []
    for line in lines {
        let parts = line.split(separator: "=", omittingEmptySubsequences: false)
        if parts.count == 2, parts[0] == "unit n", !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
           let k = Int(parts[1]) {
            units.append(k)
        } else {
            odd.append(line)
        }
    }
    return (units, odd)
}

/// The unit rule for one run's slice of `index.log`: typed lines only, each k from 1 to `size`, adding up to `inputs`
/// (one image per photo), and no fewer units than `inputs / size` rounded up, which the ceiling itself forces.
private func t33CheckUnits(_ lines: [String], size: Int, inputs: Int, _ label: String) {
    let parsed = t33Units(lines)
    #expect(parsed.odd.isEmpty, "\(label): index.log holds lines that are not `unit n=<k>`: \(parsed.odd.prefix(3))")
    #expect(!parsed.units.isEmpty, "\(label): index.log holds no unit line for this run")
    let tooBig = parsed.units.filter { !(1...size).contains($0) }
    #expect(tooBig.isEmpty, "\(label): a unit is larger than the size in force (\(size)): n values \(tooBig)")
    #expect(parsed.units.reduce(0, +) == inputs,
            "\(label): the units add up to \(parsed.units.reduce(0, +)) inputs, expected \(inputs) (one image per photo); units \(parsed.units)")
    #expect(parsed.units.count >= (inputs + size - 1) / size,
            "\(label): \(parsed.units.count) units cannot hold \(inputs) inputs at \(size) a unit")
}

// MARK: the tests

extension EncodeHelperTests {
@Suite("IndexResetTests", .serialized)
struct IndexResetTests {

    // MARK: reset

    @Test func aResetLineDeletesTheIndexFilesAndAFollowingFoldersLineIndexesThe40PhotosAgain() throws {
        try t33WithWorld { world in
            try t33MakePhotos(in: world.photos, count: 40)
            let helper = try t33StartHelper(world)
            defer { helper.stop() }
            let folders = t33FoldersLine([world.photos])
            helper.send(folders)
            let first = t33WaitDone(world, helper, target: 40)
            #expect(first.done == 40, "rows stay pending before the reset: \(first.why(helper))")
            guard first.done == 40 else { return }
            #expect(FileManager.default.fileExists(atPath: world.indexFile), "no index.sqlite before the reset")
            t33Drain(helper)

            helper.send(t33Reset)
            let deadline = Date().addingTimeInterval(15)
            var left = world.indexFilesPresent()
            while !left.isEmpty, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                left = world.indexFilesPresent()
            }
            #expect(left.isEmpty, "15 s after `reset` these files are still there: \(left)")
            guard left.isEmpty else { return }
            #expect(helper.isRunning, "the helper exited on `reset`; stderr: \(helper.errors)")

            // Nothing comes back by itself, and the helper holds no connection to the deleted index.
            Thread.sleep(forTimeInterval: 2)
            #expect(world.indexFilesPresent().isEmpty, "an index file came back after `reset`: \(world.indexFilesPresent())")
            let open = Tools.capture("/usr/sbin/lsof", ["-n", "-P", "-p", String(helper.pid)])?.output ?? ""
            #expect(!open.contains("index.sqlite"), "after `reset` the helper still holds a connection to the index: \(open.split(separator: "\n").filter { $0.contains("index.sqlite") })")

            // The same folders line indexes the same 40 photos again, from nothing.
            t33Drain(helper)
            helper.send(folders)
            #expect(t33WaitWalked(helper), "no `walked` event after the folders line that followed `reset`; stderr: \(helper.errors)")
            let again = t33WaitDone(world, helper, target: 40)
            #expect(again.done == 40, "after `reset` and a folders line, rows stay pending: \(again.why(helper))")
            if let db = T33DB(path: world.indexFile) {
                let problems = t33Problems(db, photos: 40)
                #expect(problems.isEmpty, "the new index is not whole: \(problems.count) problems, first: \(problems.prefix(3))")
            } else {
                Issue.record("no index.sqlite after the folders line that followed `reset`")
            }
        }
    }

    @Test func aResetLineSentWhileABatchIsInFlightCancelsItAndLeavesNoIndexFiles() throws {
        try t33WithWorld { world in
            let total = 120
            try t33MakePhotos(in: world.photos, count: total)
            let helper = try t33StartHelper(world)
            defer { helper.stop() }
            let folders = t33FoldersLine([world.photos])
            helper.send(folders)

            // Reset as soon as a few photos are done and many are not.
            let midway = t33WaitDone(world, helper, target: 3, interval: 0.005)
            #expect(midway.done >= 3, "the work never got going before the reset: \(midway.why(helper))")
            guard midway.done >= 3 else { return }
            #expect(midway.done < total, "all \(total) photos were done before `reset` could be sent mid-batch; this run proves nothing")
            helper.send(t33Reset)

            let deadline = Date().addingTimeInterval(15)
            var left = world.indexFilesPresent()
            while !left.isEmpty, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                left = world.indexFilesPresent()
            }
            #expect(left.isEmpty, "15 s after `reset` (sent with \(midway.done) of \(total) photos done) these files are still there: \(left)")
            guard left.isEmpty else { return }
            #expect(helper.isRunning, "the helper exited on `reset`; stderr: \(helper.errors)")

            // A batch that was not cancelled would write again: watch for 3 s, by path only.
            let watchUntil = Date().addingTimeInterval(3)
            var returned: [String] = []
            while Date() < watchUntil {
                returned = world.indexFilesPresent()
                if !returned.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            #expect(returned.isEmpty, "the batch in flight was not cancelled: \(returned) came back after `reset`")
            guard returned.isEmpty else { return }

            // From nothing, the same folders line indexes every photo, once each: no row of the cancelled batch.
            t33Drain(helper)
            helper.send(folders)
            let again = t33WaitDone(world, helper, target: total)
            #expect(again.done == total, "after the cancelled batch and a folders line, rows stay pending: \(again.why(helper))")
            if let db = T33DB(path: world.indexFile) {
                let problems = t33Problems(db, photos: total)
                #expect(problems.isEmpty, "the new index is not whole: \(problems.count) problems, first: \(problems.prefix(3))")
            } else {
                Issue.record("no index.sqlite after the folders line that followed `reset`")
            }
        }
    }

    // MARK: panel and unit

    @Test func aPanelLineWithOpenTrueIsAnsweredByUnitSize4AndWithOpenFalseBySize16() throws {
        try t33WithWorld { world in
            let helper = try t33StartHelper(world)
            defer { helper.stop() }
            helper.send(t33Panel(open: true))
            let opened = t33NextUnit(helper)
            #expect(opened != nil, "no `unit` event answered {\"cmd\":\"panel\",\"open\":true}; stderr: \(helper.errors)")
            #expect(opened == 4, "{\"cmd\":\"panel\",\"open\":true} was answered by a unit of size \(String(describing: opened)), expected 4")
            helper.send(t33Panel(open: false))
            let closed = t33NextUnit(helper)
            #expect(closed != nil, "no `unit` event answered {\"cmd\":\"panel\",\"open\":false}; stderr: \(helper.errors)")
            #expect(closed == 16, "{\"cmd\":\"panel\",\"open\":false} was answered by a unit of size \(String(describing: closed)), expected 16")
        }
    }

    @Test func everyPanelLineIsAnsweredByExactlyOneUnitEventInOrder() throws {
        try t33WithWorld { world in
            let helper = try t33StartHelper(world)
            defer { helper.stop() }
            let opens = [true, false, true, true, false]
            for open in opens { helper.send(t33Panel(open: open)) }
            var sizes: [Int?] = []
            for _ in opens { sizes.append(t33NextUnit(helper)) }
            #expect(sizes == opens.map { $0 ? 4 : 16 }, "five panel lines open \(opens) were answered by unit sizes \(sizes), expected 4, 16, 4, 4, 16")
            #expect(t33NextUnit(helper, timeout: 1) == nil, "a sixth `unit` event came after five `panel` lines")
        }
    }

    // MARK: the lever on a photo batch

    @Test func aPhotoBatchEmbeddedWhilePanelIsOpenUsesNoUnitLargerThan4AndWhileClosedNoLargerThan16() throws {
        try t33WithWorld { world in
            let folderA = world.photos.appendingPathComponent("a", isDirectory: true)
            let folderB = world.photos.appendingPathComponent("b", isDirectory: true)
            try t33MakePhotos(in: folderA, count: 40)
            try t33MakePhotos(in: folderB, count: 40, seedBase: 1000)
            let helper = try t33StartHelper(world)
            defer { helper.stop() }

            // Panel open for the whole of the first run: 40 inputs, no unit larger than 4.
            helper.send(t33Panel(open: true))
            #expect(t33NextUnit(helper) == 4, "the panel line did not answer a unit of size 4")
            helper.send(t33FoldersLine([folderA]))
            let first = t33WaitDone(world, helper, target: 40)
            #expect(first.done == 40, "rows stay pending with the panel open: \(first.why(helper))")
            guard first.done == 40 else { return }
            Thread.sleep(forTimeInterval: 1)
            let openLog = t33LogLines(world)
            t33CheckUnits(openLog, size: 4, inputs: 40, "panel open, 40 photos")

            // Panel closed for the whole of the second run: 40 more inputs, no unit larger than 16.
            helper.send(t33Panel(open: false))
            #expect(t33NextUnit(helper) == 16, "the panel line did not answer a unit of size 16")
            helper.send(t33FoldersLine([folderA, folderB]))
            let second = t33WaitDone(world, helper, target: 80)
            #expect(second.done == 80, "rows stay pending with the panel closed: \(second.why(helper))")
            guard second.done == 80 else { return }
            Thread.sleep(forTimeInterval: 1)
            let closedLog = Array(t33LogLines(world).dropFirst(openLog.count))
            t33CheckUnits(closedLog, size: 16, inputs: 40, "panel closed, 40 more photos")

            if let db = T33DB(path: world.indexFile) {
                let problems = t33Problems(db, photos: 80)
                #expect(problems.isEmpty, "the index is not whole: \(problems.count) problems, first: \(problems.prefix(3))")
            }
        }
    }
}
}
