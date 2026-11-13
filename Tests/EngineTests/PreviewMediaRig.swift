import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Speech
import Testing
import SesameEngine

// plan-5-t4, tester step. The shared rig of PreviewReaderAudioTests and PreviewReaderVideoTests. Written from the entry plan-5-t4 of
// plan-5-tasks.md, the Conventions, the Decisions D3 to D8 and D11, the t2 and t3 tester and implementer reports and the plan 4 preview
// tests (PreviewReaderPdfTests is the model); no product source is read. Nothing here is product code.
//
// SHAPES THIS FILE PINS that the entry did not fix (the one place to edit each is this file; the report lists them):
//   1. `PreviewReader(scratch: Scratch(), speech: SpeechService)`: the plan 4 initialiser `init(scratch:)` stays (sealed tests use it)
//      and gains `speech:`. The reader is one object for the whole run, so a newer ticket can reach an older call in flight: `reply`
//      may be called from two threads on one reader.
//   2. `public protocol SpeechService: Sendable` with `var supportsOnDevice: Bool { get }` and
//      `func transcribe(samples: [Float], request: SFSpeechAudioBufferRecognitionRequest, isCancelled: @escaping @Sendable () -> Bool) -> String?`
//      (blocking; nil is "no words"). The request is built by the product with `LiveSpeech.makeRequest()`, so a fake that reads
//      `request.requiresOnDeviceRecognition` reads the flag the live code sets, not a boolean the reader chose; `samples` are the stored
//      window's 16 kHz mono Float32 samples and nothing else; `isCancelled` turns true once a newer ticket has reached the reader.
//   3. `LiveSpeech.makeRequest() -> SFSpeechAudioBufferRecognitionRequest`, a static function, no authorization, no recognition.
//   4. `PreviewReply.seconds: Int?` is the last label of the initialiser after `text` (`locator:`, `text:`, `seconds:` in that order;
//      `marks:` may come between `text:` and `seconds:` or after `seconds:`); a test here never passes both `marks:` and `seconds:`.
//   5. An audio or video reply has `kind` "audio" or "video", `seconds` the spot in whole seconds, `locator` "Opens at mm:ss" (minutes
//      unbounded), and its PNG (a waveform, a frame on a timeline). `text` holds the spoken words for audio and is nil otherwise;
//      `marks` is empty; `page`, `pageCount` are nil.
//   6. The timeline of a video PNG is a strip across the whole width of the PNG (0 at the left edge, the duration at the right edge) with
//      one marker; no text on the strip changes with the second. Two replies of one file at two seconds give PNGs of one size.
//   7. A passage that is a window of a video's soundtrack previews as that video's frame at the window's start second, with
//      `seconds` that start.
//   8. A gone reply has `png`, `size`, `mtime`, `page`, `pageCount`, `locator`, `text` and `seconds` all nil; a file that no longer opens
//      is `.ok` with `png`, `locator`, `text` and `seconds` nil (the pane says "Can't preview this file", G20).
//   9. `.changed`: `size` and `mtime` are the current ones; `seconds` is the stored second when it is still inside the current duration,
//      else 0; the picture is the current file's.
//
// The independent readers: the WAV the test wrote (decoded by `MediaRig.frames`), `ffmpeg` and `ffprobe` for the rig's own sanity (t3),
// the kit's `waveform-check` as the judge of the waveform (a child process), and this file's own pixel counts for the frame.

// MARK: tickets

final class PmTickets: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 9000
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        last += 1
        return last
    }
}

let pmTickets = PmTickets()

// MARK: the fake SpeechService

final class PmSpeech: SpeechService, @unchecked Sendable {
    struct Call: Sendable {
        let onDevice: Bool
        let samples: [Float]
    }

    let supportsOnDevice: Bool
    private let words: String?
    private let hold: TimeInterval
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var cancelled = false
    private let entered = DispatchSemaphore(value: 0)

