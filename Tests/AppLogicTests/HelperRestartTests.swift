import CoreGraphics
import Foundation
import ImageIO
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t35, tester step (2 of 2): the end-to-end half. Carry-over F8 (design section 1, `tries`: "the app, not the
// helper, restarts the helper after any unplanned exit while Start is pressed, not paused and work remains; every death
// spends a try, so a bad file blocks nothing for more than two deaths"; design section 9, 1c: "a planted file whose
// fake-embedder read always crashes ends as `could_not_read` after two deaths while every other file is indexed").
// Written from the t35 entry (its Tests paragraph), those two design texts and the t31 to t34 names only. No product
// source was read. The fake-host half is in HelperSupervisorTests.swift (the same entry, the same API pins, listed at
// the head of that file's t35 section).
//
// THE TEST. The real `HelperSupervisor`, over the real `HelperClientIndexHost` and `HelperClient`, started on the bundled
// release helper (`dist/Sesame.app/Contents/MacOS/SesameHelper`, built by `scripts/bundle.sh`) with
// `SESAME_FAKE_EMBEDDER=1` and a throwaway HOME. 20 generated photos: `crash-always-1.jpg`, `crash-always-2.jpg` and 18
// ordinary ones. Under the fake embedder every `crash-always-<n>.jpg` kills the helper (the entry widens plan 1's single
// name to every <n>). The supervisor restarts the helper until the index holds the two bad files as `could_not_read`
// ("damaged") and the other 18 as `done`, and then restarts it no more. The index is read through `IndexReader`
// (`PanelSnapshot.read`, `couldNotRead()` through `CouldNotReadList`), the work source is a real `StatusCache` over that
// reader, and the delay seam asks for any delay but is answered at once (the entry's "delay seam set to 0").
//
// WHAT IS COUNTED. A decorator host forwards to the real `HelperClientIndexHost` and counts `start()` calls and exits.
// Written by hand from the design: every restart is one `start()` after one unplanned exit, so `start()` calls equal 1
// plus the unplanned exits; a bad file dies at most twice (the second death makes it `could_not_read`), so the deaths
// are at least 2 (one file twice, the other riding in the same unit) and at most 4 (each file twice, alone). The
// entry's "each bad file died twice" is read as: no bad file survives a third run.
//
// TIME. The first helper start compiles the Vision model (about 35 s measured, 120 s allowed, once per test process);
// every later helper is warm. The whole wait is 420 s (120 s for the first helper, 300 s of slack), never a tight bound.
// The five seconds after the end state only look for a restart that must not come.
//
// PINS this file uses beyond the fake-host half (the entry gives names; if a shape is wrong, ask for a test change):
//   `HelperSupervisor.helperChanged()`  the relay's call for a `changed` event of the index helper (the test's delegate
//                                       makes it, as the app's relay will).
//   `StatusCache.workRemains`           the work source (see HelperSupervisorTests.swift).
//   `HelperSupervisor(host:inputs:workRemains:schedule:)` with the `schedule` closure of that file.
// HOME is process-wide, so the suite is nested in `ModelDownloadTests` and runs one at a time with the others.

// MARK: the world: photos, helper binary, settings

private let rsGood = (1...18).map { String(format: "photo-%02d", $0) }
// Newest first (the helper reads newest first). The bad files sit in the middle of the queue, not at its ends.
private let rsOrder: [String] = {
    var names = rsGood
    names.insert("crash-always-1", at: 6)
    names.insert("crash-always-2", at: 13)
    return names
}()

private func rsNoise(seed: Int, side: Int = 96) -> CGImage? {
    var pixels = [UInt8](repeating: 255, count: side * side * 4)
    var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678_9ABC_DEF1
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

private func rsJPEG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

private struct RSError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `<folder>/<name>.jpg` for every name, each a different picture, the first the newest, all an hour or more old.
private func rsMakePhotos(in folder: URL, names: [String]) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let past = Date().timeIntervalSince1970.rounded(.down) - 3600
    for (index, name) in names.enumerated() {
        guard let image = rsNoise(seed: index + 1), let data = rsJPEG(image) else { throw RSError("could not draw \(name)") }
        let url = folder.appendingPathComponent(name + ".jpg")
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: past - Double(index))],
                                              ofItemAtPath: url.path)
    }
}

