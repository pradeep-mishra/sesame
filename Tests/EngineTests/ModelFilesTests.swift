import CryptoKit
import Foundation
import Testing
import SesameEngine

// plan-1-t26, tester step. Written from design section 7 and the t26 entry only; no product source read.
//
// API SHAPES these tests pin (design names the types but fixes no signatures). Everything is `public` in
// SesameEngine because this file uses `import SesameEngine`, not `@testable`. If a shape is wrong, ask for
// a test change rather than guessing.
//   1. `public struct ModelFile: Equatable, Sendable`, with `public let name: String`, `public let size: Int`
//      (bytes) and `public let sha256: String` (64 lower-case hex digits), and
//      `public init(name: String, size: Int, sha256: String)`. The public init is the injection point that
//      lets a test (and ModelDownload's tests) use a small synthetic expected size and hash.
//   2. `ModelFiles.all: [ModelFile]` holds exactly the two files of design section 7, text file first.
//   3. `ModelFiles.sha256(of url: URL) throws -> String` hashes the file in 8 MB pieces and returns the
//      lower-case hex digest.
//   4. `ModelFiles.isPresent(_ file: ModelFile, at url: URL) -> Bool` is true only when the file at `url`
//      has exactly `file.size` bytes and SHA-256 `file.sha256`. A missing or unreadable file is `false`
//      (it never throws and never traps).

private let mfTextName = "embeddinggemma-2-Q8_0.gguf"
private let mfTextSize = 309_855_456
private let mfTextHash = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
private let mfMMName = "mmproj-embeddinggemma-2-Q8_0.gguf"
private let mfMMSize = 554_821_024
private let mfMMHash = "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f"

private func mfHex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// Deterministic, non-repeating bytes, so a hash that only read the first piece (or the last) differs.
private func mfPattern(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var out = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        out[i] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(out)
}

private let mfBase: Data = mfPattern(20_000_000, seed: 7)

private func mfWithTempFolder(_ body: (URL) throws -> Void) throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory
        .appendingPathComponent("sesame-modelfiles-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    try body(folder)
}

// The kit's model cache: `$KIT_ROOT/cache`, KIT_ROOT defaulting to `$TMPDIR/sesame-kit` (scripts/kit-lib/common.sh).
private let mfCacheFolder: URL? = {
    let env = ProcessInfo.processInfo.environment
    let root: String
    if let kit = env["KIT_ROOT"], !kit.isEmpty {
        root = kit
    } else if let tmp = env["TMPDIR"], !tmp.isEmpty {
        root = (tmp as NSString).appendingPathComponent("sesame-kit")
    } else {
        return nil
    }
    return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("cache", isDirectory: true)
}()

private let mfCachePresent: Bool = {
    guard let cache = mfCacheFolder else { return false }
    let fm = FileManager.default
    for (name, size) in [(mfTextName, mfTextSize), (mfMMName, mfMMSize)] {
        let path = cache.appendingPathComponent(name).path
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              (attributes[.size] as? Int) == size else { return false }
    }
    return true
}()

private func mfFile(named name: String) throws -> ModelFile {
    try #require(ModelFiles.all.first { $0.name == name }, "ModelFiles.all has no file named \(name)")
}

@Suite("ModelFilesTests")
struct ModelFilesTests {

    // MARK: the two names, sizes and SHA-256 of design section 7

    @Test func holdsTheTwoNamesSizesAndHashesOfDesignSection7() throws {
        #expect(ModelFiles.all.map(\.name) == [mfTextName, mfMMName])
        let text = try mfFile(named: mfTextName)
        #expect(text.size == 309_855_456)
        #expect(text.sha256 == "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135")
        let mm = try mfFile(named: mfMMName)
        #expect(mm.size == 554_821_024)
        #expect(mm.sha256 == "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")
        #expect(ModelFiles.all.map(\.size).reduce(0, +) == 864_676_480)
    }

    // MARK: hashing in 8 MB pieces equals CryptoKit's own digest

    @Test(arguments: [
        0, 1, 4_096,
        7_999_999, 8_000_000, 8_000_001,
        8_388_607, 8_388_608, 8_388_609,
        16_777_216, 16_777_217, 20_000_000,
    ])
    func hashingInPiecesEqualsTheDigestCryptoKitComputes(size: Int) throws {
        try mfWithTempFolder { folder in
            let data = mfBase.prefix(size)
            let url = folder.appendingPathComponent("piece-\(size).bin")
            try Data(data).write(to: url)

            let mine = try ModelFiles.sha256(of: url)

            #expect(mine == mfHex(Data(data)), "size \(size)")
            #expect(mine.count == 64)
            #expect(mine == mine.lowercased())
        }
    }

    // MARK: size and SHA-256 both have to be right

    @Test func aFileWithTheRightSizeAndHashIsPresent() throws {
        try mfWithTempFolder { folder in
            let data = mfBase.prefix(1_000_003)
            let url = folder.appendingPathComponent("whole.gguf")
            try Data(data).write(to: url)
            let expected = ModelFile(name: "whole.gguf", size: data.count, sha256: mfHex(Data(data)))

            #expect(ModelFiles.isPresent(expected, at: url))
        }
    }

