import Foundation
import Testing
import SesameEngine

// plan-3-t22, tester step. Written from the t22 entry of plan-3-tasks.md, Decision D13, the plan-3 Conventions and the plan-1
// and plan-2 tests' public names only (SesameFolderTests: `SesameFolder.append(_:to:)`, `SesameFolder.size(of:)`, the
// 1,048,576-byte cap; LoginItemTests: the four `LoginStatus` cases; SpeedsStoreTests: the `bench status=` words). No product
// source was read. Every expected line is written here by hand, byte for byte; none comes from the code.
//
// What the entry fixes, and these tests use:
//   `Log.write(_:to:)` takes a `LogEvent` and a `LogFile` and appends one line through `SesameFolder.append`.
//   `LogEvent` has exactly three cases: `unit(inputs: Int)`, `loginStatus(LoginStatus)`, `benchStatus(BenchStatus)`.
//   `LogFile` has the cases `app`, `index` and `encode`.
// What it does not fix, and this file picks (a pick that is wrong is a test change, not a guess in the product):
//   * `Log.write` may throw or not; the tests call it as `try? Log.write(...)`, so either works. A write that failed leaves
//     no line and the expectations then fail.
//   * `LoginStatus` and `BenchStatus` are the payload types of the two cases. A `LogEvent` in the engine cannot hold a type
//     of the app target (LoginItemTests reaches `LoginStatus` through `@testable import Sesame` today), so the implementer
//     places both where `SesameEngine` can see them; this file never names the two types, only their cases. The `LoginStatus` cases are those LoginItemTests names. The `BenchStatus`
//     cases are `ok`, `failed` and `timeout`: `bench status=ok` is the entry's line, and `failed` and `timeout` are the words
//     SpeedsStoreTests already expects in `app.log`.
//   * A line is `<text>\n`: the file holds one newline-ended line per write.
//   * The file names are `app.log` and `index.log` (as every existing test reads them, in the Sesame folder, or under
//     `logs/` when that is where a reader finds them). The name behind `LogFile.encode` is not pinned: the test only
//     requires that it is a third `.log` file.
//   * What the cap does with the bytes past it (drop the oldest, drop the new) is the cap of `SesameFolder.append` and not
//     pinned here; only the size is.
// Everything runs in a throwaway HOME (the lock of SesameFolderTests); the helper test has its own HOME and the fake embedder.

private func lgFolder(_ t: TempHome) -> URL { t.folder }

/// The text of `<name>` in the Sesame folder, or under `logs/` when that is where it is. Nil when neither exists.
private func lgText(_ folder: URL, _ name: String) -> String? {
    for candidate in [folder.appendingPathComponent(name), folder.appendingPathComponent("logs").appendingPathComponent(name)] {
        if let data = try? Data(contentsOf: candidate) { return String(decoding: data, as: UTF8.self) }
    }
    return nil
}

private func lgLines(_ text: String?) -> [String] {
    (text ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

// The size of index.log wherever it is (under logs/ or loose): `SesameFolder.size(of:)` takes a name in the Sesame folder only, so
// it stopped seeing the log once the logs moved under logs/ (spec line 26).
private func lgLogSize(_ t: TempHome) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: sesameLogURL(lgFolder(t), "index.log").path)[.size] as? Int)
}

private let lgShape = "^[a-z_]+( [a-z_]+=[a-z0-9_]+)*$"

private func lgMatchesShape(_ line: String) -> Bool {
    line.range(of: lgShape, options: .regularExpression) != nil
}

/// The six lines of the entry, hand-written.
private func lgHandWritten() -> [(event: LogEvent, line: String)] {
    [
        (.unit(inputs: 4), "unit n=4"),
        (.loginStatus(.enabled), "login status=enabled"),
        (.loginStatus(.requiresApproval), "login status=requires_approval"),
        (.loginStatus(.notRegistered), "login status=not_registered"),
        (.loginStatus(.notFound), "login status=not_found"),
        (.benchStatus(.ok), "bench status=ok"),
    ]
}

/// One sample of each of the three cases, and the name of the case, by an exhaustive switch with no default: a fourth case,
/// or a case that changes its label or its `Int`, stops this file from compiling. The status types are never named here: a
/// test of the engine sees `LoginStatus` and `BenchStatus` only through the cases; the implementer picks where they live.
private func lgKind(_ event: LogEvent) -> String {
    switch event {
    case .unit(inputs: let n): let _: Int = n; return "unit"
    case .loginStatus(let status): _ = status; return "login"
    case .benchStatus(let status): _ = status; return "bench"
    }
}