    /// `hold` above 0 makes a call wait that many seconds, or until it is cancelled.
    init(supportsOnDevice: Bool = true, words: String? = nil, hold: TimeInterval = 0) {
        self.supportsOnDevice = supportsOnDevice
        self.words = words
        self.hold = hold
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var sawCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func transcribe(samples: [Float], request: SFSpeechAudioBufferRecognitionRequest, isCancelled: @escaping @Sendable () -> Bool) -> String? {
        lock.lock()
        recorded.append(Call(onDevice: request.requiresOnDeviceRecognition, samples: samples))
        lock.unlock()
        entered.signal()
        if hold > 0 {
            let end = Date().addingTimeInterval(hold)
            while Date() < end {
                if isCancelled() {
                    lock.lock()
                    cancelled = true
                    lock.unlock()
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return words
    }

    func waitEntered(_ seconds: TimeInterval) -> Bool { entered.wait(timeout: .now() + seconds) == .success }

    func waitCancelled(_ seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if sawCancel { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return sawCancel
    }
}

// MARK: a reader call under the world's HOME

/// HOME is process-wide: the lock is held for the whole body (two calls on two threads inside one body do not take it again).
func pmWithHome<T>(_ home: String, _ body: () throws -> T) rethrows -> T {
    homeLock.lock()
    defer { homeLock.unlock() }
    let previous = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home, 1)
    defer { if let previous { setenv("HOME", previous, 1) } else { unsetenv("HOME") } }
    return try body()
}

func pmReply(_ home: String, speech: SpeechService, file: String, passage: Int?, query: String = "the keeper repaired the lamp",
              ticket: Int = pmTickets.next()) -> PreviewReply {
    pmWithHome(home) { PreviewReader(scratch: Scratch(), speech: speech).reply(ticket: ticket, file: file, passage: passage, query: query) }
}

func pmDropPNG(_ reply: PreviewReply?) {
    if let png = reply?.png { try? FileManager.default.removeItem(atPath: png) }
}

/// A closure run on its own thread, its result waited for.
final class PmAsync<T: Sendable>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: T?

    init(_ body: @escaping @Sendable () -> T) {
        let thread = Thread { [self] in
            let result = body()
            lock.lock()
            value = result
            lock.unlock()
            done.signal()
        }
        thread.start()
    }

    func wait(_ seconds: TimeInterval) -> T? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: worlds are removed at exit

final class PmKeeper: @unchecked Sendable {
    private let lock = NSLock()
    private var worlds: [AtWorld] = []
    func add(_ world: AtWorld) {
        lock.lock()
        worlds.append(world)
        lock.unlock()
    }
    func run() {
        lock.lock()
        let all = worlds
        lock.unlock()
        for world in all { world.remove() }
        try? FileManager.default.removeItem(atPath: pmScratchFolder)
    }
}

let pmKeeper = PmKeeper()

/// The scratch folder the readers of this test process make (`$TMPDIR/Sesame-<pid>`, design section 1).
var pmScratchFolder: String { NSTemporaryDirectory() + "Sesame-\(getpid())" }

/// Names in the scratch folder that are not a PNG: a staged copy of a media file that was not removed shows here.
func pmScratchLeftovers() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: pmScratchFolder)) ?? []
    return names.filter { !$0.hasSuffix(".png") }
}

// MARK: facts about a file, read by the test itself

struct PmFacts: Equatable {
    var size: Int64
    var mtimeNs: Int64
    var inode: UInt64
    var bytes: Data
}

func pmFacts(_ path: String) -> PmFacts? {
    var info = Darwin.stat()
    guard lstat(path, &info) == 0, let bytes = FileManager.default.contents(atPath: path) else { return nil }
    return PmFacts(size: Int64(info.st_size),
                   mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                   inode: UInt64(info.st_ino), bytes: bytes)
}

/// Whether any file under `folder` holds `marker` as bytes (the index, its log, a PNG, a copy: whatever is there).
func pmFolderHolds(_ marker: String, under folder: String) -> [String] {
    let needle = Data(marker.utf8)
    var found: [String] = []
    guard let walker = FileManager.default.enumerator(atPath: folder) else { return found }
    for case let name as String in walker {
        let path = folder + "/" + name
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let data = FileManager.default.contents(atPath: path) else { continue }
        if data.range(of: needle) != nil { found.append(name) }
    }
    return found
}

// MARK: pictures

struct PmPixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]
}

func pmDecode(_ path: String) -> (pixels: PmPixels, type: String?)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else { return nil }
    let width = image.width, height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = data.withUnsafeMutableBytes { raw in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }
    return (PmPixels(width: width, height: height, rgba: data), CGImageSourceGetType(source) as String?)
}

