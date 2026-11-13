import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t29, tester step (1 of 2): `PauseSet`, the in-memory set of pause reasons (S7.3, S7.4, S7.17).
// Written from the t29 entry (its Tests paragraph), design section 6 ("Pause reasons are a set (you, CPU, Low
// Power, battery); 'Resume anyway, on battery' removes only battery, for this session [guess]"), design guess G4
// ("pause and 'Resume anyway' kept in memory only") and spec S7 ("'Resume anyway, on battery' overrides the battery
// pause only"). No product source was read. Every expected value is written by hand from those texts.
//
// API SHAPES these tests pin. The entry names `PauseSet`, `isPaused` and `resumeAnyway()` and fixes no other
// signature; the rest are this file's picks. If a shape is wrong, ask for a test change rather than guessing.
//   1. `PauseReason` already exists (`enum PauseReason: Hashable { you, cpu, lowPower, battery }`, MenuState.swift); it
//      is reused, never redefined.
//   2. `PauseSet` is in the `Sesame` target, with `init()`. A class or a struct both satisfy these tests (they hold it
//      in a `var`); t30's LoadMonitor and t32's MenuActions share one instance, so a class is the likely pick. A new
//      `PauseSet()` is a new session: it holds no reason and has no override.
//   3. `set.reasons: Set<PauseReason>` is what is set now (the type `MenuInputs.pauseReasons` takes).
//   4. `set.add(_ reason: PauseReason)` and `set.remove(_ reason: PauseReason)` change one reason and never another.
//      Adding a reason twice is one reason; removing one that is not set does nothing.
//   5. `set.isPaused: Bool` is true exactly while `reasons` is not empty.
//   6. `set.resumeAnyway()` removes `battery` and nothing else, and from then on, for this `PauseSet` only, `add(.battery)`
//      does nothing ("a later battery event in the same session is ignored"). The other three reasons still add and
//      remove normally afterwards.
// Not pinned, on purpose: thread safety and actor isolation (the tests run on the main actor), whether
// `resumeAnyway()` with no battery reason set arms the override, whether `remove(.battery)` after the override does
// anything visible, any change callback (t30 owns `onChange`), the type of the return value of add or remove.
//
// SUITE PLACEMENT. The "nothing is written" test sets HOME (process-wide, as SetupFlowTests does), so this suite is
// nested inside `ModelDownloadTests` too and runs one at a time with the other HOME suites. Side effect:
// `swift test --filter ModelDownloadTests` also runs these tests.

private var psAll: Set<PauseReason> { [.you, .cpu, .lowPower, .battery] }

// The four reasons as an ordered list, with a name for failure messages.
private var psEach: [(name: String, reason: PauseReason)] {
    [("you", .you), ("cpu", .cpu), ("lowPower", .lowPower), ("battery", .battery)]
}

