import Foundation
import Testing
import SesameEngine

// plan-5-t3, tester step. Written from the entry plan-5-t3 of plan-5-tasks.md (Tests: HelperVideoModelTests) and Decision D3 only; no product source
// is read. One helper run per test with the cached real model (the kit's model cache `$KIT_ROOT/cache`, read, never wiped or written): the bundled
// release helper, `index` mode with `--text-model` and `--mm-model`, a throwaway HOME. These tests are meant to run in the background: the model
// loads and every frame goes through it.
//
// What the entry asks, and how it is split by D3 (loading the audio tower exceeds the 0.85 GB cap; parked until the person decides):
//   - ENABLED (the vision path only: frames, the image model loaded with `vision_only`): a video with no soundtrack and a golden video with no
//     audio track are `done`, never `could_not_read`; every frame passage holds a vector (not NULL, modality image) that is 768 finite numbers of unit
//     length within 0.02 and not all alike; `meta.vector_source` is the real one; the test polls the helper's footprint every 250 ms and prints the
//     peak (`READING video footprint peak ...`): under the watchdog cap 850,000,000 and no `needed too much memory`. A peak at or over the cap is a
//     STOP-ASK (D3), and the table and the cap are never changed by anyone but the person.
//   - DISABLED with the D3 reason (it needs the audio tower to LOAD): the golden clip with a spoken soundtrack, one helper run, a frame's vector
//     (image) and a window's vector (audio), so the model swap `.image` then `.audio` worked inside the cap. Its assertions are the entry's, unchanged;
//     remove the `.disabled(...)` trait to run it once the person has decided.

private let hvmCap = 850_000_000.0

private struct HvmModels {
    let text: URL
    let mm: URL
}

private func hvmModels() throws -> HvmModels {
    let text = try #require(KitPaths.textModel(),
                            "model file missing: $KIT_ROOT/cache/\(KitPaths.textModelName) (seed the cache: scripts/kit-mirror.sh seed --real)")
    let mm = text.deletingLastPathComponent().appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf")
    try #require(FileManager.default.fileExists(atPath: mm.path), "model file missing: \(mm.path) (seed the cache: scripts/kit-mirror.sh seed --real)")
    return HvmModels(text: text, mm: mm)
}

private func hvmCosine(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for index in 0..<min(a.count, b.count) {
        dot += a[index] * b[index]; na += a[index] * a[index]; nb += b[index] * b[index]
    }
    return dot / (na.squareRoot() * nb.squareRoot())
}

private struct HvmRun {
    var status = "none"
    var reason: String?
    var peakBytes = 0.0
    var lifetimeBytes = 0.0
    var samples = 0
    var stderr = ""
    var exit: Int32?
    var source: String?
    var rows: [(id: String, source: String, modality: String, bytes: String, hex: String)] = []
}

/// Runs the helper over `folder` (`file` is the one file to wait for), sampling the footprint, then reads the index of `world`.
private func hvmRun(_ world: AtWorld, folder: URL, file: String, models: HvmModels) throws -> HvmRun {
    var run = HvmRun()
    let rig = try PipeRig(helper: KitPaths.bundledHelper, home: world.home, models: (models.text, models.mm), scratch: world.root)
    defer { rig.cleanup() }
    rig.send(atFoldersLine([folder]))
    let started = Date()
    var lastChange = started
    var lastStatus = ""
    var db: AtDB?
    while Date().timeIntervalSince(started) < 1200 {
        if let footprint = Tools.footprintMB(pid: rig.pid) {
            run.peakBytes = max(run.peakBytes, footprint * 1_048_576)
            run.samples += 1
        }
        if db == nil { db = world.db() }
        if let row = db.flatMap(mrRows)?[file] {
            run.status = row.status
            run.reason = row.reason
            if run.status != lastStatus { lastStatus = run.status; lastChange = Date() }
            if mrIsFinal(run.status) { break }
        }
        if run.status == "none" && Date().timeIntervalSince(started) > 240 { break }
        if Date().timeIntervalSince(lastChange) > 600 || !rig.isRunning { break }
        _ = rig.read(cap: 0.25, until: { false })
    }
    run.lifetimeBytes = (Tools.footprintLifetimeMaxMB(pid: rig.pid) ?? 0) * 1_048_576
    run.stderr = rig.stderrText
    rig.closeStdin()
    run.exit = rig.waitForExit(timeout: 120)?.status
    if let end = world.db() {
        run.rows = (end.rows("select p.id, p.source, p.modality, coalesce(length(p.vec), -1), coalesce(hex(p.vec), '') from passages p join files f on f.id = p.file_id where f.path like '%/\(file)' order by p.start, p.id") ?? [])
            .map { (id: $0[0] ?? "?", source: $0[1] ?? "", modality: $0[2] ?? "", bytes: $0[3] ?? "", hex: $0[4] ?? "") }
    }
    homeLock.lock()
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", world.home.path, 1)
    let reader = IndexReader()
    run.source = reader.meta("vector_source")
    reader.close()
    if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
    homeLock.unlock()
    return run
}

