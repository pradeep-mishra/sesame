import CoreGraphics
import Foundation
import ImageIO
import Testing
import SesameEngine

// plan-3 fix round 2, t17-8, tester step (4): a valid JPEG is not "damaged" (S8.6). Written from the reviewer's round 2 note
// ("the JPEG walker ... can wrongly mark a valid JPEG as damaged (padding bytes between segments, or a missing EOI)"), the spec
// (a damaged file is `could_not_read`, a good one is read) and PhotoDamageTests for the interface (not edited). No product
// source is read.
//
// Samples, all built here with ImageIO from a 96x96 noisy picture (baseline, the ImageIO default) and byte edits:
//   control-plain.jpg      the JPEG as ImageIO wrote it
//   fill-before-sos.jpg    two 0xFF fill bytes inserted before the SOS marker (the JPEG standard allows any number of 0xFF
//                          fill bytes before a marker), so the file reads FF FF FF DA
//   fill-everywhere.jpg    two 0xFF fill bytes before every header marker, before SOS and before EOI (FF FF FF D9)
//   fill-before-eoi.jpg    the JPEG with its EOI preceded by two 0xFF fill bytes (FF FF FF D9)
//   padded-zero.jpg        the JPEG plus 1024 trailing 0x00 bytes after EOI
//   padded-ff.jpg          the JPEG plus 64 trailing 0xFF bytes after EOI
//   truncated-half.jpg     a 256x256 noisy JPEG cut to half its length (damaged; the same cut PhotoDamageTests calls
//                          cut-jpg-half): must stay `could_not_read` / PhotoReadError.unreadable
// Each valid sample must decode in ImageIO (checked while the samples are built: a bad sample fails every test with a clear
// message instead of a misleading red). Then:
//   through the bundled release helper alone (SESAME_FAKE_EMBEDDER=1, a temp HOME, no app): the valid samples are `done`,
//   the truncated one is `could_not_read`;
//   through the public `PhotoReader.read(path:expecting:wantBitmap:)` (the interface the helper uses): the valid samples
//   read with a bitmap, the truncated one throws `PhotoReadError.unreadable`.

private let jfDirectory = "pics"
private let jfValidNames = ["fill-before-sos.jpg", "fill-everywhere.jpg", "fill-before-eoi.jpg", "padded-zero.jpg", "padded-ff.jpg"]

// MARK: building the samples

/// The offset of the first start-of-scan marker (FF DA), found by walking the segments after SOI.
private func jfSOSOffset(_ bytes: [UInt8]) -> Int? {
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
    var i = 2
    while i + 4 <= bytes.count {
        guard bytes[i] == 0xFF else { return nil }
        let marker = bytes[i + 1]
        if marker == 0xFF { i += 1; continue }
        if marker == 0xDA { return i }
        i += 2 + (Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]))
    }
    return nil
}

/// The first start-of-frame marker byte (0xC0 baseline, 0xC2 progressive, ...), found by walking the segments after SOI.
private func jfFrameMarker(_ bytes: [UInt8]) -> UInt8? {
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
    var i = 2
    while i + 4 <= bytes.count {
        guard bytes[i] == 0xFF else { return nil }
        let marker = bytes[i + 1]
        if marker == 0xFF { i += 1; continue }
        if marker == 0xDA || marker == 0xD9 { return nil }
        if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC { return marker }
        i += 2 + (Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]))
    }
    return nil
}

private struct JFDecoded {
    var width = 0
    var height = 0
    var complete = false
}

private func jfDecode(_ path: String) -> JFDecoded? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return JFDecoded(width: image.width, height: image.height,
                     complete: CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete)
}

private struct JFSamples {
    var problems: [String] = []
}

