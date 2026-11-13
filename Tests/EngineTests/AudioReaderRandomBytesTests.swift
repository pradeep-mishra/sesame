import Foundation
import Testing
import SesameEngine

// plan-5-t3 test-side repair, tester step. A user's broken audio file must give `unreadable` and never kill the helper. The implementer's whole-suite run
// died once from an uncaught ObjC exception (AVAudioFile.setFramePosition, error 1718449215) on random bytes under an audio name, so the bytes here are
// SEEDED: the same blobs on every run. No product source is read.
//
// An ObjC exception cannot be caught by a test, it ends the process, so the blobs go through the bundled release helper (`dist/Sesame.app`, run
// `scripts/bundle.sh` first), one throwaway HOME per extension, the fake embedder. The helper reads the folder; the test expects every file to end
// `could_not_read` with reason `damaged` or, where the system decoder really reads the bytes as sound (a valid WAV header over random samples, random bytes
// with an MPEG sync), `done`; the helper never to die; and the helper to exit 0 at the end of its stdin. The count of `done` files is printed as a reading,
// it is not a pass condition. When the helper dies the test starts it
// again over the same index (as the app does) and counts the deaths; the file named in a death is the first file not yet settled, because the files are
// aged so the helper reads them in the order of `arbSpecs` (newest first).
//
// The blobs, per extension (mp3, m4a, wav, aac, flac):
//   plain: seeds 1 to 300, each at 16, 64, 1,000, 4,096 and 50,000 bytes of random bytes (1,500 files);
//   riff, ftyp, id3, adts, flac, mpeg: a header that looks like the format (RIFF/WAVE with a fmt chunk of random fields and a data chunk of a random size,
//     an ftyp box and a following box of random size, an ID3 tag of random size, an ADTS sync, fLaC with a STREAMINFO block, an MPEG frame sync) followed by
//     random bytes, seeds 1 to 300, the size of the random part from the five sizes by `seed % 5` (300 files each, under every extension).
//
// SHAPES THIS FILE PINS that the brief did not fix: a file name is `<shape>-s<seed>-n<size>.<ext>`; the blob of a seed differs under each extension and each shape.

private let arbExtensions = ["mp3", "m4a", "wav", "aac", "flac"]
private let arbSizes = [16, 64, 1_000, 4_096, 50_000]

private enum ArbShape: String, CaseIterable {
    case plain, riff, ftyp, id3, adts, flac, mpeg
}

private struct ArbSpec {
    let shape: ArbShape
    let seed: Int
    let size: Int
}

private struct ArbSplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func arbSpecs() -> [ArbSpec] {
    var list: [ArbSpec] = []
    for seed in 1...300 { for size in arbSizes { list.append(ArbSpec(shape: .plain, seed: seed, size: size)) } }
    for shape in ArbShape.allCases where shape != .plain {
        for seed in 1...300 { list.append(ArbSpec(shape: shape, seed: seed, size: arbSizes[seed % arbSizes.count])) }
    }
    return list
}

private func arbName(_ spec: ArbSpec, _ ext: String) -> String { "\(spec.shape.rawValue)-s\(spec.seed)-n\(spec.size).\(ext)" }

private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
private func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(8 * $0)) } }
private func be32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * $0)) } }
private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

private func arbPick<T>(_ generator: inout ArbSplitMix, _ options: [T]) -> T {
    options[Int(generator.next() % UInt64(options.count))]
}

private func arbFill(_ generator: inout ArbSplitMix, _ count: Int) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(count + 8)
    while out.count < count {
        var word = generator.next()
        for _ in 0..<8 { out.append(UInt8(truncatingIfNeeded: word)); word >>= 8 }
    }
    out.removeLast(out.count - count)
    return out
}

