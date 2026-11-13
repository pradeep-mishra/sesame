import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SQLite3
import Testing
import Vision

// plan-1-t34, tester step. Written from the t34 entry, the Helper protocol table of the plan's Conventions and
// design sections 1, 2, 3, 8 and 12 only; no product source read.
//
// These tests start the helper the way the app does: `SesameHelper index` with `HOME` and `TMPDIR` pointing at a
// throwaway folder and `SESAME_FAKE_EMBEDDER=1` (a preview loads no model), send hand-written `folders` and `preview`
// lines on its stdin and read the JSON lines it writes on stdout. The index is looked at with this file's own
// read-only SQLite connection, so what is waited for is what is on disk. Expected values come from this file's own
// inputs (the photos it draws, their sizes in pixels, the times it sets) and from `stat` of the files it made, never
// from the code under test. The suite is nested in `EncodeHelperTests` (Reading.swift), so no other helper suite runs
// beside it.
//
// What the entry fixes, and how each clause is observed from outside:
// - "a `preview` request for one indexed photo returns the preview reply with status ok and a PNG path under
//   $TMPDIR/Sesame-<pid> that decodes to at most pane size, plus the name, kind photo, size equal to stat and mtime
//   equal to the modified time the test reads": the reply fields, the PNG decoded with ImageIO. The pane is part of
//   the 960 x 560 panel (design notes 3: list 40%, pane 60%), so its largest possible size is the whole panel at 2x
//   scale, 1920 x 1120 pixels [guess: the entry does not give the number]. The test also asks for a picture that is
//   reduced from a 4000 x 3000 original and not a thumbnail (longest side of at least 400 pixels), and the original
//   proportions kept within 2 per cent [guess: "decoded to pane size" read as a fit, not a crop].
// - "a deleted file gives status gone": `png`, `size` and `mtime` are JSON null (the Helper protocol table).
// - "a file edited after indexing (size changed) gives status changed": the same shape as ok, with the current size,
//   the current time, and a PNG of the current content (the test rewrites a landscape picture as a portrait one).
// - "a path no longer admitted gives gone": a folder taken out of the `folders` list (the file is still on disk), a
//   photo in a folder that was never picked, and a never-read key name inside a picked folder (design section 1).
// - "a newer selection cancels an older one": six large photos, six `preview` lines in one write; the newest is
//   answered, no older ticket is answered after it, and at least one older ticket is never answered.
// - "the scratch folder is mode 0600 files, removed at exit": `$TMPDIR/Sesame-<pid>` holds the PNG with mode 0600
//   and is gone once the helper has exited at stdin EOF.

// MARK: shared by PreviewReaderTests and IndexPhotoBatchFootprintReadingTests

/// The pane's largest size in pixels: the 960 x 560 panel at 2x scale.
let t34PaneMaxWidth = 1920
let t34PaneMaxHeight = 1120

/// An hour or more in the past, so no "modified a moment ago" wait applies.
let t34Past = Date().timeIntervalSince1970.rounded(.down) - 3600

final class T34DB {
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

    func int(_ sql: String) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// `files` rows per status in one statement, e.g. ["done": 12, "pending": 28]; nil when it cannot be read.
    func statuses() -> [String: Int]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select status, count(*) from files group by status", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var out: [String: Int] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            if let text = sqlite3_column_text(statement, 0) { out[String(cString: text)] = Int(sqlite3_column_int64(statement, 1)) }
        }
        return out
    }
}

final class T34World {
    let root: URL
    let home: URL
    let photos: URL
    let tmp: URL

    var support: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var indexFile: String { support.appendingPathComponent("index.sqlite").path }

    /// The scratch folder of a helper: `$TMPDIR/Sesame-<pid>` (design section 1).
    func scratch(pid: Int32) -> URL { tmp.appendingPathComponent("Sesame-\(pid)", isDirectory: true) }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sesame-t34-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        photos = root.appendingPathComponent("photos", isDirectory: true)
        tmp = root.appendingPathComponent("tmp", isDirectory: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        // The app makes this folder (mode 0700) before it ever starts a helper.
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// The first text recognition on a Mac compiles its model, which takes tens of seconds and is kept for every later
/// process. The test does it once itself, so a helper's first photo is not mistaken for a stall.
private func t34WarmImage() -> CGImage? {
    let width = 1500, height = 500
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 190, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.textPosition = CGPoint(x: 80, y: 150)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "WARM UP 0123", attributes: attributes)), context)
    return context.makeImage()
}