/// The package root: this file is `<root>/Tests/AppLogicTests/HelperRestartTests.swift`.
private let rsBundledHelper: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("dist/Sesame.app/Contents/MacOS/SesameHelper")

// MARK: the decorator host, the relay

/// Forwards to the real host and counts what the supervisor does to it and what the process does.
@MainActor
private final class RSCountingHost: IndexHost {
    private let inner: HelperClientIndexHost
    private var downstream: ((HelperExit) -> Void)?
    private(set) var startCalls = 0
    private(set) var plannedExits = 0
    private(set) var deaths: [Int32] = []        // unplanned exits with a status other than 0
    private(set) var otherUnplanned = 0           // unplanned exits with status 0 (an idle exit the app did not ask for)

    var isRunning: Bool { inner.isRunning }
    var onExit: ((HelperExit) -> Void)? {
        get { downstream }
        set { downstream = newValue }
    }

    init(_ inner: HelperClientIndexHost) {
        self.inner = inner
        inner.onExit = { [unowned self] exit in
            switch exit {
            case .planned: plannedExits += 1
            case .unplanned(let status):
                if status == 0 { otherUnplanned += 1 } else { deaths.append(status) }
            case .idle: otherUnplanned += 1
            }
            downstream?(exit)
        }
    }

    func start() { startCalls += 1; inner.start() }
    func stopClean() { inner.stopClean() }
    var unplannedExits: Int { deaths.count + otherUnplanned }
}

/// The app's relay of the index helper's `changed` events: to the supervisor (delay back to 1 s) and to the cache.
private final class RSRelay: HelperClientDelegate, @unchecked Sendable {
    private let onChanged: @MainActor @Sendable () -> Void
    init(_ onChanged: @escaping @MainActor @Sendable () -> Void) { self.onChanged = onChanged }
    func helperClient(_ client: HelperClient, didReceive event: HelperEvent) {
        if case .changed = event {
            let handler = onChanged
            Task { @MainActor in handler() }
        }
    }
}

// MARK: the suite

extension ModelDownloadTests {
    @Suite("HelperRestartTests", .serialized)
    struct HelperRestartTests {