private func hvmCheckFrames(_ run: HvmRun, expectedSeconds: [Int]?, label: String) {
    print("READING video footprint peak polled=\(Int(run.peakBytes)) bytes (\(run.samples) samples) lifetime max=\(Int(run.lifetimeBytes)) bytes cap=\(Int(hvmCap)) (\(label))")
    #expect(run.status == "done",
            "\(label) should be done, got \(run.status) (\(run.reason ?? "no reason")); if it is could_not_read this may be the model or the memory cap: STOP-ASK (D3). stderr: \(run.stderr.prefix(300))")
    #expect(run.reason != "needed too much memory" && !run.stderr.contains("needed too much memory"),
            "STOP-ASK (D3): the helper gave \(label) up for memory: reason \(run.reason ?? "none"), stderr \(run.stderr.prefix(300))")
    #expect(run.samples > 0 && run.peakBytes < hvmCap,
            "STOP-ASK (D3): the polled footprint peak is \(Int(run.peakBytes)) bytes over \(run.samples) samples, the cap is \(Int(hvmCap))")
    #expect(run.exit == 0, "the helper should exit 0 within 120 s of its stdin ending, got \(run.exit.map(String.init) ?? "still running")")
    let frames = run.rows.filter { $0.source == "frame" }
    #expect(!frames.isEmpty, "\(label) holds no frame passage")
    var decoded: [[Double]] = []
    for row in frames {
        #expect(row.modality == "image" && row.bytes == "1536", "frame passage \(row.id) is \(row.modality) with \(row.bytes) vector bytes (NULL is -1), expected image with 1536")
        let vector = MediaRig.halfVector(hex: row.hex)
        let length = vector.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        #expect(vector.count == 768 && vector.allSatisfy { $0.isFinite } && abs(length - 1) < 0.02,
                "a frame vector is not 768 finite numbers of unit length (count \(vector.count), length \(length))")
        decoded.append(vector)
    }
    var lowest = 1.0
    for first in decoded.indices { for second in decoded.indices where second > first { lowest = min(lowest, hvmCosine(decoded[first], decoded[second])) } }
    print("READING video frame vectors: lowest pairwise cosine \(lowest) over \(decoded.count) frames (\(label))")
    #expect(decoded.count < 2 || lowest < 0.99999, "every frame of \(label) has the same vector (lowest pairwise cosine \(lowest)): the pictures differ, the vectors must")
    if let expectedSeconds {
        let seconds = run.rows.filter { $0.source == "frame" }.count
        #expect(seconds == expectedSeconds.count, "\(label) holds \(seconds) frame passages, expected \(expectedSeconds.count)")
    }
    #expect(run.source == LlamaEmbedder.vectorSource, "meta.vector_source is \(run.source ?? "nil"), expected \(LlamaEmbedder.vectorSource)")
}

extension EncodeHelperTests {
@Suite("HelperVideoModelTests", .serialized)
struct HelperVideoModelTests {

