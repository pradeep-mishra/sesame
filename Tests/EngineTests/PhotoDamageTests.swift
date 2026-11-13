import CoreGraphics
import Foundation
import ImageIO
import SesameEngine
import Testing

// plan-3-t14b, tester step: a photo that decodes only partly is `could_not_read` (damaged).
// Written from the plan entry only; no product source is read. The interface is the one the helper uses:
// the public `PhotoReader.read(path:expecting:wantBitmap:)` with `wantBitmap: false`, a `FileIdentity` made from the
// test's own `lstat`, the error `PhotoReadError.unreadable` (the helper writes `could_not_read`, reason "damaged",
// for exactly that error) and `nameWords` holding the file name.
//
// Damaged samples (each must throw `PhotoReadError.unreadable`): a 640x480 PNG that ImageIO writes, cut to its first
// 100 bytes, its first 300 bytes, and all but its last 12 bytes (every picture byte present, the IEND chunk gone);
// a 640x480 JPEG cut to its first 300 bytes and to half its length.
// Good samples (each must read, no throw): one file of each supported extension, made by ImageIO where this machine
// can write the type and otherwise taken from the `ext-<ext>` cell of `kit-fixtures.sh build matrix` (child process,
// temp KIT_ROOT), plus the uncut PNG and JPEG the cut ones came from.
// Every file lives under one temp folder under $TMPDIR, removed at exit. No helper, no model, no app.
//
// plan-3-t14b-3 additions (controller decision: a false "could not read" on a person's own photo is worse than a missed
// truncated photo; a good photo with data after its end marker is not damaged):
// Good, must read: the JPEG plus a 2 MB pseudo-random trailer, the JPEG plus 4 KB of 0x00, the PNG plus 64 trailing
// bytes after IEND, an uncut 640x480 progressive JPEG written by ImageIO.
// Damaged, must be unreadable: a 640x480 JPEG with an embedded EXIF thumbnail (so an FF D9 sits early in the file)
// cut to half, and the progressive JPEG cut to half.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private let width = 640
private let height = 480

// MARK: hand-written expectations

private let photoExtensions = ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"]

/// The picture type each supported extension must really be.
private let typeOf: [String: String] = [
    "jpeg": "public.jpeg", "jpg": "public.jpeg", "png": "public.png", "heic": "public.heic",
    "webp": "org.webmproject.webp", "tiff": "public.tiff", "tif": "public.tiff", "gif": "com.compuserve.gif",
]

/// The 12-byte PNG end chunk.
private let iend: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

// MARK: building the samples

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A gradient plus noise, no text: well above 5,000 bytes in PNG and JPEG alike.
private func makeImage(width w: Int, height h: Int, seed: UInt64) -> CGImage? {
    var rng = SplitMix64(state: seed)
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let noise = UInt8(truncatingIfNeeded: rng.next() >> 56)
            bytes[i] = UInt8(x * 255 / max(w - 1, 1))
            bytes[i + 1] = UInt8(y * 255 / max(h - 1, 1))
            bytes[i + 2] = noise
            bytes[i + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGImage(
        width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

/// Writes `image` as `type` with ImageIO; true only when the file is there and ImageIO reads it back as that type.
private func writeImage(_ image: CGImage, type: String, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        try? FileManager.default.removeItem(at: url)
        return false
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          (CGImageSourceGetType(source) as String?) == type,
          CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
        try? FileManager.default.removeItem(at: url)
        return false
    }
    return true
}

/// Writes `image` as a JPEG with ImageIO using `properties` for the image; true only when the file reads back as a
/// 640x480 JPEG.
private func writeJPEG(_ image: CGImage, properties: [String: Any], to path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        try? FileManager.default.removeItem(at: url)
        return false
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          (CGImageSourceGetType(source) as String?) == "public.jpeg",
          let back = CGImageSourceCreateImageAtIndex(source, 0, nil), back.width == width, back.height == height else {
        try? FileManager.default.removeItem(at: url)
        return false
    }
    return true
}

/// The first start-of-frame marker byte (0xC0 baseline, 0xC2 progressive, ...) of a JPEG, found by walking its segments.
private func jpegFrameMarker(_ bytes: [UInt8]) -> UInt8? {
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
    var i = 2
    while i + 4 <= bytes.count {
        guard bytes[i] == 0xFF else { return nil }
        let m = bytes[i + 1]
        if m == 0xFF { i += 1; continue }
        if m == 0xDA || m == 0xD9 { return nil }
        if (0xC0...0xCF).contains(m), m != 0xC4, m != 0xC8, m != 0xCC { return m }
        let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        i += 2 + length
    }
    return nil
}

/// The index of the first FF D9 pair, or nil.
private func firstEndMarker(_ bytes: [UInt8]) -> Int? {
    guard bytes.count > 1 else { return nil }
    for i in 0..<(bytes.count - 1) where bytes[i] == 0xFF && bytes[i + 1] == 0xD9 { return i }
    return nil
}

private func randomBytes(_ n: Int, seed: UInt64) -> [UInt8] {
    var rng = SplitMix64(state: seed)
    return (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next() >> 56) }
}

private final class Cleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }
    func run() {
        lock.lock()
        let all = paths
        lock.unlock()
        for p in all { try? FileManager.default.removeItem(atPath: p) }
    }
}
private let cleanup = Cleanup()
private let cleanupRegistered: Void = { atexit { cleanup.run() } }()

