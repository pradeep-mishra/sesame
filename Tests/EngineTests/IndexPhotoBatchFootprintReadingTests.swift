import Foundation
import Testing

// plan-1-t34, tester step. The memory stop of design section 8 (the `index` photo-batch peak against 0.80 GB, U8) and
// U9 (the first preview's start-up time with `index` not running). Written from the t34 entry, the "Reading tests"
// paragraph of the plan's Conventions and design sections 8 and 9 only; no product source read.
//
// The test starts the bundled RELEASE helper at dist/Sesame.app/Contents/MacOS/SesameHelper (never the debug build;
// the Run builds release and bundles just before it) in `index` mode over the 40 golden photos the kit builds, with
// HOME and TMPDIR at a throwaway folder and no fake embedder (a real model, real OCR). Round 2: the helper is given
// BOTH model paths, `--text-model` and `--mm-model`, because the image model cannot make a vector without the text
// model beside it (U8: answered No, measured: with `--mm-model` alone 0 of 40 photos are embedded; the entry's
// "image-and-audio model alone" is superseded). The bar is the same 0.80 GB, never lowered. While the batch runs it:
//   - samples the helper's phys footprint every 250 ms (`Tools.footprintMB`, Reading.swift: `proc_pid_rusage`,
//     the figure `footprint` prints, read without spawning anything) and, with each sample, the lifetime maximum
//     the kernel keeps (`Tools.footprintLifetimeMaxMB`), which cannot miss a spike between two samples,
//   - sends one `preview` of fixtures/golden/photos/beach-dog.jpg once 3 photos are done (so the render happens
//     between embed units with the model loaded, the worst row of the memory table), and
//   - waits until all 40 photos are `done`.
// Prints   READING index_photo_peak_gb=<n>   (peak footprint, the larger of the sampled peak and the kernel's
// lifetime maximum, GB of 1024 MB, two decimals), and checks the peak
// against the 0.80 GB bar with `Reading.check` in MB (0.80 x 1024 = 819.2 MB), because `Reading.format` prints one
// decimal and a GB figure of 0.76 would read as 0.8. It asserts that all 40 photos reached `done` and that the preview
// reply is `ok`. The bar is never lowered.
// Then the helper is let to exit (stdin EOF), a fresh `index` helper with no work is started over the same HOME, sent
// the same `preview`, and
//   READING U9 first_preview_ms=<n>
// is printed: the time from just before the process starts to the moment its reply line is read. U9 has no bar here;
// its figure goes to the report.
//
// The first text recognition in a freshly built helper compiles its model (about 35 s after a rebuild), so the stall
// limit is generous.

private let barGB = 0.80
private let mmModelName = "mmproj-embeddinggemma-2-Q8_0.gguf"
private let textModelName = "embeddinggemma-2-Q8_0.gguf"

private func t34KitRoot() -> URL? {
    let env = ProcessInfo.processInfo.environment
    if let kit = env["KIT_ROOT"], !kit.isEmpty { return URL(fileURLWithPath: kit, isDirectory: true) }
    if let tmp = env["TMPDIR"], !tmp.isEmpty {
        return URL(fileURLWithPath: (tmp as NSString).appendingPathComponent("sesame-kit"), isDirectory: true)
    }
    return nil
}