private func arbData(_ spec: ArbSpec, _ ext: String) -> Data {
    let extIndex = arbExtensions.firstIndex(of: ext) ?? 0
    let shapeIndex = ArbShape.allCases.firstIndex(of: spec.shape) ?? 0
    let mixed = (UInt64(spec.seed) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(shapeIndex) << 40) ^ (UInt64(extIndex) << 48) ^ UInt64(spec.size)
    var generator = ArbSplitMix(state: mixed)
    var head: [UInt8] = []
    switch spec.shape {
    case .plain:
        break
    case .riff:
        let fmtSize = arbPick(&generator, [UInt32(16), 18, 40, UInt32(truncatingIfNeeded: generator.next())])
        let dataSize = arbPick(&generator, [UInt32(0), 0xFFFF_FFFF, UInt32(truncatingIfNeeded: generator.next()), UInt32(spec.size)])
        head += ascii("RIFF") + le32(UInt32(truncatingIfNeeded: generator.next())) + ascii("WAVE") + ascii("fmt ") + le32(fmtSize)
        head += le16(arbPick(&generator, [1, 3, 0xFFFE, 0x55, UInt16(truncatingIfNeeded: generator.next())]))
        head += le16(arbPick(&generator, [0, 1, 2, 6, 255, UInt16(truncatingIfNeeded: generator.next())]))
        head += le32(arbPick(&generator, [0, 8000, 16000, 44100, 96000, UInt32(truncatingIfNeeded: generator.next())]))
        head += le32(UInt32(truncatingIfNeeded: generator.next()))
        head += le16(UInt16(truncatingIfNeeded: generator.next()))
        head += le16(arbPick(&generator, [0, 8, 16, 24, 32, 64, UInt16(truncatingIfNeeded: generator.next())]))
        head += ascii("data") + le32(dataSize)
    case .ftyp:
        let brand = arbPick(&generator, ["M4A ", "mp42", "isom", "qt  ", "M4B "])
        let boxType = arbPick(&generator, ["moov", "mdat", "free", "wide", "trak"])
        head += be32(arbPick(&generator, [0x18, 0x20, 0, 1, UInt32(truncatingIfNeeded: generator.next())])) + ascii("ftyp") + ascii(brand) + be32(0)
        head += ascii(brand) + ascii("mp42") + ascii("isom")
        head += be32(UInt32(truncatingIfNeeded: generator.next())) + ascii(boxType)
    case .id3:
        let syncsafe = (0..<4).map { _ in UInt8(truncatingIfNeeded: generator.next()) & 0x7F }
        head += ascii("ID3") + [arbPick(&generator, [2, 3, 4]), 0, UInt8(truncatingIfNeeded: generator.next())] + syncsafe
    case .adts:
        head += [0xFF, arbPick(&generator, [0xF1, 0xF9]), UInt8(truncatingIfNeeded: generator.next()), UInt8(truncatingIfNeeded: generator.next()),
                 UInt8(truncatingIfNeeded: generator.next()), UInt8(truncatingIfNeeded: generator.next()), UInt8(truncatingIfNeeded: generator.next())]
    case .flac:
        head += ascii("fLaC") + [0x00, 0x00, 0x00, 0x22] + arbFill(&generator, 34)
    case .mpeg:
        head += [0xFF, arbPick(&generator, [0xFB, 0xFA, 0xF3, 0xE3]), UInt8(truncatingIfNeeded: generator.next()), UInt8(truncatingIfNeeded: generator.next())]
    }
    return Data(head + arbFill(&generator, spec.size))
}

// MARK: the helper batch

private struct ArbBatch {
    var expected = 0
    var settled = false
    var stalled = false
    var deaths = 0
    var culprits: [String] = []
    var lastStatus: Int32?
    var rows: [String: MrRow] = [:]
    var exit: Int32?
    var seconds = 0.0
}

private func arbRunHelper(ext: String) throws -> ArbBatch {
    let world = try AtWorld()
    defer { world.remove() }
    let specs = arbSpecs()
    var order: [String: Int] = [:]
    for (index, spec) in specs.enumerated() {
        let name = arbName(spec, ext)
        let path = world.photos.appendingPathComponent(name).path
        try arbData(spec, ext).write(to: URL(fileURLWithPath: path))
        try mrAge(path, index)
        order[name] = index
    }
    var batch = ArbBatch()
    batch.expected = specs.count
    let started = Date()
    for _ in 0..<600 {
        if Date().timeIntervalSince(started) > 420 { batch.stalled = true; break }
        let helper = try atStartHelper(world)
        helper.send(atFoldersLine([world.photos]))
        let wait = mrWaitSettled(world, helper, expected: specs.count, quiet: 2, stall: 90, cap: 1_500)
        batch.rows = wait.rows
        if wait.met {
            helper.closeStdin()
            batch.exit = helper.waitForExit(timeout: 60)?.status
            if batch.exit == nil { helper.stop() }
            batch.settled = true
            break
        }
        if helper.isRunning {
            batch.stalled = true
            helper.stop()
            break
        }
        let ended = helper.waitForExit(timeout: 5)
        let open = wait.rows.filter { !mrIsFinal($0.value.status) }.keys.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
        batch.deaths += 1
        batch.lastStatus = ended?.status
        if let first = open.first, !batch.culprits.contains(first) { batch.culprits.append(first) }
        helper.stop()
    }
    batch.seconds = Date().timeIntervalSince(started)
    return batch
}