private struct Ran {
    let status: Int32
    let output: String
}

private func runProcess(_ exe: String, _ args: [String], env: [String: String], limit: TimeInterval = 600) -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("photodamage-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    guard let handle = try? FileHandle(forWritingTo: out) else { return Ran(status: 127, output: "no output file") }
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    p.standardOutput = handle
    p.standardError = handle
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return Ran(status: 127, output: "\(error)") }
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    var status: Int32
    if p.isRunning {
        p.terminate()
        p.waitUntilExit()
        status = 124
    } else {
        status = p.terminationStatus
    }
    try? handle.synchronize()
    return Ran(status: status, output: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
}

/// The path of cell `ext-<ext>` in the sealed matrix table (read, never changed): cell,path,... per row.
private func matrixCellPath(_ cell: String) -> String? {
    let table = projectRoot.appendingPathComponent("scripts/kit-lib/gate-matrix.csv").path
    guard let text = try? String(contentsOfFile: table, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if f.count >= 2, f[0] == cell { return f[1] }
    }
    return nil
}

private struct Built {
    /// sample name -> absolute path
    var paths: [String: String] = [:]
    /// how each good extension sample was made: "ImageIO" or "matrix cell"
    var madeBy: [String: String] = [:]
    var problems: [String] = []
    /// samples this machine could not make (reported, not a failure of the build)
    var dropped: [String] = []
}