    // A video with no audio track, six shots of 10 s: the first samples inside the shots are seconds 0, 12, 21, 30, 42 and 51, so six frames.
    @Test func aVideoWithNoSoundtrackIsDoneWithRealFrameVectorsInsideTheMemoryCap() throws {
        let models = try hvmModels()
        let world = try AtWorld()
        defer { world.remove() }
        let clip = world.photos.appendingPathComponent("realframesvideo.mp4").path
        try MediaRig.writeVideo(clip, shots: MediaRig.shots(Array(repeating: 10, count: 6)))
        try mrAge(clip, 1)
        let run = try hvmRun(world, folder: world.photos, file: "realframesvideo.mp4", models: models)
        hvmCheckFrames(run, expectedSeconds: [0, 12, 21, 30, 42, 51], label: "the six-shot clip")
        let seconds = (world.db()?.rows("select cast(start as integer) from passages p join files f on f.id = p.file_id where f.path like '%/realframesvideo.mp4' and p.source = 'frame' order by p.start") ?? []).compactMap { $0[0].flatMap { Int($0) } }
        #expect(seconds == [0, 12, 21, 30, 42, 51], "the frame seconds are \(seconds), expected [0, 12, 21, 30, 42, 51]")
    }

    // A golden video with no audio track (safari-zebra.mp4, a scene from 42 s): vision only, the model loaded for pictures.
    @Test func aGoldenVideoWithNoAudioTrackIsDoneWithRealFrameVectorsInsideTheMemoryCap() throws {
        let models = try hvmModels()
        let golden = mrGoldenAV
        if let problem = golden.problem { Issue.record("setup failed: \(problem)"); return }
        let world = try AtWorld()
        defer { world.remove() }
        let folder = world.photos.appendingPathComponent("golden", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: golden.av + "/video/safari-zebra.mp4", toPath: folder.appendingPathComponent("safari-zebra.mp4").path)
        let run = try hvmRun(world, folder: folder, file: "safari-zebra.mp4", models: models)
        hvmCheckFrames(run, expectedSeconds: nil, label: "safari-zebra.mp4")
        let frames = run.rows.filter { $0.source == "frame" }
        #expect(frames.count >= 3, "safari-zebra.mp4 holds \(frames.count) frame passages, expected at least 3 (five scenes)")
    }

    // The spoken soundtrack needs the audio tower: enabled now that D3 is fixed (audio-only switch), assertions unchanged.
    @Test func aGoldenVideoWithSpeechHasARealFrameVectorAndARealWindowVectorInOneRunSoTheModelSwapWorkedInsideTheCap() throws {
        let models = try hvmModels()
        let golden = mrGoldenAV
        if let problem = golden.problem { Issue.record("setup failed: \(problem)"); return }
        let world = try AtWorld()
        defer { world.remove() }
        let folder = world.photos.appendingPathComponent("golden", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: golden.av + "/video/clip-v11.mp4", toPath: folder.appendingPathComponent("clip-v11.mp4").path)
        let run = try hvmRun(world, folder: folder, file: "clip-v11.mp4", models: models)
        hvmCheckFrames(run, expectedSeconds: [0], label: "clip-v11.mp4")
        let windows = run.rows.filter { $0.source == "audio" }
        #expect(windows.count == 1, "clip-v11.mp4 holds \(windows.count) audio window passages, expected 1")
        for row in windows {
            #expect(row.modality == "audio" && row.bytes == "1536", "window passage \(row.id) is \(row.modality) with \(row.bytes) vector bytes, expected audio with 1536 (STOP-ASK if the audio tower did not embed: D3)")
            let vector = MediaRig.halfVector(hex: row.hex)
            let length = vector.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
            #expect(vector.count == 768 && vector.allSatisfy { $0.isFinite } && abs(length - 1) < 0.02, "a window vector is not 768 finite numbers of unit length (count \(vector.count), length \(length))")
        }
    }
}
}