private func arbCheck(_ ext: String) throws {
    let batch = try arbRunHelper(ext: ext)
    let readAsAudio = batch.rows.values.filter { $0.status == "done" }.count
    let offenders = batch.rows.filter { !($0.value.status == "done" || ($0.value.status == "could_not_read" && $0.value.reason == "damaged")) }
    let sample = offenders.keys.sorted().prefix(8).map { "\($0)=\(offenders[$0]!.status)(\(offenders[$0]!.reason ?? "no reason")) tries \(offenders[$0]!.tries)" }
    let offenderCount = offenders.count
    let byShape = Dictionary(grouping: batch.culprits) { String($0.prefix { $0 != "-" }) }.mapValues(\.count)
    print("READING random bytes under .\(ext): \(batch.expected) files, helper deaths \(batch.deaths), files that killed it \(batch.culprits.count) \(byShape.sorted { $0.key < $1.key }), read as audio by the system decoder (done) \(readAsAudio), other end states \(offenderCount), \(Int(batch.seconds)) s")
    #expect(batch.deaths == 0, "the helper died \(batch.deaths) time(s) (last status \(batch.lastStatus.map(String.init) ?? "unknown"), 6 is abort) reading the .\(ext) blobs; \(batch.culprits.count) files killed it, by shape \(byShape.sorted { $0.key < $1.key }), the first: \(batch.culprits.prefix(6))")
    #expect(!batch.stalled, "the .\(ext) run was cut off (the helper stopped answering, or 420 s passed) with \(batch.rows.count) of \(batch.expected) files in the index")
    #expect(batch.settled, "the .\(ext) blobs did not all settle: \(batch.rows.count) rows of \(batch.expected), \(offenderCount) in another end state; \(sample)")
    let allEndWell = offenderCount == 0
    #expect(allEndWell, "\(offenderCount) of \(batch.expected) .\(ext) blobs ended neither could_not_read (damaged) nor done: \(sample)")
    #expect(batch.exit == 0, "the helper should exit 0 within 60 s of its stdin ending, status \(batch.exit.map(String.init) ?? "still running")")
}

extension EncodeHelperTests {
@Suite("AudioReaderRandomBytesHelperTests", .serialized)
struct AudioReaderRandomBytesHelperTests {
    @Test func randomAndHeaderedBlobsUnderMp3NeverKillTheHelperAndEveryFileSettles() throws { try arbCheck("mp3") }
    @Test func randomAndHeaderedBlobsUnderM4aNeverKillTheHelperAndEveryFileSettles() throws { try arbCheck("m4a") }
    @Test func randomAndHeaderedBlobsUnderWavNeverKillTheHelperAndEveryFileSettles() throws { try arbCheck("wav") }
    @Test func randomAndHeaderedBlobsUnderAacNeverKillTheHelperAndEveryFileSettles() throws { try arbCheck("aac") }
    @Test func randomAndHeaderedBlobsUnderFlacNeverKillTheHelperAndEveryFileSettles() throws { try arbCheck("flac") }
}
}

// MARK: in process, the set that does not kill the test process today

// A death here would end the whole test run, so only the blobs that were seen to survive are read in the process: plain random blobs of 16 and 64 bytes, seeds 1 to 20
// (the helper batches above find the ones that kill). Every one is expected to throw `unreadable`: random bytes of that length hold no decodable frame.
@Suite("AudioReaderRandomBytesTests", .serialized)
struct AudioReaderRandomBytesTests {
    @Test func shortPlainRandomBlobsUnderEveryAudioExtensionThrowUnreadable() throws {
        try mrWithDir { dir in
            var wrong: [String] = []
            var count = 0
            for ext in arbExtensions {
                for seed in 1...20 {
                    for size in [16, 64] {
                        let spec = ArbSpec(shape: .plain, seed: seed, size: size)
                        let path = dir.file(arbName(spec, ext))
                        try arbData(spec, ext).write(to: URL(fileURLWithPath: path))
                        let known = try #require(mrSeen(path))
                        count += 1
                        do {
                            _ = try AudioReader.read(path: path, expecting: mrIdentity(known), fromSecond: 0, scratch: Scratch(), shouldStop: { false })
                            wrong.append("\(arbName(spec, ext)) read")
                        } catch let error as AudioReadError {
                            if "\(error)" != "unreadable" { wrong.append("\(arbName(spec, ext)) threw \(error)") }
                        } catch {
                            wrong.append("\(arbName(spec, ext)) threw \(error)")
                        }
                    }
                }
            }
            #expect(count == 200, "the set holds \(count) blobs, expected 200")
            #expect(wrong.isEmpty, "\(wrong.count) of \(count) short random blobs did not throw unreadable: \(wrong.prefix(8))")
        }
    }
}