private let built: Built = {
    _ = cleanupRegistered
    var b = Built()
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("photodamage-" + UUID().uuidString, isDirectory: true)
        .resolvingSymlinksInPath().path
    do { try fm.createDirectory(atPath: base, withIntermediateDirectories: true) } catch {
        b.problems.append("cannot make \(base): \(error)")
        return b
    }
    cleanup.add(base)

    // the uncut PNG and JPEG, 640x480
    guard let big = makeImage(width: width, height: height, seed: 640_480) else {
        b.problems.append("cannot make the 640x480 image")
        return b
    }
    let fullPng = base + "/fullpicture.png"
    let fullJpg = base + "/fullpicture.jpg"
    if writeImage(big, type: "public.png", to: fullPng) { b.paths["full-png"] = fullPng } else {
        b.problems.append("ImageIO could not write the 640x480 PNG")
    }
    if writeImage(big, type: "public.jpeg", to: fullJpg) { b.paths["full-jpg"] = fullJpg } else {
        b.problems.append("ImageIO could not write the 640x480 JPEG")
    }

    // the cuts
    func cut(_ source: String, name: String, file: String, keep: (Int) -> Int) {
        guard let data = fm.contents(atPath: source) else { return }
        let path = base + "/" + file
        if fm.createFile(atPath: path, contents: data.prefix(keep(data.count))) { b.paths[name] = path }
    }
    if let p = b.paths["full-png"] {
        cut(p, name: "cut-png-100", file: "cutpicture100.png") { _ in 100 }
        cut(p, name: "cut-png-300", file: "cutpicture300.png") { _ in 300 }
        cut(p, name: "cut-png-minus12", file: "cutpicturetail.png") { $0 - 12 }
    }
    if let p = b.paths["full-jpg"] {
        cut(p, name: "cut-jpg-300", file: "cutpicture300.jpg") { _ in 300 }
        cut(p, name: "cut-jpg-half", file: "cutpicturehalf.jpg") { $0 / 2 }
    }

    // plan-3-t14b-3: good photos with data after the end marker, a progressive JPEG, an EXIF-thumbnail JPEG
    func append(_ source: String, name: String, file: String, extra: [UInt8]) {
        guard let data = fm.contents(atPath: source) else { return }
        let path = base + "/" + file
        if fm.createFile(atPath: path, contents: data + Data(extra)) { b.paths[name] = path }
    }
    if let p = b.paths["full-jpg"] {
        append(p, name: "trailer-jpg-random", file: "trailerrandom.jpg", extra: randomBytes(2_000_000, seed: 2_000_000))
        append(p, name: "trailer-jpg-zero", file: "trailerzero.jpg", extra: [UInt8](repeating: 0, count: 4096))
    }
    if let p = b.paths["full-png"] {
        append(p, name: "trailer-png", file: "trailerpng.png", extra: randomBytes(64, seed: 64))
    }
    let progressiveProps: [String: Any] = [
        kCGImagePropertyJFIFDictionary as String: [kCGImagePropertyJFIFIsProgressive as String: true] as CFDictionary,
    ]
    let progressivePath = base + "/progressive.jpg"
    if writeJPEG(big, properties: progressiveProps, to: progressivePath) {
        b.paths["progressive-jpg"] = progressivePath
        cut(progressivePath, name: "progressive-jpg-half", file: "progressivehalf.jpg") { $0 / 2 }
    } else {
        b.dropped.append("ImageIO could not write a 640x480 progressive JPEG")
    }
    let thumbPath = base + "/thumbnail.jpg"
    var thumbMade = false
    for thumbPixels in [160, 96, 64] where !thumbMade {
        let props: [String: Any] = [
            kCGImageDestinationEmbedThumbnail as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: thumbPixels,
        ]
        guard writeJPEG(big, properties: props, to: thumbPath) else { continue }
        if let early = firstEndMarker(fileBytes(thumbPath)), early < 20_000 { thumbMade = true } else {
            try? fm.removeItem(atPath: thumbPath)
        }
    }
    if thumbMade {
        b.paths["thumbnail-jpg"] = thumbPath
        cut(thumbPath, name: "thumbnail-jpg-half", file: "thumbnailhalf.jpg") { $0 / 2 }
    } else {
        b.dropped.append("ImageIO did not write a 640x480 JPEG with an FF D9 in its first 20,000 bytes (no embedded thumbnail)")
    }

    // one good file per supported extension: ImageIO where it can write the type, else the matrix cell
    let small = makeImage(width: 160, height: 120, seed: 160_120)
    var needMatrix: [String] = []
    for ext in photoExtensions {
        let path = base + "/goodpicture\(ext)." + ext
        if let small, let type = typeOf[ext], writeImage(small, type: type, to: path) {
            b.paths["good-" + ext] = path
            b.madeBy[ext] = "ImageIO"
        } else {
            needMatrix.append(ext)
        }
    }
    if !needMatrix.isEmpty {
        let kitRoot = base + "/sesame-kit-pd"
        let tmp = base + "/tmp"
        let home = base + "/decoy-home"
        for d in [kitRoot + "/run", tmp, home] {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        let script = projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path
        let ran = runProcess(
            "/bin/bash", [script, "build", "matrix"],
            env: ["KIT_ROOT": kitRoot, "TMPDIR": tmp + "/", "HOME": home,
                  "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"])
        if ran.status != 0 { b.problems.append("kit-fixtures.sh build matrix exited \(ran.status): \(ran.output.suffix(400))") }
        for ext in needMatrix {
            guard let rel = matrixCellPath("ext-" + ext) else {
                b.problems.append("the table has no cell ext-\(ext)")
                continue
            }
            let from = kitRoot + "/fixtures/matrix/" + rel
            let to = base + "/goodpicture\(ext)." + ext
            if fm.fileExists(atPath: from), (try? fm.copyItem(atPath: from, toPath: to)) != nil {
                b.paths["good-" + ext] = to
                b.madeBy[ext] = "matrix cell ext-\(ext)"
            } else {
                b.problems.append("no file for ext-\(ext) at \(from)")
            }
        }
    }
    return b
}()

// MARK: reading through the helper's interface

private func identity(of path: String) -> FileIdentity? {
    var st = Darwin.stat()
    guard lstat(path, &st) == 0 else { return nil }
    let mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    return FileIdentity(size: Int64(st.st_size), mtimeNs: mtimeNs, inode: UInt64(st.st_ino))
}

private struct Outcome {
    let verdict: String
    let nameWords: String
}

/// "read" when `PhotoReader.read` returns, "unreadable" when it throws `PhotoReadError.unreadable`, else "other: ...".
private func read(_ path: String) -> Outcome {
    guard let id = identity(of: path) else { return Outcome(verdict: "no file or no identity", nameWords: "") }
    do {
        let photo = try PhotoReader.read(path: path, expecting: id, wantBitmap: false)
        return Outcome(verdict: "read", nameWords: String(describing: photo.nameWords))
    } catch PhotoReadError.unreadable {
        return Outcome(verdict: "unreadable", nameWords: "")
    } catch {
        return Outcome(verdict: "other: \(error)", nameWords: "")
    }
}

private func size(_ path: String) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1
}