    @Test(arguments: [0, 500_001, 1_000_002])
    func oneFlippedByteMeansNotPresent(position: Int) throws {
        try mfWithTempFolder { folder in
            let original = Data(mfBase.prefix(1_000_003))
            var flipped = original
            flipped[position] ^= 0xFF
            let url = folder.appendingPathComponent("flipped.gguf")
            try flipped.write(to: url)
            let expected = ModelFile(name: "flipped.gguf", size: original.count, sha256: mfHex(original))

            #expect(try Data(contentsOf: url).count == original.count)
            #expect(!ModelFiles.isPresent(expected, at: url), "byte \(position) flipped")
        }
    }

    @Test func aFlippedByteInThePieceAfterTheFirstEightMegabytesMeansNotPresent() throws {
        try mfWithTempFolder { folder in
            let original = Data(mfBase.prefix(9_000_000))
            var flipped = original
            flipped[8_700_000] ^= 0x01
            let url = folder.appendingPathComponent("flipped-late.gguf")
            try flipped.write(to: url)
            let expected = ModelFile(name: "flipped-late.gguf", size: original.count, sha256: mfHex(original))

            #expect(!ModelFiles.isPresent(expected, at: url))
        }
    }

    @Test(arguments: [0, 1_000_002, 500_001, 8])
    func aTruncatedCopyIsNotPresent(keeping length: Int) throws {
        try mfWithTempFolder { folder in
            let original = Data(mfBase.prefix(1_000_003))
            let url = folder.appendingPathComponent("truncated.gguf")
            try original.prefix(length).write(to: url)
            let expected = ModelFile(name: "truncated.gguf", size: original.count, sha256: mfHex(original))

            #expect(!ModelFiles.isPresent(expected, at: url), "kept \(length) bytes")
        }
    }

    @Test func aFileWithOneExtraByteIsNotPresent() throws {
        try mfWithTempFolder { folder in
            let original = Data(mfBase.prefix(1_000_003))
            let url = folder.appendingPathComponent("longer.gguf")
            try (original + Data([0x00])).write(to: url)
            let expected = ModelFile(name: "longer.gguf", size: original.count, sha256: mfHex(original))

            #expect(!ModelFiles.isPresent(expected, at: url))
        }
    }

    @Test func rightBytesButAWrongExpectedSizeOrHashIsNotPresent() throws {
        try mfWithTempFolder { folder in
            let data = Data(mfBase.prefix(1_000_003))
            let url = folder.appendingPathComponent("bytes.gguf")
            try data.write(to: url)
            let hash = mfHex(data)
            var wrongHash = hash
            wrongHash.removeLast()
            wrongHash.append(hash.last == "0" ? "1" : "0")

            #expect(ModelFiles.isPresent(ModelFile(name: "bytes.gguf", size: data.count, sha256: hash), at: url))
            #expect(!ModelFiles.isPresent(ModelFile(name: "bytes.gguf", size: data.count + 1, sha256: hash), at: url))
            #expect(!ModelFiles.isPresent(ModelFile(name: "bytes.gguf", size: data.count - 1, sha256: hash), at: url))
            #expect(!ModelFiles.isPresent(ModelFile(name: "bytes.gguf", size: data.count, sha256: wrongHash), at: url))
        }
    }

    @Test func aMissingFileIsNotPresent() throws {
        try mfWithTempFolder { folder in
            let expected = ModelFile(name: "nothing.gguf", size: 10, sha256: mfHex(Data(count: 10)))

            #expect(!ModelFiles.isPresent(expected, at: folder.appendingPathComponent("nothing.gguf")))
        }
    }

    // MARK: the real files in the kit cache (skipped, and reported as skipped, when the cache is empty)

    @Test(.enabled(if: mfCachePresent, "the kit cache holds both whole model files"),
          arguments: [mfTextName, mfMMName])
    func theCachedModelFileIsPresent(name: String) throws {
        let cache = try #require(mfCacheFolder)
        let file = try mfFile(named: name)

        #expect(ModelFiles.isPresent(file, at: cache.appendingPathComponent(name)))
        #expect(try ModelFiles.sha256(of: cache.appendingPathComponent(name)) == file.sha256)
    }

    @Test(.enabled(if: mfCachePresent, "the kit cache holds both whole model files"))
    func theCachedTextModelWithOneFlippedByteIsNotPresent() throws {
        let cache = try #require(mfCacheFolder)
        let file = try mfFile(named: mfTextName)
        try mfWithTempFolder { folder in
            let copy = folder.appendingPathComponent(mfTextName)
            try FileManager.default.copyItem(at: cache.appendingPathComponent(mfTextName), to: copy)
            let handle = try FileHandle(forUpdating: copy)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(file.size / 2))
            let byte = try #require(try handle.read(upToCount: 1))
            try handle.seek(toOffset: UInt64(file.size / 2))
            try handle.write(contentsOf: Data([byte[0] ^ 0xFF]))
            try handle.synchronize()

            #expect(!ModelFiles.isPresent(file, at: copy))
        }
    }

    @Test(.enabled(if: mfCachePresent, "the kit cache holds both whole model files"),
          arguments: [1, 1_000_000])
    func aTruncatedCopyOfTheCachedTextModelIsNotPresent(cutOff: Int) throws {
        let cache = try #require(mfCacheFolder)
        let file = try mfFile(named: mfTextName)
        try mfWithTempFolder { folder in
            let copy = folder.appendingPathComponent(mfTextName)
            try FileManager.default.copyItem(at: cache.appendingPathComponent(mfTextName), to: copy)
            let handle = try FileHandle(forUpdating: copy)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(file.size - cutOff))
            try handle.synchronize()

            #expect(!ModelFiles.isPresent(file, at: copy), "\(cutOff) bytes cut off")
        }
    }
}