private let t34VisionWarm: Bool = {
    guard let image = t34WarmImage() else { return false }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return true
}()

/// Warming the test process does not warm the helper: the first text recognition in a freshly signed helper binary
/// compiles its model again, about 35 s measured (finding F19). Once per test process, one photo with text goes
/// through a real helper first, with up to 120 s allowed for it (cap 150 s); the tests' own stall limits and 30 s
/// reply waits then start from a warm binary. The throwaway world is its own and nothing is asserted: a helper that
/// never warms makes the real test fail with its own message.
private let t34HelperWarm: Bool = {
    guard let world = try? T34World(), let image = t34WarmImage() else { return false }
    defer { world.remove() }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    let photo = world.photos.appendingPathComponent("warm-up-000.jpg")
    guard (try? (data as Data).write(to: photo)) != nil,
          (try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t34Past)],
                                                  ofItemAtPath: photo.path)) != nil,
          let helper = try? t34StartHelper(world) else { return false }
    defer { helper.stop() }
    helper.send(t34FoldersLine([world.photos]))
    return t34WaitDone(world, helper, total: 1, stall: 120, cap: 150).reachedAll
}()

func t34WithWorld(_ body: (T34World) throws -> Void) throws {
    _ = t34VisionWarm
    _ = t34HelperWarm
    let world = try T34World()
    defer { world.remove() }
    try body(world)
}

/// Starts a helper process with `HOME` and `TMPDIR` pointing into the world. `fake` sets `SESAME_FAKE_EMBEDDER=1`
/// (no model); otherwise the variable is removed. With no `executable` it is the debug helper `swift test` builds.
func t34StartHelper(_ world: T34World, executable: URL? = nil, arguments: [String] = ["index"],
                    fake: Bool = true) throws -> HelperProcess {
    let url: URL
    if let executable {
        url = executable
    } else {
        url = try #require(KitPaths.debugHelper(),
                           "debug SesameHelper not found next to the test bundle or in .build/debug")
    }
    homeLock.lock()
    defer { homeLock.unlock() }
    let previousHome = getenv("HOME").map { String(cString: $0) }
    let previousTmp = getenv("TMPDIR").map { String(cString: $0) }
    let previousFake = getenv("SESAME_FAKE_EMBEDDER").map { String(cString: $0) }
    setenv("HOME", world.home.path, 1)
    setenv("TMPDIR", world.tmp.path + "/", 1)
    if fake { setenv("SESAME_FAKE_EMBEDDER", "1", 1) } else { unsetenv("SESAME_FAKE_EMBEDDER") }
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        if let previousTmp { setenv("TMPDIR", previousTmp, 1) } else { unsetenv("TMPDIR") }
        if let previousFake { setenv("SESAME_FAKE_EMBEDDER", previousFake, 1) } else { unsetenv("SESAME_FAKE_EMBEDDER") }
    }
    return try HelperProcess(executable: url, arguments: arguments)
}

private func t34JSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

/// The hand-written `folders` line of the Helper protocol table: the whole list, `code` false.
func t34FoldersLine(_ folders: [URL]) -> String {
    let items = folders.map { "{\"path\":\(t34JSONString($0.path)),\"code\":false}" }.joined(separator: ",")
    return "{\"cmd\":\"folders\",\"folders\":[\(items)]}"
}

/// The hand-written `preview` line of the Helper protocol table; `passage` is null.
func t34PreviewLine(ticket: Int, file: String, query: String = "a dog on the beach") -> String {
    "{\"cmd\":\"preview\",\"ticket\":\(ticket),\"file\":\(t34JSONString(file)),\"passage\":null,\"query\":\(t34JSONString(query))}"
}