private func fileBytes(_ path: String) -> [UInt8] {
    FileManager.default.contents(atPath: path).map { [UInt8]($0) } ?? []
}

// MARK: the tests

@Suite("PhotoDamageTests", .serialized)
struct PhotoDamageTests {
    @Test("the samples are built: nothing failed, the PNG and JPEG are 640x480 and well above 5,000 bytes, the cuts are the stated cuts")
    func samplesAreBuilt() throws {
        #expect(built.problems.isEmpty, "building the samples failed: \(built.problems)")
        let png = try #require(built.paths["full-png"])
        let jpg = try #require(built.paths["full-jpg"])
        #expect(size(png) > 5_000, "the PNG is only \(size(png)) bytes")
        #expect(size(jpg) > 5_000, "the JPEG is only \(size(jpg)) bytes")
        for p in [png, jpg] {
            let src = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil))
            let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
            #expect(img.width == 640 && img.height == 480, "\(p) is \(img.width)x\(img.height)")
        }
        let whole = fileBytes(png)
        #expect(Array(whole.prefix(8)) == pngSignature, "the PNG has no PNG signature")
        #expect(Array(whole.suffix(12)) == iend, "the PNG does not end with the IEND chunk, so the minus-12 cut is not the IEND cut")
        #expect(size(try #require(built.paths["cut-png-100"])) == 100)
        #expect(size(try #require(built.paths["cut-png-300"])) == 300)
        #expect(size(try #require(built.paths["cut-png-minus12"])) == whole.count - 12)
        #expect(size(try #require(built.paths["cut-jpg-300"])) == 300)
        #expect(size(try #require(built.paths["cut-jpg-half"])) == size(jpg) / 2)
    }

    @Test("a cut photo throws PhotoReadError.unreadable", arguments: [
        "cut-png-100", "cut-png-300", "cut-png-minus12", "cut-jpg-300", "cut-jpg-half",
    ])
    func damagedIsUnreadable(sample: String) throws {
        let path = try #require(built.paths[sample], "sample \(sample) was not built: \(built.problems)")
        let result = read(path)
        #expect(result.verdict == "unreadable", "\(sample) (\(size(path)) bytes): expected unreadable, got \(result.verdict)")
    }

    @Test("an uncut photo reads, and nameWords holds the file name", arguments: [
        "full-png", "full-jpg",
        "good-jpeg", "good-jpg", "good-png", "good-heic", "good-webp", "good-tiff", "good-tif", "good-gif",
    ])
    func goodReads(sample: String) throws {
        let path = try #require(built.paths[sample], "sample \(sample) was not built: \(built.problems)")
        let result = read(path)
        #expect(result.verdict == "read", "\(sample) (\(size(path)) bytes): expected read, got \(result.verdict)")
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        #expect(result.nameWords.lowercased().contains(stem), "\(sample): nameWords \(result.nameWords) does not hold \(stem)")
    }

    // MARK: plan-3-t14b-3

    @Test("the extra samples are built as stated: trailers after the end markers, a progressive JPEG, a JPEG with an early FF D9")
    func extraSamplesAreBuilt() throws {
        #expect(built.dropped.isEmpty, "dropped samples: \(built.dropped)")
        let jpg = fileBytes(try #require(built.paths["full-jpg"]))
        let png = fileBytes(try #require(built.paths["full-png"]))
        #expect(Array(jpg.suffix(2)) == [0xFF, 0xD9], "the plain JPEG does not end FF D9")

        let random = fileBytes(try #require(built.paths["trailer-jpg-random"]))
        #expect(random.count == jpg.count + 2_000_000 && Array(random.prefix(jpg.count)) == jpg)
        let zero = fileBytes(try #require(built.paths["trailer-jpg-zero"]))
        #expect(zero.count == jpg.count + 4096 && Array(zero.prefix(jpg.count)) == jpg && zero.suffix(4096).allSatisfy { $0 == 0 })
        let pngTrailer = fileBytes(try #require(built.paths["trailer-png"]))
        #expect(pngTrailer.count == png.count + 64 && Array(pngTrailer.prefix(png.count)) == png)

        if let path = built.paths["progressive-jpg"] {
            let bytes = fileBytes(path)
            #expect(bytes.count > 5_000, "the progressive JPEG is only \(bytes.count) bytes")
            #expect(jpegFrameMarker(bytes) == 0xC2, "the progressive JPEG's frame marker is \(String(describing: jpegFrameMarker(bytes)))")
            #expect(Array(bytes.suffix(2)) == [0xFF, 0xD9])
            #expect(size(try #require(built.paths["progressive-jpg-half"])) == bytes.count / 2)
        }
        if let path = built.paths["thumbnail-jpg"] {
            let bytes = fileBytes(path)
            let early = try #require(firstEndMarker(bytes))
            #expect(early < 20_000, "first FF D9 at \(early)")
            #expect(early < bytes.count - 2, "the only FF D9 is the last one: no embedded thumbnail")
            #expect(size(try #require(built.paths["thumbnail-jpg-half"])) == bytes.count / 2)
            #expect(bytes.count / 2 > early + 2, "the half cut does not contain the early FF D9")
        }
    }

    @Test("a good photo with data after its end marker, or a progressive one, still reads", arguments: [
        "trailer-jpg-random", "trailer-jpg-zero", "trailer-png", "progressive-jpg",
    ])
    func goodWithTrailerReads(sample: String) throws {
        let path = try #require(built.paths[sample], "sample \(sample) was not built: \(built.problems) \(built.dropped)")
        let result = read(path)
        #expect(result.verdict == "read", "\(sample) (\(size(path)) bytes): expected read, got \(result.verdict)")
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        #expect(result.nameWords.lowercased().contains(stem), "\(sample): nameWords \(result.nameWords) does not hold \(stem)")
    }

    @Test("a truncated JPEG is unreadable even when it holds an early FF D9 or is progressive", arguments: [
        "thumbnail-jpg-half", "progressive-jpg-half",
    ])
    func truncatedWithEarlyMarkerIsUnreadable(sample: String) throws {
        let path = try #require(built.paths[sample], "sample \(sample) was not built: \(built.problems) \(built.dropped)")
        let result = read(path)
        #expect(result.verdict == "unreadable", "\(sample) (\(size(path)) bytes): expected unreadable, got \(result.verdict)")
    }
}