/// Writes the samples into a fresh tree's `pics` folder and checks the valid ones decode. The tree is kept for the helper run.
private func jfBuild(_ tree: RXTree) -> JFSamples {
    var samples = JFSamples()
    let plain = [UInt8](rxPicture(seed: 96, type: "public.jpeg", side: 96))
    guard plain.count > 4, plain[0] == 0xFF, plain[1] == 0xD8, plain.suffix(2).elementsEqual([0xFF, 0xD9]) else {
        samples.problems.append("ImageIO did not write a JPEG that starts FF D8 and ends FF D9")
        return samples
    }
    guard jfFrameMarker(plain) == 0xC0 else {
        samples.problems.append("the JPEG is not baseline (frame marker \(String(describing: jfFrameMarker(plain))))")
        return samples
    }
    guard let sos = jfSOSOffset(plain) else {
        samples.problems.append("no SOS marker found in the JPEG")
        return samples
    }
    let fill = Array(plain[..<sos]) + [0xFF, 0xFF] + Array(plain[sos...])
    // two 0xFF fill bytes before every marker between SOI and SOS (each header segment), and before EOI
    var everywhere: [UInt8] = [0xFF, 0xD8]
    var cursor = 2
    while cursor < sos {
        let length = 2 + (Int(plain[cursor + 2]) << 8 | Int(plain[cursor + 3]))
        everywhere += [0xFF, 0xFF] + plain[cursor..<(cursor + length)]
        cursor += length
    }
    everywhere += [0xFF, 0xFF] + plain[sos..<(plain.count - 2)] + [0xFF, 0xFF, 0xFF, 0xD9]
    let beforeEOI = Array(plain.dropLast(2)) + [0xFF, 0xFF, 0xFF, 0xD9]
    let files: [(name: String, bytes: [UInt8])] = [
        ("control-plain.jpg", plain),
        ("fill-before-sos.jpg", fill),
        ("fill-everywhere.jpg", everywhere),
        ("fill-before-eoi.jpg", beforeEOI),
        ("padded-zero.jpg", plain + [UInt8](repeating: 0x00, count: 1024)),
        ("padded-ff.jpg", plain + [UInt8](repeating: 0xFF, count: 64)),
    ]
    for file in files {
        do { try tree.bytes(jfDirectory + "/" + file.name, file.bytes) } catch { samples.problems.append("cannot write \(file.name): \(error)") }
    }
    let big = [UInt8](rxPicture(seed: 256, type: "public.jpeg", side: 256))
    if big.count > 5_000 {
        do { try tree.bytes(jfDirectory + "/truncated-half.jpg", Array(big.prefix(big.count / 2))) } catch {
            samples.problems.append("cannot write truncated-half.jpg: \(error)")
        }
    } else {
        samples.problems.append("the 256x256 JPEG is only \(big.count) bytes")
    }
    if fill.count != plain.count + 2 { samples.problems.append("the fill sample is not 2 bytes longer") }
    for name in ["control-plain.jpg"] + jfValidNames {
        let path = tree.path(jfDirectory + "/" + name)
        guard let decoded = jfDecode(path) else { samples.problems.append("ImageIO cannot decode \(name)"); continue }
        if decoded.width != 96 || decoded.height != 96 || !decoded.complete {
            samples.problems.append("ImageIO decodes \(name) as \(decoded.width)x\(decoded.height), complete \(decoded.complete); want 96x96 complete")
        }
    }
    return samples
}

// MARK: one helper run shared by the tests

private struct JFRun {
    var samples = JFSamples()
    var settled = false
    var note = ""
    /// file name -> status
    var statuses: [String: String] = [:]
}

private let jfRun: JFRun = {
    var run = JFRun()
    guard let tree = try? RXTree() else { run.note = "cannot make the temp tree"; return run }
    defer { tree.remove() }
    run.samples = jfBuild(tree)
    guard run.samples.problems.isEmpty else { return run }
    guard let helper = try? rxStartHelper(home: tree.home) else { run.note = "cannot start the helper"; return run }
    defer { helper.stop() }
    helper.send(rxFoldersLine([(tree.path(jfDirectory), false)]))
    let settled = rxSettle(helper, home: tree.home, expectRows: 7)
    run.settled = settled.settled
    run.note = settled.note
    for row in settled.rows { run.statuses[(row.path as NSString).lastPathComponent] = row.status }
    return run
}()

