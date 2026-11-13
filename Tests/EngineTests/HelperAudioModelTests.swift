import Foundation
import Testing
import SesameEngine

// plan-5-t2, tester step. Written from the entry plan-5-t2 of plan-5-tasks.md (Tests: HelperAudioModelTests) and Decision D3 only; no
// product source is read. One helper run with the cached real model (the kit's model cache `$KIT_ROOT/cache`, read, never wiped or
// written): the bundled release helper, `index` mode with `--text-model` and `--mm-model`, a throwaway HOME, one 240 s clip (eight
// 30 s blocks, each a different tone, so ten windows, starts 0 to 225 by 25). This test is meant to run in the background: the model
// loads and every window goes through it.
//
// What the entry asks, and what is asserted:
//   - the clip is `done`, never `could_not_read` (and no `needed too much memory` reason);
//   - every window passage holds a vector (not NULL, modality audio) and `meta.vector_source` is the real one
//     (`LlamaEmbedder.vectorSource`), not the fake's;
//   - the test polls the helper's footprint every 250 ms and prints the peak (`READING audio footprint peak ...`): under the
//     watchdog cap 850,000,000 bytes, and no `needed too much memory` anywhere. A peak at or over the cap, or a clip the helper could
//     not embed because the audio tower is missing (`mtmd_support_audio` false), is a STOP-ASK (D3): this file then fails with the
//     words "STOP-ASK" in its message, and the table and the cap are not changed by anyone but the person.
//   - one more, against a stub that stores the same vector for every window: the vectors are 768 finite numbers of unit length within
//     0.02 and not all alike (some pair of windows has a cosine under 0.99999).

private let hmCap = 850_000_000.0

private struct HmModels {
    let text: URL
    let mm: URL
}

private func hmModels() throws -> HmModels {
    let text = try #require(KitPaths.textModel(),
                            "model file missing: $KIT_ROOT/cache/\(KitPaths.textModelName) (seed the cache: scripts/kit-mirror.sh seed --real)")
    let mm = text.deletingLastPathComponent().appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf")
    try #require(FileManager.default.fileExists(atPath: mm.path), "model file missing: \(mm.path) (seed the cache: scripts/kit-mirror.sh seed --real)")
    return HmModels(text: text, mm: mm)
}

private func hmCosine(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for index in 0..<min(a.count, b.count) {
        dot += a[index] * b[index]; na += a[index] * a[index]; nb += b[index] * b[index]
    }
    return dot / (na.squareRoot() * nb.squareRoot())
}

extension EncodeHelperTests {
@Suite("HelperAudioModelTests", .serialized)
struct HelperAudioModelTests {