@Suite("LogTests", .serialized)
struct LogTests {

    // MARK: the hand-written lines

    @Test func eachEventWritesItsLineByteForByte() throws {
        for (event, line) in lgHandWritten() {
            try withTempHome { t in
                guard try createFolder(t) else { return }
                try? Log.write(event, to: .app)
                #expect(lgText(lgFolder(t), "app.log") == line + "\n", "\(line): app.log holds \(String(describing: lgText(lgFolder(t), "app.log")))")
            }
        }
    }

    @Test func linesAppendInOrderAndAreNeverRewritten() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            for (event, _) in lgHandWritten() { try? Log.write(event, to: .app) }
            #expect(lgLines(lgText(lgFolder(t), "app.log")) == lgHandWritten().map { $0.line }, "app.log holds \(lgLines(lgText(lgFolder(t), "app.log")))")

            try? Log.write(.unit(inputs: 4), to: .app)
            #expect(lgLines(lgText(lgFolder(t), "app.log")) == lgHandWritten().map { $0.line } + ["unit n=4"])
            #expect(lgText(lgFolder(t), "app.log")?.hasSuffix("\n") == true, "the last line is not newline-ended")
        }
    }

    // MARK: edge numbers and the shape rule

    @Test func theEdgeNumbersWriteTheirDigitsExactly() throws {
        let table: [(Int, String)] = [(0, "unit n=0"), (16, "unit n=16"), (Int.max, "unit n=9223372036854775807")]
        for (number, line) in table {
            try withTempHome { t in
                guard try createFolder(t) else { return }
                try? Log.write(.unit(inputs: number), to: .index)
                #expect(lgText(lgFolder(t), "index.log") == line + "\n", "unit \(number): index.log holds \(String(describing: lgText(lgFolder(t), "index.log")))")
            }
        }
    }

    @Test func everyCaseLineMatchesTheShapeForTheEdgeNumbersAndEveryStatus() throws {
        var events: [LogEvent] = [.unit(inputs: 0), .unit(inputs: 16), .unit(inputs: Int.max)]
        events += [.loginStatus(.enabled), .loginStatus(.requiresApproval), .loginStatus(.notRegistered), .loginStatus(.notFound)]
        events += [.benchStatus(.ok), .benchStatus(.failed), .benchStatus(.timeout)]
        try withTempHome { t in
            guard try createFolder(t) else { return }
            for event in events { try? Log.write(event, to: .app) }
            let lines = lgLines(lgText(lgFolder(t), "app.log"))
            #expect(lines.count == events.count, "wrote \(events.count) events, the log holds \(lines.count) lines: \(lines)")
            for line in lines {
                #expect(lgMatchesShape(line), "the line \"\(line)\" does not match \(lgShape)")
                #expect(!line.contains("/"), "the line \"\(line)\" holds a slash")
            }
        }
    }

    // MARK: the closed set of events

    @Test func theEventHasExactlyThreeCasesAndNoneCarriesAStringOrAnError() {
        // by hand: one sample per case; `lgKind` is an exhaustive switch, so a fourth case does not compile
        let samples: [LogEvent] = [.unit(inputs: 4), .loginStatus(.enabled), .benchStatus(.ok)]
        #expect(samples.map(lgKind) == ["unit", "login", "bench"])
        #expect(Set(samples.map(lgKind)).count == 3, "the event must have exactly three cases")

        for sample in samples {
            for child in Mirror(reflecting: sample).children {
                #expect(!(child.value is String), "a case carries a String: \(sample)")
                #expect(!(child.value is any Error), "a case carries an error: \(sample)")
                #expect(!(child.value is Substring), "a case carries text: \(sample)")
            }
        }
    }

    // MARK: the three files

    @Test func theThreeFilesAreThreeSeparateLogsAndNothingElseIsMade() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            try? Log.write(.loginStatus(.enabled), to: .app)
            try? Log.write(.unit(inputs: 4), to: .index)
            try? Log.write(.unit(inputs: 7), to: .encode)

            #expect(lgLines(lgText(lgFolder(t), "app.log")) == ["login status=enabled"])
            #expect(lgLines(lgText(lgFolder(t), "index.log")) == ["unit n=4"])
            // The logs live under logs/ (spec line 26); this test read the Sesame folder itself. It now reads logs/ when it exists and
            // the loose place otherwise; LogLocationTests pins that they are under logs/.
            let logsFolder = lgFolder(t).appendingPathComponent("logs", isDirectory: true)
            let held = try names(in: FileManager.default.fileExists(atPath: logsFolder.path) ? logsFolder : lgFolder(t))
            let logs = held.filter { $0.hasSuffix(".log") }
            #expect(held == logs, "the Sesame folder holds something that is not a log: \(held)")
            #expect(logs.count == 3 && logs.contains("app.log") && logs.contains("index.log"), "the logs are \(logs)")
            let third = try #require(logs.first { $0 != "app.log" && $0 != "index.log" }, "no third log for LogFile.encode: \(logs)")
            #expect(lgLines(lgText(lgFolder(t), third)) == ["unit n=7"], "the encode log \(third) holds \(lgLines(lgText(lgFolder(t), third)))")
        }
    }

    // MARK: the cap

    @Test func aLogFedPastOneMebibyteStaysAtOrUnderTheCap() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            // "unit n=9223372036854775807\n" is 27 bytes: 45,000 lines are 1,215,000 bytes, past the cap of 1,048,576
            for round in 1...45_000 {
                try? Log.write(.unit(inputs: Int.max), to: .index)
                if round % 5_000 == 0 {
                    let size = try lgLogSize(t)
                    #expect(size <= logCap, "after \(round) lines the log is \(size) bytes")
                }
            }
            let size = try lgLogSize(t)
            #expect(size <= logCap, "the log is \(size) bytes, past \(logCap)")
            #expect(size > 0)
            let onDisk = try #require(FileManager.default.attributesOfItem(atPath: sesameLogURL(lgFolder(t), "index.log").path)[.size] as? Int)
            #expect(onDisk <= logCap, "the file on disk is \(onDisk) bytes")
        }
    }

    // MARK: the helper alone still writes its unit line

    // GUARD: passes today. The bundled helper (`SESAME_FAKE_EMBEDDER=1`, a throwaway HOME, as HelperNoPathLogTests starts it)
    // indexes three photos; after its unit, `index.log` holds a `unit n=<1 or more>` line, and every line in it has the shape.
    // `scripts/bundle.sh` runs first (a stale bundle fails here, never passes). Needs a user who is not root.
    @Test func theHelperAloneWritesAUnitLineToIndexLogAfterAUnit() throws {
        _ = atHelperWarm
        let executable = KitPaths.bundledHelper
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AtError("the bundled helper is missing: \(executable.path) (run scripts/bundle.sh)")
        }
        let world = try AtWorld()
        defer { world.remove() }
        try atMakePhotos(in: world.photos, names: atNames("lg", 1...3), seedBase: 2200)

        let rig = try PipeRig(helper: executable, home: world.home, models: nil, scratch: world.root)
        defer { rig.cleanup() }
        rig.send(atFoldersLine([world.photos]))
        #expect(rig.read(cap: 120, until: { rig.walked }), "no `walked` event; stderr: \(rig.stderrText.prefix(300))")

        let deadline = Date().addingTimeInterval(240)
        var done = 0
        var lastChange = Date()
        var db: AtDB?
        while Date() < deadline {
            if db == nil { db = world.db() }
            let now = db?.int("select count(*) from files where status = 'done'") ?? 0
            if now != done { done = now; lastChange = Date() }
            if done == 3 { break }
            if Date().timeIntervalSince(lastChange) > 60 || !rig.isRunning { break }
            _ = rig.read(cap: 0.1, until: { false })
        }
        #expect(done == 3, "the helper finished \(done) of 3 photos; stderr: \(rig.stderrText.prefix(300))")

        rig.closeStdin()
        _ = rig.read(cap: 60, until: { false })
        let exit = rig.waitForExit(timeout: 60)
        #expect(exit != nil, "the helper was still running 60 s after its stdin ended")

        let lines = lgLines(lgText(world.support, "index.log"))
        #expect(!lines.isEmpty, "the helper wrote no index.log")
        let units = lines.filter { $0.hasPrefix("unit n=") }
        #expect(!units.isEmpty, "no `unit n=` line in index.log: \(lines)")
        for line in units {
            let number = Int(line.dropFirst("unit n=".count))
            #expect((number ?? 0) >= 1, "the unit line \"\(line)\" does not carry a count of 1 or more")
        }
        for line in lines { #expect(lgMatchesShape(line), "index.log holds \"\(line)\", which does not match \(lgShape)") }
    }
}