/// The valid samples, built again in a folder that lives until the end of the process, for the direct reader.
private let jfDirect: (paths: [String: String], problems: [String]) = {
    guard let tree = try? RXTree() else { return ([:], ["cannot make the temp tree"]) }
    let samples = jfBuild(tree)
    var paths: [String: String] = [:]
    for name in ["control-plain.jpg", "truncated-half.jpg"] + jfValidNames { paths[name] = tree.path(jfDirectory + "/" + name) }
    jfDirectCleanup.add(tree.root)
    return (paths, samples.problems)
}()

private final class JFCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String] = []
    func add(_ root: String) { lock.lock(); roots.append(root); lock.unlock() }
    func run() {
        lock.lock()
        let all = roots
        lock.unlock()
        for root in all { try? FileManager.default.removeItem(atPath: root) }
    }
}
private let jfDirectCleanup = JFCleanup()
private let jfDirectCleanupRegistered: Void = { atexit { jfDirectCleanup.run() } }()

private func jfIdentity(of path: String) -> FileIdentity? {
    var st = Darwin.stat()
    guard lstat(path, &st) == 0 else { return nil }
    let mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    return FileIdentity(size: Int64(st.st_size), mtimeNs: mtimeNs, inode: UInt64(st.st_ino))
}

/// "read" when `PhotoReader.read` returns, "unreadable" when it throws `PhotoReadError.unreadable`, else "other: ...".
private func jfRead(_ path: String) -> String {
    guard let identity = jfIdentity(of: path) else { return "no file or no identity" }
    do {
        _ = try PhotoReader.read(path: path, expecting: identity, wantBitmap: true)
        return "read"
    } catch PhotoReadError.unreadable {
        return "unreadable"
    } catch {
        return "other: \(error)"
    }
}

// MARK: the tests

@Suite("JpegFillBytesTests", .serialized)
struct JpegFillBytesTests {

    // MARK: through the helper

    @Test("the helper reads a valid JPEG with fill bytes or trailing padding as done", arguments: jfValidNames)
    func helperReadsValidJpegAsDone(name: String) throws {
        let run = jfRun
        try #require(run.samples.problems.isEmpty, "the samples are wrong: \(run.samples.problems)")
        #expect(run.settled, "\(run.note)")
        #expect(run.statuses[name] == "done", "\(name): the helper recorded \(run.statuses[name] ?? "no row"), want done; all rows \(run.statuses)")
    }

    @Test func helperReadsThePlainControlAsDone() throws {
        let run = jfRun
        try #require(run.samples.problems.isEmpty, "the samples are wrong: \(run.samples.problems)")
        #expect(run.settled, "\(run.note)")
        #expect(run.statuses["control-plain.jpg"] == "done", "control-plain.jpg: \(run.statuses["control-plain.jpg"] ?? "no row"); all rows \(run.statuses)")
    }

    @Test func helperStillCallsATruncatedJpegCouldNotRead() throws {
        let run = jfRun
        try #require(run.samples.problems.isEmpty, "the samples are wrong: \(run.samples.problems)")
        #expect(run.settled, "\(run.note)")
        #expect(run.statuses["truncated-half.jpg"] == "could_not_read",
                "truncated-half.jpg: \(run.statuses["truncated-half.jpg"] ?? "no row"), want could_not_read; all rows \(run.statuses)")
    }

    // MARK: through the reader the helper uses

    @Test("PhotoReader decodes a valid JPEG with fill bytes or trailing padding", arguments: jfValidNames)
    func readerDecodesValidJpeg(name: String) throws {
        _ = jfDirectCleanupRegistered
        let direct = jfDirect
        try #require(direct.problems.isEmpty, "the samples are wrong: \(direct.problems)")
        let path = try #require(direct.paths[name])
        #expect(jfRead(path) == "read", "\(name): PhotoReader gave \(jfRead(path)), want read")
    }

    @Test func readerStillThrowsUnreadableForATruncatedJpeg() throws {
        _ = jfDirectCleanupRegistered
        let direct = jfDirect
        try #require(direct.problems.isEmpty, "the samples are wrong: \(direct.problems)")
        let path = try #require(direct.paths["truncated-half.jpg"])
        #expect(jfRead(path) == "unreadable", "truncated-half.jpg: PhotoReader gave \(jfRead(path)), want unreadable")
    }
}