/// The shade (0 to 7 of `MediaRig.shades`) most pixels of the picture are, counting a shade and its dim cell (55 percent) as one; nil when
/// no shade holds at least 15 percent of the pixels or the best is not at least twice the next one.
func pmDominantShade(_ pixels: PmPixels) -> (shade: Int, share: Double)? {
    var palette: [(shade: Int, r: Double, g: Double, b: Double)] = []
    for (index, shade) in MediaRig.shades.enumerated() {
        palette.append((index, shade.r, shade.g, shade.b))
        palette.append((index, shade.r * MediaRig.litShare, shade.g * MediaRig.litShare, shade.b * MediaRig.litShare))
    }
    var counts = [Int](repeating: 0, count: MediaRig.shades.count)
    let total = pixels.width * pixels.height
    for pixel in 0..<total {
        let r = Double(pixels.rgba[pixel * 4]), g = Double(pixels.rgba[pixel * 4 + 1]), b = Double(pixels.rgba[pixel * 4 + 2])
        var best = -1
        var bestDistance = 45.0
        for entry in palette {
            let distance = ((r - entry.r) * (r - entry.r) + (g - entry.g) * (g - entry.g) + (b - entry.b) * (b - entry.b)).squareRoot()
            if distance < bestDistance { bestDistance = distance; best = entry.shade }
        }
        if best >= 0 { counts[best] += 1 }
    }
    let order = counts.indices.sorted { counts[$0] > counts[$1] }
    let top = order[0], next = order[1]
    guard Double(counts[top]) >= 0.15 * Double(total), counts[top] >= 2 * counts[next] else { return nil }
    return (top, Double(counts[top]) / Double(total))
}

/// The centres, as a share of the width (0 to 1), of the places where two pictures of one size differ in rows that only a narrow
/// strip differs in (the frame differs across most of a row, a marker only at its own columns). Clusters are split at gaps of 4 percent.
func pmMarkerCentres(_ a: PmPixels, _ b: PmPixels) -> [Double]? {
    guard a.width == b.width, a.height == b.height else { return nil }
    var columns = Set<Int>()
    for y in 0..<a.height {
        var different: [Int] = []
        for x in 0..<a.width {
            let i = (y * a.width + x) * 4
            let d = abs(Int(a.rgba[i]) - Int(b.rgba[i])) + abs(Int(a.rgba[i + 1]) - Int(b.rgba[i + 1])) + abs(Int(a.rgba[i + 2]) - Int(b.rgba[i + 2]))
            if d > 120 { different.append(x) }
        }
        if !different.isEmpty && different.count * 100 <= a.width * 15 { columns.formUnion(different) }
    }
    let sorted = columns.sorted()
    guard !sorted.isEmpty else { return [] }
    var centres: [Double] = []
    var start = sorted[0], last = sorted[0]
    let gap = max(2, a.width * 4 / 100)
    for column in sorted.dropFirst() {
        if column - last > gap {
            centres.append(Double(start + last) / 2 / Double(a.width))
            start = column
        }
        last = column
    }
    centres.append(Double(start + last) / 2 / Double(a.width))
    return centres
}

// MARK: the kit's waveform judge, a child process

private let pmJudgeKit: MrKit? = MrKit()

struct PmJudged {
    let status: Int32
    let output: String
}

func pmWaveformCheck(png: String, audio: String, start: Int) -> PmJudged? {
    guard let kit = pmJudgeKit else {
        Issue.record("the test could not make a temp kit root for the waveform judge")
        return nil
    }
    let script = KitPaths.projectRoot.appendingPathComponent("scripts/kit-readback.sh").path
    guard FileManager.default.fileExists(atPath: script) else {
        Issue.record("scripts/kit-readback.sh not found")
        return nil
    }
    guard let ran = mrRun("/bin/bash", [script, "waveform-check", png, audio, String(start)], env: kit.env, limit: 600) else {
        Issue.record("the waveform judge could not be started")
        return nil
    }
    if ran.output.contains("not built yet") { Issue.record("kit-readback.sh waveform-check is `not built yet`") }
    return PmJudged(status: ran.status, output: ran.output)
}