extension HelperReply {
    var previewTicket: Int? { (object["ticket"] as? NSNumber)?.intValue }
    var previewStatus: String? { object["status"] as? String }
    var previewPng: String? { object["png"] as? String }
    var previewName: String? { object["name"] as? String }
    var previewKind: String? { object["kind"] as? String }
    var previewSize: Int64? { (object["size"] as? NSNumber)?.int64Value }
    var previewMtime: Int64? { (object["mtime"] as? NSNumber)?.int64Value }
    /// True when the key is present and is JSON null (not missing, not a value).
    func isNull(_ key: String) -> Bool { object[key] is NSNull }
}

/// Waits for the preview reply of `ticket`, skipping every other line (`changed`, `walked`, `unit`, other tickets).
func t34WaitPreview(_ helper: HelperProcess, ticket: Int, timeout: TimeInterval) -> (reply: HelperReply, at: Date)? {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let left = deadline.timeIntervalSinceNow
        if left <= 0 { return nil }
        guard let line = helper.nextLine(timeout: left) else { return nil }
        guard let reply = HelperReply(line.text), reply.event != nil else {
            Issue.record("a line from the helper is not one JSON object with an `event`: \(line.text.prefix(200))")
            continue
        }
        if reply.event == "preview", reply.previewTicket == ticket { return (reply, line.at) }
    }
}

/// Sends one `preview` line and waits for its reply (nil: none came in time).
func t34Ask(_ helper: HelperProcess, ticket: Int, file: String, timeout: TimeInterval = 30) -> (reply: HelperReply, at: Date)? {
    helper.send(t34PreviewLine(ticket: ticket, file: file))
    return t34WaitPreview(helper, ticket: ticket, timeout: timeout)
}

// MARK: waiting for the index, from outside

struct T34Wait {
    let done: Int
    let total: Int
    let statuses: [String: Int]
    let seconds: Double
    let helperRunning: Bool
    var reachedAll: Bool { done == total }

    func why(_ helper: HelperProcess) -> String {
        "\(done) of \(total) files reached done after \(Int(seconds)) s, statuses \(statuses.isEmpty ? "none (no files rows)" : "\(statuses)"), helper \(helperRunning ? "still running" : "exited"), stderr: \(helper.errors)"
    }
}

/// Polls the index until `total` files are `done`, until nothing has changed for `stall` seconds, until `cap`
/// seconds in all, or until the helper is gone and nothing more can come.
func t34WaitDone(_ world: T34World, _ helper: HelperProcess, total: Int,
                 stall: TimeInterval = 90, cap: TimeInterval = 300) -> T34Wait {
    let started = Date()
    var lastChange = started
    var lastDone = -1
    var db: T34DB?
    var statuses: [String: Int] = [:]
    while true {
        if db == nil { db = T34DB(path: world.indexFile) }
        if let found = db?.statuses() {
            statuses = found
            let done = found["done"] ?? 0
            if done != lastDone { lastDone = done; lastChange = Date() }
            if done == total { break }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > stall || now.timeIntervalSince(started) > cap { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.2); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return T34Wait(done: max(lastDone, 0), total: total, statuses: statuses,
                   seconds: Date().timeIntervalSince(started), helperRunning: helper.isRunning)
}

// MARK: drawing and reading pictures

/// A smooth gradient with a few discs: compresses well at any size, and has a clear shape and proportion.
func t34Picture(width: Int, height: Int, seed: Int) -> CGImage? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    func channel(_ k: Int) -> CGFloat { CGFloat((seed &* 37 &+ k &* 91) % 200 + 30) / 255 }
    let colors = [CGColor(red: channel(1), green: channel(2), blue: channel(3), alpha: 1),
                  CGColor(red: channel(4), green: channel(5), blue: channel(6), alpha: 1)] as CFArray
    guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return nil }
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    for disc in 0..<5 {
        context.setFillColor(CGColor(red: channel(disc + 7), green: channel(disc + 8), blue: channel(disc + 9), alpha: 1))
        let side = CGFloat(min(width, height)) * 0.18
        context.fillEllipse(in: CGRect(x: CGFloat(width) * (0.1 + 0.17 * CGFloat(disc)), y: CGFloat(height) * 0.35,
                                       width: side, height: side))
    }
    return context.makeImage()
}