// One line per entry under `root`, recursively: relative path, kind, size, modification time (ns) and, for a file,
// its bytes as a string. Sorted, so two listings of an untouched tree are equal.
private func psListing(_ root: URL) throws -> [String] {
    let fm = FileManager.default
    var lines: [String] = []
    guard let walker = fm.enumerator(atPath: root.path) else { return lines }
    for case let relative as String in walker {
        let path = root.appendingPathComponent(relative).path
        let attributes = try fm.attributesOfItem(atPath: path)
        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        let modified = ((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1_000_000_000
        var content = ""
        if !isDirectory, let data = fm.contents(atPath: path) {
            content = data.base64EncodedString()
        }
        lines.append("\(relative)|\(isDirectory ? "dir" : "file")|\(size)|\(Int64(modified))|\(content)")
    }
    return lines.sorted()
}

extension ModelDownloadTests {
    @Suite("PauseSetTests", .serialized)
    @MainActor
    struct PauseSetTests {

        // MARK: the reasons are independent

        @Test func aNewSetHoldsNoReasonAndIsNotPaused() {
            let set = PauseSet()
            #expect(set.reasons.isEmpty)
            #expect(set.isPaused == false)
            for (name, reason) in psEach {
                #expect(!set.reasons.contains(reason), "a new set must not hold \(name)")
            }
        }

        @Test func eachReasonAloneIsAddedAndRemovedAndPausesWhileSet() {
            for (name, reason) in psEach {
                var set = PauseSet()
                set.add(reason)
                #expect(set.reasons == [reason], "after add(\(name))")
                #expect(set.isPaused == true, "paused while \(name) is set")
                set.remove(reason)
                #expect(set.reasons.isEmpty, "after remove(\(name))")
                #expect(set.isPaused == false, "not paused once \(name) is gone")
            }
        }

        @Test func addingOneReasonLeavesTheOthersAlone() {
            for (name, reason) in psEach {
                var set = PauseSet()
                let others = psAll.subtracting([reason])
                for other in others { set.add(other) }
                #expect(set.reasons == others)
                set.add(reason)
                #expect(set.reasons == psAll, "add(\(name)) on top of the other three")
            }
        }

        @Test func removingOneReasonLeavesTheOthersAndStaysPausedUntilTheLastIsGone() {
            for (name, reason) in psEach {
                var set = PauseSet()
                for each in psAll { set.add(each) }
                set.remove(reason)
                #expect(set.reasons == psAll.subtracting([reason]), "remove(\(name)) from all four")
                #expect(set.isPaused == true, "still paused: three reasons remain after removing \(name)")
            }
            var set = PauseSet()
            for each in psAll { set.add(each) }
            var remaining = psAll
            for (name, reason) in psEach {
                set.remove(reason)
                remaining.remove(reason)
                #expect(set.reasons == remaining, "after removing up to \(name)")
                #expect(set.isPaused == !remaining.isEmpty, "isPaused follows whether any reason is left, at \(name)")
            }
            #expect(set.isPaused == false)
        }

        @Test func addingTheSameReasonTwiceIsOneReasonAndOneRemoveClearsIt() {
            for (name, reason) in psEach {
                var set = PauseSet()
                set.add(reason)
                set.add(reason)
                #expect(set.reasons == [reason], "\(name) added twice")
                set.remove(reason)
                #expect(set.reasons.isEmpty, "one remove clears \(name) added twice")
                #expect(set.isPaused == false)
            }
        }

        @Test func removingAReasonThatIsNotSetChangesNothing() {
            var set = PauseSet()
            set.add(.you)
            set.add(.cpu)
            set.remove(.battery)
            set.remove(.lowPower)
            #expect(set.reasons == [.you, .cpu])
            #expect(set.isPaused == true)
            var empty = PauseSet()
            empty.remove(.you)
            #expect(empty.reasons.isEmpty)
            #expect(empty.isPaused == false)
        }

        // MARK: Resume anyway

        @Test func resumeAnywayRemovesOnlyBatteryAndKeepsCpuLowPowerAndYou() {
            var set = PauseSet()
            for each in psAll { set.add(each) }
            set.resumeAnyway()
            #expect(set.reasons == [.you, .cpu, .lowPower])
            #expect(set.isPaused == true, "the other three reasons still pause")
        }

        @Test func resumeAnywayWithBatteryAloneEndsThePause() {
            var set = PauseSet()
            set.add(.battery)
            #expect(set.isPaused == true)
            set.resumeAnyway()
            #expect(set.reasons.isEmpty)
            #expect(set.isPaused == false)
        }

        @Test func resumeAnywayKeepsEachOtherReasonOnItsOwn() {
            for (name, kept) in psEach where kept != .battery {
                var set = PauseSet()
                set.add(kept)
                set.add(.battery)
                set.resumeAnyway()
                #expect(set.reasons == [kept], "battery and \(name), after resumeAnyway")
                #expect(set.isPaused == true, "\(name) still pauses after resumeAnyway")
            }
        }

        @Test func aLaterBatteryEventInTheSameSessionIsIgnored() {
            var set = PauseSet()
            set.add(.battery)
            set.resumeAnyway()
            set.add(.battery)
            #expect(set.reasons.isEmpty, "the battery event after Resume anyway must not pause again")
            #expect(set.isPaused == false)
            set.add(.battery)
            set.add(.battery)
            #expect(set.reasons.isEmpty, "every later battery event is ignored, not only the first")
        }

        @Test func aLaterBatteryEventIsIgnoredWhileOtherReasonsComeAndGo() {
            var set = PauseSet()
            set.add(.cpu)
            set.add(.battery)
            set.resumeAnyway()
            set.add(.battery)
            #expect(set.reasons == [.cpu], "battery ignored, cpu kept")
            set.add(.lowPower)
            set.add(.you)
            #expect(set.reasons == [.cpu, .lowPower, .you], "the other reasons still add after the override")
            set.remove(.cpu)
            set.add(.battery)
            #expect(set.reasons == [.lowPower, .you], "battery still ignored after cpu went away")
            set.remove(.lowPower)
            set.remove(.you)
            #expect(set.reasons.isEmpty)
            #expect(set.isPaused == false)
            set.add(.cpu)
            #expect(set.reasons == [.cpu], "cpu still adds after the override")
        }

        // MARK: a new session starts clean

        @Test func aNewSetIsANewSessionWithNoReasonAndNoOverride() {
            var first = PauseSet()
            first.add(.you)
            first.add(.battery)
            first.resumeAnyway()
            first.add(.battery)
            #expect(first.reasons == [.you])

            var second = PauseSet()
            #expect(second.reasons.isEmpty, "a new session holds no reason")
            #expect(second.isPaused == false)
            second.add(.battery)
            #expect(second.reasons == [.battery], "the override of the first session does not carry into the second")
            #expect(first.reasons == [.you], "and the second does not change the first")
        }

        // MARK: nothing is written

        @Test func noReasonChangeWritesSettingsJsonOrAnyFile() throws {
            let fm = FileManager.default
            let home = fm.temporaryDirectory.appendingPathComponent("sesame-pauseset-test-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            let previousHome = getenv("HOME").map { String(cString: $0) }
            setenv("HOME", home.path, 1)
            defer {
                if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
                try? fm.removeItem(at: home)
            }
            _ = try SesameFolder.create()
            let folder = home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
            guard fm.fileExists(atPath: folder.path) else {
                Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before touching anything")
                return
            }
            // Files a person's folder would hold, with bytes written by hand, so a rewrite shows in the listing.
            try SesameFolder.write(Data(#"{"version":3,"startPressed":true,"indexDeleted":false}"#.utf8), to: "settings.json")
            try SesameFolder.write(Data("login status=enabled\n".utf8), to: "app.log")

            let before = try psListing(home)
            #expect(before.contains { $0.hasPrefix("Library/Application Support/Sesame/settings.json|file|") },
                    "the test's own settings.json is in the listing (else the check below proves nothing)")

            var set = PauseSet()
            for each in psAll { set.add(each) }
            set.remove(.cpu)
            set.add(.cpu)
            set.resumeAnyway()
            set.add(.battery)
            set.remove(.you)
            set.remove(.lowPower)
            set.remove(.cpu)
            #expect(set.isPaused == false)
            var fresh = PauseSet()
            fresh.add(.you)
            fresh.add(.battery)

            let after = try psListing(home)
            #expect(after == before, "no file under the throwaway HOME may be created, changed or removed by a PauseSet")
            let settings = try Data(contentsOf: folder.appendingPathComponent("settings.json"))
            #expect(String(decoding: settings, as: UTF8.self) == #"{"version":3,"startPressed":true,"indexDeleted":false}"#,
                    "settings.json is byte for byte what the test wrote")
        }
    }
}