        @MainActor
        @Test func theSupervisorRestartsTheDeadHelperUntilTheTwoPlantedFilesAreCouldNotReadAndTheOtherEighteenAreDone() async throws {
            guard FileManager.default.isExecutableFile(atPath: rsBundledHelper.path) else {
                Issue.record("the bundled helper is missing: \(rsBundledHelper.path) (run scripts/bundle.sh)")
                return
            }
            let previousFake = getenv("SESAME_FAKE_EMBEDDER").map { String(cString: $0) }
            setenv("SESAME_FAKE_EMBEDDER", "1", 1)
            defer {
                if let previousFake { setenv("SESAME_FAKE_EMBEDDER", previousFake, 1) } else { unsetenv("SESAME_FAKE_EMBEDDER") }
            }

            try await spWithHome { home in
                let fm = FileManager.default
                let root = home.resolvingSymlinksInPath()
                let photos = root.appendingPathComponent("photos", isDirectory: true)
                try rsMakePhotos(in: photos, names: rsOrder)
                let textModel = root.appendingPathComponent("text-model.gguf")
                let mmModel = root.appendingPathComponent("mm-model.gguf")
                fm.createFile(atPath: textModel.path, contents: Data("t".utf8))
                fm.createFile(atPath: mmModel.path, contents: Data("m".utf8))

                var settings = Settings()
                settings.startPressed = true
                settings.kindsOn = ["photo": true]
                settings.folders = [Settings.Folder(path: photos.path, code: false, reading: true)]
                try SettingsFile().write(settings)
                let savedSettings = settings

                let reader = IndexReader()
                defer { reader.close() }
                let queue = DispatchQueue(label: "sesame.helperrestart.test.cache", qos: .utility)
                let cache = StatusCache(
                    sources: StatusSources(
                        settings: { savedSettings },
                        counts: { PanelSnapshot.read(reader: reader, model: .whole).counts },
                        meta: { reader.meta($0) },
                        modelState: { .whole }),
                    queue: queue)

                let client = HelperClient(helper: rsBundledHelper, textModel: textModel, mmModel: mmModel)
                defer { client.shutdown(timeout: 5) {} }
                let host = RSCountingHost(HelperClientIndexHost(client: client))

                final class Quit: @unchecked Sendable { var now = false }
                let quit = Quit()
                var requestedDelays: [TimeInterval] = []
                let supervisor = HelperSupervisor(
                    host: host,
                    inputs: {
                        HelperSupervisor.Inputs(startPressed: true, indexDeleted: false, modelWhole: true,
                                                pauseReasons: [], quitting: quit.now)
                    },
                    workRemains: { cache.workRemains },
                    schedule: { delay, work in
                        requestedDelays.append(delay)          // the delay seam: the requested time is not waited
                        Task { @MainActor in work() }
                    })
                client.delegate = RSRelay({ supervisor.helperChanged(); cache.helperChanged() })

                cache.refresh()
                supervisor.reevaluate()   // a launch with Start pressed starts indexing with no press

                let expectedRows = ["crash-always-1.jpg, damaged", "crash-always-2.jpg, damaged"]
                func state() -> (done: Int, others: String, rows: [String]) {
                    let counts = PanelSnapshot.read(reader: reader, model: .whole).counts
                    let rows = CouldNotReadList(files: reader.couldNotRead()).rows
                    return (counts.done, "pending \(counts.pending), partial \(counts.partial), needsPermission \(counts.needsPermission)", rows)
                }
                func finished() -> Bool {
                    let now = state()
                    let counts = PanelSnapshot.read(reader: reader, model: .whole).counts
                    return now.done == 18 && counts.pending.isEmpty && counts.partial.isEmpty
                        && counts.needsPermission == 0 && now.rows == expectedRows
                }

                // 120 s for the first (cold) helper and 300 s of slack for the restarts; never a tight bound.
                let deadline = Date().addingTimeInterval(420)
                var reached = finished()
                var notRunningSince: Date?
                var gaveUp = false
                while !reached && Date() < deadline {
                    await spWait(0.25)
                    reached = finished()
                    // The delay seam answers at once, so a restart follows a death within moments. A helper that has
                    // been gone for 30 s with the index unfinished was never restarted: stop waiting for it.
                    if host.isRunning { notRunningSince = nil } else if let since = notRunningSince {
                        if Date().timeIntervalSince(since) > 30 { gaveUp = true; break }
                    } else { notRunningSince = Date() }
                }
                let now = state()
                #expect(reached, """
                    the index never reached 18 done and the two planted files could_not_read (damaged): done \(now.done), \
                    \(now.others), could not read \(now.rows); start() calls \(host.startCalls), deaths \(host.deaths), \
                    other unplanned exits \(host.otherUnplanned), planned exits \(host.plannedExits), requested delays \
                    \(requestedDelays)\(gaveUp ? "; the helper was gone for 30 s and was never started again" : "")
                    """)
                #expect(now.rows == expectedRows, "could-not-read rows: \(now.rows)")
                #expect(now.done == 18, "done: \(now.done); \(now.others)")

                // every restart was one start() after one unplanned exit; a bad file dies at most twice
                #expect((2...4).contains(host.deaths.count),
                        "deaths: \(host.deaths); two bad files that die twice each give 2 to 4 deaths")
                #expect(host.startCalls == 1 + host.unplannedExits,
                        "start() calls \(host.startCalls) for \(host.unplannedExits) unplanned exits (deaths \(host.deaths))")
                #expect(Set(requestedDelays).isSubset(of: [1, 2, 5, 10, 30]), "delays asked for: \(requestedDelays)")

                // then no more restarts
                let startsAtEnd = host.startCalls
                await spWait(5)
                #expect(host.startCalls == startsAtEnd,
                        "the supervisor restarted the helper \(host.startCalls - startsAtEnd) more time(s) after nothing was left to do")
                let after = state()
                #expect(after.done == 18 && after.rows == expectedRows, "the end state changed: \(after)")

                // a clean Quit ends the helper; nothing restarts it
                quit.now = true
                supervisor.reevaluate()
                let stopped = await spEventually(timeout: 120) { !host.isRunning }
                #expect(stopped, "the helper was still running 120 s after Quit")
                await spWait(2)
                #expect(host.startCalls == startsAtEnd, "a start() came after Quit")
            }
        }
    }
}