/// Writes (or rewrites in place) one picture and sets its modified time to a whole second.
func t34Write(_ url: URL, width: Int, height: Int, seed: Int, mtime: TimeInterval) throws {
    let png = url.pathExtension == "png" || url.pathExtension == "pem"
    let data = NSMutableData()
    guard let image = t34Picture(width: width, height: height, seed: seed),
          let destination = CGImageDestinationCreateWithData(data, (png ? "public.png" : "public.jpeg") as CFString, 1, nil)
    else {
        Issue.record("the test could not draw \(url.lastPathComponent)")
        return
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    try (data as Data).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: url.path)
}

func t34Stat(_ url: URL) -> (size: Int64, mtime: Int64, mode: UInt16)? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return (Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), UInt16(info.st_mode & 0o7777))
}

func t34Normal(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

/// What ImageIO says about a file: its type and its pixel size, and whether it decodes whole.
func t34Decode(_ url: URL) -> (type: String?, width: Int, height: Int, decodes: Bool)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
    return (CGImageSourceGetType(source) as String?, width, height, CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
}

private let t34ShortNames = ["amber", "basalt", "cedar", "dune", "ember", "fjord", "glacier", "harbor", "island", "jungle"]

/// `count` photos named `<word>-<nn>.<ext>` in `directory`, `width` x `height`, every one a different picture.
@discardableResult
func t34MakePhotos(in directory: URL, count: Int, width: Int, height: Int, png: Bool = false, firstNumber: Int = 1) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var made: [URL] = []
    for offset in 0..<count {
        let number = firstNumber + offset
        let url = directory.appendingPathComponent(
            String(format: "%@-%02d.%@", t34ShortNames[(number - 1) % t34ShortNames.count], number, png ? "png" : "jpg"))
        try t34Write(url, width: width, height: height, seed: number, mtime: t34Past - Double(number))
        made.append(url)
    }
    return made
}

// MARK: the tests

extension EncodeHelperTests {
@Suite("PreviewReaderTests", .serialized)
struct PreviewReaderTests {

    /// Indexes `directories`' photos with the fake embedder and waits for all `total` to be done.
    private func indexed(_ world: T34World, _ helper: HelperProcess, folders: [URL], total: Int) -> Bool {
        helper.send(t34FoldersLine(folders))
        let wait = t34WaitDone(world, helper, total: total)
        #expect(wait.reachedAll, "rows stay pending: \(wait.why(helper))")
        return wait.reachedAll
    }

    // MARK: ok