    @Test func aFourMinuteClipIsDoneWithRealWindowVectorsInsideTheMemoryCap() throws {
        let models = try hmModels()
        let world = try AtWorld()
        defer { world.remove() }
        let clip = world.photos.appendingPathComponent("fourminuteclip.wav").path
        let blocks = (0..<8).map { MediaRig.Part.tone(30, db: -22, hz: 220 + 130 * Double($0)) }
        try MediaRig.writeWav(clip, blocks)
        try mrAge(clip, 1)

        let rig = try PipeRig(helper: KitPaths.bundledHelper, home: world.home, models: (models.text, models.mm), scratch: world.root)
        defer { rig.cleanup() }
        rig.send(atFoldersLine([world.photos]))

        var peakBytes = 0.0
        var samples = 0
        var status = "none"
        var reason: String?
        let started = Date()
        var lastChange = started
        var lastStatus = ""
        var db: AtDB?
        while Date().timeIntervalSince(started) < 1200 {
            if let footprint = Tools.footprintMB(pid: rig.pid) {
                peakBytes = max(peakBytes, footprint * 1_048_576)
                samples += 1
            }
            if db == nil { db = world.db() }
            if let row = db.flatMap(mrRows)?["fourminuteclip.wav"] {
                status = row.status
                reason = row.reason
                if status != lastStatus { lastStatus = status; lastChange = Date() }
                if mrIsFinal(status) { break }
            }
            if status == "none" && Date().timeIntervalSince(started) > 240 { break }
            if Date().timeIntervalSince(lastChange) > 600 || !rig.isRunning { break }
            _ = rig.read(cap: 0.25, until: { false })
        }
        let lifetime = (Tools.footprintLifetimeMaxMB(pid: rig.pid) ?? 0) * 1_048_576
        print("READING audio footprint peak polled=\(Int(peakBytes)) bytes (\(samples) samples) lifetime max=\(Int(lifetime)) bytes cap=\(Int(hmCap))")
        let stderrText = rig.stderrText
        #expect(status == "done",
                "the 4-minute clip should be done, got \(status) (\(reason ?? "no reason")); if it is could_not_read this may be the audio tower or the memory cap: STOP-ASK (D3). stderr: \(stderrText.prefix(300))")
        #expect(reason != "needed too much memory" && !stderrText.contains("needed too much memory"),
                "STOP-ASK (D3): the helper gave the clip up for memory: reason \(reason ?? "none"), stderr \(stderrText.prefix(300))")
        #expect(samples > 0 && peakBytes < hmCap,
                "STOP-ASK (D3): the polled footprint peak is \(Int(peakBytes)) bytes over \(samples) samples, the cap is \(Int(hmCap))")
        rig.closeStdin()
        let ended = rig.waitForExit(timeout: 120)
        #expect(ended?.status == 0, "the helper should exit 0 within 120 s of its stdin ending, got \(ended.map { String($0.status) } ?? "still running")")

        let end = try #require(world.db())
        let everything = try #require(mrPassages(end))
        let passages = everything["fourminuteclip.wav"] ?? []
        let windows = passages.filter { $0.source == "audio" }
        #expect(windows.map { $0.start ?? -1 }.sorted() == Array(stride(from: 0, through: 225, by: 25)),
                "the window starts are \(windows.map { $0.start ?? -1 }.sorted()), expected 0 to 225 by 25 (continuous sound)")
        let vectors = try #require(end.rows("select p.id, p.modality, coalesce(length(p.vec), -1), coalesce(hex(p.vec), '') from passages p where p.source = 'audio' order by p.start"))
        #expect(vectors.count == windows.count && vectors.count == 10, "window rows with a vector query: \(vectors.count), expected 10")
        var decoded: [[Double]] = []
        for row in vectors {
            #expect(row[1] == "audio" && row[2] == "1536", "passage \(row[0] ?? "?") is \(row[1] ?? "nil") with \(row[2] ?? "nil") vector bytes: STOP-ASK if the audio tower did not embed (D3)")
            let vector = MediaRig.halfVector(hex: row[3] ?? "")
            let length = vector.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
            #expect(vector.count == 768 && vector.allSatisfy { $0.isFinite } && abs(length - 1) < 0.02,
                    "a window vector is not 768 finite numbers of unit length (count \(vector.count), length \(length))")
            decoded.append(vector)
        }
        var lowest = 1.0
        for first in decoded.indices { for second in decoded.indices where second > first { lowest = min(lowest, hmCosine(decoded[first], decoded[second])) } }
        print("READING audio window vectors: lowest pairwise cosine \(lowest)")
        #expect(decoded.count < 2 || lowest < 0.99999, "every window of a clip whose blocks are eight different tones has the same vector (lowest pairwise cosine \(lowest))")

        homeLock.lock()
        let previousHome = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", world.home.path, 1)
        let reader = IndexReader()
        let source = reader.meta("vector_source")
        reader.close()
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        homeLock.unlock()
        #expect(source == LlamaEmbedder.vectorSource, "meta.vector_source is \(source ?? "nil"), expected \(LlamaEmbedder.vectorSource)")
    }
}
}