/// The same advisory lock IndexPhotosTests and GroupATests take while the golden folder is built, so no two
/// builds of it overlap.
private func t34WithGoldenLock<T>(_ kit: URL, _ body: () throws -> T) rethrows -> T {
    let path = kit.appendingPathComponent(".t32-golden.lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return try body()
}

extension EncodeHelperTests {
@Suite("IndexPhotoBatchFootprintReadingTests", .serialized)
struct IndexPhotoBatchFootprintReadingTests {

    @Test func theIndexHelperWithBothModelsFitsTheMemoryBarOverTheGoldenPhotosAndAPreviewAndTheFirstPreviewIsTimed() throws {
        let helperURL = KitPaths.bundledHelper
        try #require(FileManager.default.isExecutableFile(atPath: helperURL.path),
                     "bundled helper missing: \(helperURL.path) (swift build -c release, then scripts/bundle.sh)")
        let kit = try #require(t34KitRoot(), "no KIT_ROOT and no TMPDIR: cannot find the kit")
        let mmModel = kit.appendingPathComponent("cache/\(mmModelName)")
        try #require(FileManager.default.fileExists(atPath: mmModel.path),
                     "model file missing: \(mmModel.path) (seed the cache: scripts/kit-mirror.sh seed --real)")
        let textModel = kit.appendingPathComponent("cache/\(textModelName)")
        try #require(FileManager.default.fileExists(atPath: textModel.path),
                     "model file missing: \(textModel.path) (seed the cache: scripts/kit-mirror.sh seed --real)")

        let build = t34WithGoldenLock(kit) {
            Tools.capture("/bin/bash", [KitPaths.projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path, "build", "golden"])
        }
        let built = try #require(build, "scripts/kit-fixtures.sh could not run")
        try #require(built.status == 0, "scripts/kit-fixtures.sh build golden exited \(built.status): \(built.output.suffix(300))")
        let golden = kit.appendingPathComponent("fixtures/golden", isDirectory: true).resolvingSymlinksInPath()
        let beach = golden.appendingPathComponent("photos/beach-dog.jpg")
        try #require(FileManager.default.fileExists(atPath: beach.path), "the golden photo is missing: \(beach.path)")
        // Both model paths, as the app passes them: the image model cannot run without the text model (U8).
        let arguments = ["index", "--text-model", textModel.path, "--mm-model", mmModel.path]

        try t34WithWorld { world in
            // MARK: the batch

            let helper = try t34StartHelper(world, executable: helperURL, arguments: arguments, fake: false)
            defer { helper.stop() }
            helper.send(t34FoldersLine([golden]))

            let started = Date()
            var peakMB = 0.0
            var lifetimeMaxMB = 0.0
            var samples = 0
            var done = 0
            var statuses: [String: Int] = [:]
            var db: T34DB?
            var lastChange = started
            var finishedAt: Date?
            var previewSent = false
            var previewReply: HelperReply?
            var previewSentAt = 0
            var nextSample = started
            while true {
                let now = Date()
                if now >= nextSample {
                    if let mb = Tools.footprintMB(pid: helper.pid) { peakMB = max(peakMB, mb); samples += 1 }
                    if let mb = Tools.footprintLifetimeMaxMB(pid: helper.pid) { lifetimeMaxMB = max(lifetimeMaxMB, mb) }
                    nextSample = now.addingTimeInterval(0.25)
                }
                if db == nil { db = T34DB(path: world.indexFile) }
                if let found = db?.statuses() {
                    statuses = found
                    let count = found["done"] ?? 0
                    if count != done { done = count; lastChange = now }
                }
                // One preview while the batch is in flight (the fallback sends it anyway after 90 s).
                if !previewSent, done >= 3 || now.timeIntervalSince(started) > 90 {
                    helper.send(t34PreviewLine(ticket: 1, file: beach.path))
                    previewSent = true
                    previewSentAt = done
                }
                while let line = helper.nextLine(timeout: 0.01) {
                    if let reply = HelperReply(line.text), reply.event == "preview", reply.previewTicket == 1 { previewReply = reply }
                }
                if done == 40 {
                    if finishedAt == nil { finishedAt = now }
                    if previewReply != nil, now.timeIntervalSince(finishedAt!) > 2 { break }
                    if now.timeIntervalSince(finishedAt!) > 60 { break }
                }
                if now.timeIntervalSince(lastChange) > 150 || now.timeIntervalSince(started) > 1500 { break }
                if !helper.isRunning { break }
            }
            if previewReply == nil, previewSent {
                previewReply = t34WaitPreview(helper, ticket: 1, timeout: 30)?.reply
            }
            // One last read of the kernel's lifetime maximum while the helper is still there (it cannot be read
            // once the process has exited).
            if let mb = Tools.footprintLifetimeMaxMB(pid: helper.pid) { lifetimeMaxMB = max(lifetimeMaxMB, mb) }
            let seconds = Int(Date().timeIntervalSince(started))

            #expect(done == 40, "\(done) of 40 golden photos reached done after \(seconds) s with both models, statuses \(statuses), helper \(helper.isRunning ? "still running" : "exited"), stderr: \(helper.errors)")
            #expect(previewReply != nil, "no preview reply for beach-dog.jpg (\(previewSent ? "sent with \(previewSentAt) photos done" : "never sent: the helper was gone before 3 photos were done")); stderr: \(helper.errors)")
            if let previewReply {
                #expect(previewReply.previewStatus == "ok", "the preview reply has status \(String(describing: previewReply.previewStatus)), expected ok: \(previewReply.raw.prefix(300))")
            }
            #expect(samples > 0, "no footprint reading for pid \(helper.pid) (helper running: \(helper.isRunning))")
            // The peak is the larger of the sampled peak and the kernel's lifetime maximum.
            let peak = samples > 0 ? max(peakMB, lifetimeMaxMB) : .nan
            print("READING index_photo_peak_gb=\(peak.isFinite ? String(format: "%.2f", peak / 1024) : "nan")")
            print("index photo batch: \(samples) footprint samples, sampled peak \(Int(peakMB)) MB, lifetime max \(Int(lifetimeMaxMB)) MB, peak \(peak.isFinite ? String(Int(peak)) : "none") MB")
            let figure = peak
            Reading.check(name: "index_photo_peak_mb", value: figure, bar: barGB * 1024)

            // MARK: the first preview with `index` not running

            helper.closeStdin()
            let exit = helper.waitForExit(timeout: 120)
            #expect(exit != nil, "the helper did not exit within 120 s of stdin EOF; stderr: \(helper.errors)")
            helper.stop()

            let began = Date()
            let fresh = try t34StartHelper(world, executable: helperURL, arguments: arguments, fake: false)
            defer { fresh.stop() }
            guard let answer = t34Ask(fresh, ticket: 2, file: beach.path, timeout: 120) else {
                Issue.record("no preview reply from a fresh index helper within 120 s; stderr: \(fresh.errors)")
                return
            }
            let firstPreviewMs = answer.at.timeIntervalSince(began) * 1000
            #expect(answer.reply.previewStatus == "ok", "the fresh helper's preview has status \(String(describing: answer.reply.previewStatus)), expected ok: \(answer.reply.raw.prefix(300))")
            print("READING U9 first_preview_ms=\(Reading.format(firstPreviewMs.rounded()))")
        }
    }
}
}