    @Test func aPreviewForOneIndexedPhotoIsOkWithAPngNoLargerThanThePaneAndTheFilesOwnFacts() throws {
        try t34WithWorld { world in
            let target = world.photos.appendingPathComponent("harbor-01.jpg")
            try t34Write(target, width: 4000, height: 3000, seed: 1, mtime: t34Past - 100)
            try t34MakePhotos(in: world.photos, count: 2, width: 300, height: 200, firstNumber: 2)
            let helper = try t34StartHelper(world)
            defer { helper.stop() }
            guard indexed(world, helper, folders: [world.photos], total: 3) else { return }

            let info = try #require(t34Stat(target))
            guard let answer = t34Ask(helper, ticket: 7, file: target.path) else {
                Issue.record("no preview reply within 30 s for a photo that is indexed; stderr: \(helper.errors)")
                return
            }
            let reply = answer.reply
            #expect(reply.previewTicket == 7, "the reply carries ticket \(String(describing: reply.previewTicket)), expected 7")
            #expect(reply.previewStatus == "ok", "status is \(String(describing: reply.previewStatus)), expected ok: \(reply.raw.prefix(300))")
            #expect(reply.previewName == "harbor-01.jpg", "name is \(String(describing: reply.previewName))")
            #expect(reply.previewKind == "photo", "kind is \(String(describing: reply.previewKind))")
            #expect(reply.previewSize == info.size, "size is \(String(describing: reply.previewSize)), stat says \(info.size)")
            #expect(reply.previewMtime == info.mtime, "mtime is \(String(describing: reply.previewMtime)), stat says \(info.mtime)")

            let path = try #require(reply.previewPng, "no png path in the reply: \(reply.raw.prefix(300))")
            #expect(path.hasPrefix("/"), "the png path is not absolute: \(path)")
            let png = URL(fileURLWithPath: path)
            let folder = world.scratch(pid: helper.pid)
            #expect(t34Normal(png.deletingLastPathComponent().path) == t34Normal(folder.path),
                    "the png is at \(path), expected a file directly in \(folder.path)")
            let decoded = try #require(t34Decode(png), "the png at \(path) cannot be read by ImageIO")
            #expect(decoded.decodes, "the png at \(path) does not decode")
            #expect(decoded.type == "public.png", "the picture is of type \(decoded.type ?? "nil"), expected public.png")
            #expect(decoded.width <= t34PaneMaxWidth && decoded.height <= t34PaneMaxHeight,
                    "the png is \(decoded.width) x \(decoded.height), larger than the pane (\(t34PaneMaxWidth) x \(t34PaneMaxHeight))")
            #expect(max(decoded.width, decoded.height) >= 400,
                    "the png is \(decoded.width) x \(decoded.height): a thumbnail, not the picture at pane size")
            let ratio = Double(decoded.width) / Double(decoded.height)
            #expect(abs(ratio - 4.0 / 3.0) < 4.0 / 3.0 * 0.02, "the png has proportions \(ratio), the photo is 4000 x 3000")
        }
    }

    // MARK: gone, changed, not admitted

    @Test func aDeletedFileGivesStatusGoneWithNullPngSizeAndMtime() throws {
        try t34WithWorld { world in
            let photos = try t34MakePhotos(in: world.photos, count: 3, width: 300, height: 200)
            let helper = try t34StartHelper(world)
            defer { helper.stop() }
            guard indexed(world, helper, folders: [world.photos], total: 3) else { return }

            try FileManager.default.removeItem(at: photos[1])
            guard let answer = t34Ask(helper, ticket: 11, file: photos[1].path) else {
                Issue.record("no preview reply within 30 s for a deleted file; stderr: \(helper.errors)")
                return
            }
            let reply = answer.reply
            #expect(reply.previewTicket == 11)
            #expect(reply.previewStatus == "gone", "status is \(String(describing: reply.previewStatus)), expected gone: \(reply.raw.prefix(300))")
            #expect(reply.isNull("png"), "png is not null for a gone file: \(reply.raw.prefix(300))")
            #expect(reply.isNull("size"), "size is not null for a gone file")
            #expect(reply.isNull("mtime"), "mtime is not null for a gone file")

            // The other photos are still previewed: a gone file does not harm the helper.
            let other = t34Ask(helper, ticket: 12, file: photos[0].path)
            #expect(other?.reply.previewStatus == "ok", "after a gone file, the next preview is \(String(describing: other?.reply.previewStatus))")
        }
    }

    @Test func aFileEditedAfterIndexingGivesStatusChangedWithTheCurrentFactsAndThePictureAsItIsNow() throws {
        try t34WithWorld { world in
            let target = world.photos.appendingPathComponent("cedar-01.jpg")
            try t34Write(target, width: 1600, height: 1200, seed: 1, mtime: t34Past - 100)
            try t34MakePhotos(in: world.photos, count: 2, width: 300, height: 200, firstNumber: 2)
            let helper = try t34StartHelper(world)
            defer { helper.stop() }
            guard indexed(world, helper, folders: [world.photos], total: 3) else { return }
            let oldSize = try #require(t34Stat(target)?.size)

            // The photo is rewritten as a portrait picture: new size, new time, new content. No `folders` line follows,
            // so the index still holds what it read.
            try t34Write(target, width: 1200, height: 1600, seed: 9, mtime: t34Past - 5000)
            let info = try #require(t34Stat(target))
            #expect(info.size != oldSize, "the test's rewrite did not change the file's size")

            guard let answer = t34Ask(helper, ticket: 21, file: target.path) else {
                Issue.record("no preview reply within 30 s for an edited file; stderr: \(helper.errors)")
                return
            }
            let reply = answer.reply
            #expect(reply.previewTicket == 21)
            #expect(reply.previewStatus == "changed", "status is \(String(describing: reply.previewStatus)), expected changed: \(reply.raw.prefix(300))")
            #expect(reply.previewName == "cedar-01.jpg")
            #expect(reply.previewKind == "photo")
            #expect(reply.previewSize == info.size, "size is \(String(describing: reply.previewSize)), stat says \(info.size) (the current size)")
            #expect(reply.previewMtime == info.mtime, "mtime is \(String(describing: reply.previewMtime)), stat says \(info.mtime) (the current time)")
            let path = try #require(reply.previewPng, "no png path in a changed reply: \(reply.raw.prefix(300))")
            let decoded = try #require(t34Decode(URL(fileURLWithPath: path)), "the png at \(path) cannot be read by ImageIO")
            #expect(decoded.decodes)
            #expect(decoded.height > decoded.width, "the png is \(decoded.width) x \(decoded.height): it shows the old landscape picture, not the file as it is now")
            #expect(decoded.width <= t34PaneMaxWidth && decoded.height <= t34PaneMaxHeight)
        }
    }

    @Test func aPathNoLongerAdmittedGivesGone() throws {
        try t34WithWorld { world in
            let folderA = world.photos.appendingPathComponent("kept", isDirectory: true)
            let folderB = world.photos.appendingPathComponent("dropped", isDirectory: true)
            let elsewhere = world.root.appendingPathComponent("never-picked", isDirectory: true)
            let kept = try t34MakePhotos(in: folderA, count: 2, width: 300, height: 200)
            let dropped = try t34MakePhotos(in: folderB, count: 2, width: 300, height: 200, firstNumber: 3)
            let never = try t34MakePhotos(in: elsewhere, count: 1, width: 300, height: 200, firstNumber: 5)
            // A never-read key name (design section 1, the key-name table) inside a picked folder: real picture data.
            let key = folderA.appendingPathComponent("server.pem")
            try t34Write(key, width: 300, height: 200, seed: 6, mtime: t34Past - 6)

            let helper = try t34StartHelper(world)
            defer { helper.stop() }
            guard indexed(world, helper, folders: [folderA, folderB], total: 4) else { return }

            // The folder `dropped` leaves the list: its rows go, its files stay on disk.
            helper.send(t34FoldersLine([folderA]))
            let started = Date()
            var db: T34DB?
            var rows = -1
            while Date().timeIntervalSince(started) < 60 {
                if db == nil { db = T34DB(path: world.indexFile) }
                rows = db?.int("select count(*) from files") ?? -1
                if rows == 2 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            #expect(rows == 2, "after a shorter `folders` line the index holds \(rows) files rows, expected 2")

            var ticket = 30
            for (label, file) in [("a file whose folder was taken out of the list", dropped[0]),
                                  ("a photo in a folder that was never picked", never[0]),
                                  ("a never-read key name inside a picked folder", key)] {
                #expect(FileManager.default.fileExists(atPath: file.path), "the test's file is not on disk: \(file.path)")
                ticket += 1
                guard let answer = t34Ask(helper, ticket: ticket, file: file.path) else {
                    Issue.record("\(label): no preview reply within 30 s; stderr: \(helper.errors)")
                    continue
                }
                let reply = answer.reply
                #expect(reply.previewStatus == "gone", "\(label): status is \(String(describing: reply.previewStatus)), expected gone: \(reply.raw.prefix(300))")
                #expect(reply.isNull("png"), "\(label): png is not null")
                #expect(reply.isNull("size"), "\(label): size is not null")
                #expect(reply.isNull("mtime"), "\(label): mtime is not null")
            }
            // A picked, admitted photo is still previewed.
            let fine = t34Ask(helper, ticket: 40, file: kept[0].path)
            #expect(fine?.reply.previewStatus == "ok", "an admitted photo is \(String(describing: fine?.reply.previewStatus)) after the refusals")
        }
    }

    // MARK: a newer selection cancels an older one

    @Test func aNewerSelectionCancelsAnOlderOneAndNoOlderReplyComesAfterTheNewestOne() throws {
        try t34WithWorld { world in
            // Six large pictures: reading each takes long enough that the later lines are already waiting.
            let photos = try t34MakePhotos(in: world.photos, count: 6, width: 5000, height: 3750, png: true)
            let helper = try t34StartHelper(world)
            defer { helper.stop() }
            guard indexed(world, helper, folders: [world.photos], total: 6) else { return }

            let tickets = Array(101...106)
            let newest = 106
            // One write: all six selections arrive together, the way fast arrowing makes them follow each other.
            helper.send(zip(tickets, photos).map { t34PreviewLine(ticket: $0, file: $1.path) }.joined(separator: "\n"))

            var seen: [(ticket: Int, reply: HelperReply)] = []
            func take(_ line: (text: String, at: Date)) {
                if let reply = HelperReply(line.text), reply.event == "preview", let ticket = reply.previewTicket {
                    seen.append((ticket, reply))
                }
            }
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                guard let line = helper.nextLine(timeout: 1) else {
                    if helper.isRunning { continue } else { break }
                }
                take(line)
                if seen.last?.ticket == newest { break }
            }
            // Stragglers: anything an older request still sends after the newest one was answered.
            let settle = Date().addingTimeInterval(4)
            while Date() < settle, helper.isRunning {
                if let line = helper.nextLine(timeout: 0.2) { take(line) }
            }

            let newestAt = seen.firstIndex { $0.ticket == newest }
            #expect(newestAt != nil, "the newest selection (ticket \(newest)) was never answered; replies for \(seen.map { $0.ticket }); stderr: \(helper.errors)")
            guard let newestAt else { return }
            #expect(seen[newestAt].reply.previewStatus == "ok", "the newest reply has status \(String(describing: seen[newestAt].reply.previewStatus))")
            let late = seen[(newestAt + 1)...].map { $0.ticket }
            #expect(late.isEmpty, "replies for older tickets \(late) came after the newest one's: an older selection was not cancelled")
            let older = seen.filter { $0.ticket != newest }.map { $0.ticket }
            #expect(older.count < tickets.count - 1,
                    "all \(older.count) older selections were answered (tickets \(older)): none was cancelled by the newer one")
            #expect(Set(seen.map { $0.ticket }).isSubset(of: Set(tickets)), "a reply carries a ticket nobody sent: \(seen.map { $0.ticket })")

            // The helper still answers afterwards.
            let after = t34Ask(helper, ticket: 200, file: photos[0].path, timeout: 60)
            #expect(after?.reply.previewStatus == "ok", "after the burst the next preview is \(String(describing: after?.reply.previewStatus))")
        }
    }

    // MARK: the scratch folder

    @Test func theScratchFolderHoldsMode0600FilesAndIsRemovedWhenTheHelperExits() throws {
        try t34WithWorld { world in
            let photos = try t34MakePhotos(in: world.photos, count: 3, width: 1200, height: 800)
            let helper = try t34StartHelper(world)
            defer { helper.stop() }
            guard indexed(world, helper, folders: [world.photos], total: 3) else { return }
            let folder = world.scratch(pid: helper.pid)

            for (index, photo) in photos.enumerated() {
                guard let answer = t34Ask(helper, ticket: 50 + index, file: photo.path) else {
                    Issue.record("no preview reply within 30 s for \(photo.lastPathComponent); stderr: \(helper.errors)")
                    return
                }
                #expect(answer.reply.previewStatus == "ok", "preview \(index + 1): status \(String(describing: answer.reply.previewStatus))")
            }

            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                    "there is no scratch folder \(folder.path) after previews (TMPDIR was \(world.tmp.path); found \((try? FileManager.default.contentsOfDirectory(atPath: world.tmp.path)) ?? []))")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            #expect(!names.isEmpty, "the scratch folder holds no file after three previews")
            for name in names {
                let mode = t34Stat(folder.appendingPathComponent(name))?.mode
                #expect(mode == 0o600, "\(name) in the scratch folder has mode \(mode.map { String($0, radix: 8) } ?? "nil"), expected 600")
            }

            // Exit at stdin EOF: the folder goes with the process.
            helper.closeStdin()
            let exit = helper.waitForExit(timeout: 60)
            #expect(exit != nil, "the helper did not exit within 60 s of stdin EOF; stderr: \(helper.errors)")
            var gone = false
            let waited = Date()
            while Date().timeIntervalSince(waited) < 10 {
                if !FileManager.default.fileExists(atPath: folder.path) { gone = true; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            #expect(gone, "the scratch folder \(folder.path) is still there 10 s after the helper exited (\((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []))")
        }
    }
}
}
