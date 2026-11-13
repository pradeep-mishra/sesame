import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t36, tester step. Written from the t36 entry, the Conventions (the Probe paragraph) and design sections 9.2
// and 12 only; no product source read. `Probe` is the stub t10 made: `Probe.emit(event, ticket)` writes one JSON
// line {"event":..,"ticket":n,"ns":..} to the file named by SESAME_PROBE_FILE, reading the variable at each call,
// with no fallback value, and writes nothing when the variable is unset.
//
// SUITE PLACEMENT. SESAME_PROBE_FILE is process-wide and `Probe.sink` is a global. Every suite that emits a probe
// event (QueryBoxTests, SearchPipelineTests, ProbeCallTests, and this one) is nested inside `ModelDownloadTests`, so
// they run one at a time: no other suite's `key`, `keyword` or `ranked` line can land in the file these tests read.
// Side effect: `swift test --filter ModelDownloadTests` also runs these tests.
//
// API SHAPE these tests pin: `Probe.emit(_ event: String, _ ticket: Int)` (a static function that returns at once;
// the unlabeled second argument is the t10 stub's own shape, which the compiler showed: `ticket:` is refused).
// The event names the Conventions list are `hotkey`, `shown`, `key`, `keyword`, `ranked`; `Probe` itself is not
// limited to them, so the tests also use one more name. Nothing here asks how the line is written (file handle,
// FileManager, a queue): only what is on disk.

// MARK: the file the tests read, parsed by hand

private struct PTLine {
    let event: String
    let ticket: Int
    let ns: Int64
    let keys: Set<String>
    let raw: String
}

private func ptLines(_ url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

private func ptParse(_ line: String) -> PTLine? {
    guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          let event = object["event"] as? String,
          let ticket = (object["ticket"] as? NSNumber)?.intValue,
          let ns = (object["ns"] as? NSNumber)?.int64Value
    else { return nil }
    return PTLine(event: event, ticket: ticket, ns: ns, keys: Set(object.keys), raw: line)
}

// "ticket" and "ns" are written as whole numbers, not as 3.0 or 1e9 or strings.
private func ptWholeNumbers(_ line: String) -> Bool {
    line.range(of: #""ticket"\s*:\s*-?\d+\s*[,}]"#, options: .regularExpression) != nil
        && line.range(of: #""ns"\s*:\s*\d+\s*[,}]"#, options: .regularExpression) != nil
}

@MainActor
private func ptEventually(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

private func ptWait(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// A throwaway folder, SESAME_PROBE_FILE put back (or removed) after the body, the folder deleted.
@MainActor
private func ptWithFolder(_ body: @MainActor (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("sesame-probe-" + UUID().uuidString, isDirectory: true)
        .resolvingSymlinksInPath()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let previous = getenv("SESAME_PROBE_FILE").map { String(cString: $0) }
    unsetenv("SESAME_PROBE_FILE")
    defer {
        if let previous { setenv("SESAME_PROBE_FILE", previous, 1) } else { unsetenv("SESAME_PROBE_FILE") }
        try? fm.removeItem(at: dir)
    }
    try await body(dir)
}

// Names in a folder that mention "probe" (a fallback file would be called something like that).
private func ptProbeNames(_ dir: URL) -> [String] {
    ptNames(dir).filter { $0.lowercased().contains("probe") }
}

private func ptNames(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

extension ModelDownloadTests {
    @Suite("ProbeTests", .serialized)
    struct ProbeTests {

        @MainActor
        @Test func eachEmitAppendsOneJSONObjectLineWithEventTicketAndNsAndNothingElse() async throws {
            try await ptWithFolder { dir in
                let file = dir.appendingPathComponent("probe.jsonl")
                setenv("SESAME_PROBE_FILE", file.path, 1)

                let sent: [(String, Int)] = [("hotkey", 0), ("shown", 0), ("key", 1), ("key", 2),
                                             ("keyword", 2), ("ranked", 2)]
                for (event, ticket) in sent { Probe.emit(event, ticket) }

                let arrived = await ptEventually { ptLines(file).count >= sent.count }
                #expect(arrived, "the file holds \(ptLines(file).count) lines, \(sent.count) were emitted")
                let lines = ptLines(file)
                #expect(lines.count == sent.count, "lines: \(lines)")

                let parsed = lines.compactMap(ptParse)
                #expect(parsed.count == lines.count, "a line is not one JSON object with event, ticket and ns: \(lines)")
                for line in parsed {
                    #expect(line.keys == ["event", "ticket", "ns"], "keys of \(line.raw): \(line.keys.sorted())")
                    #expect(ptWholeNumbers(line.raw), "ticket and ns must be whole numbers: \(line.raw)")
                }
                #expect(parsed.map(\.event) == sent.map(\.0), "events in order: \(parsed.map(\.event))")
                #expect(parsed.map(\.ticket) == sent.map(\.1), "tickets in order: \(parsed.map(\.ticket))")
            }
        }

        @MainActor
        @Test func nsNeverDecreasesAndIsInNanoseconds() async throws {
            try await ptWithFolder { dir in
                let file = dir.appendingPathComponent("probe.jsonl")
                setenv("SESAME_PROBE_FILE", file.path, 1)

                Probe.emit("key", 1)
                Probe.emit("key", 2)
                await ptWait(0.05)
                Probe.emit("ranked", 2)
                let arrived = await ptEventually { ptLines(file).count >= 3 }
                #expect(arrived)
                let parsed = ptLines(file).compactMap(ptParse)
                #expect(parsed.count == 3)
                guard parsed.count == 3 else { return }
                #expect(parsed[0].ns > 0)
                #expect(parsed[1].ns >= parsed[0].ns, "ns went down: \(parsed.map(\.ns))")
                #expect(parsed[2].ns >= parsed[1].ns, "ns went down: \(parsed.map(\.ns))")
                // 50 ms of sleeping between the second and third emit: the gap is at least 40 ms and far less than
                // 10 s, which tells nanoseconds from microseconds, milliseconds or seconds.
                let gap = parsed[2].ns - parsed[1].ns
                #expect(gap >= 40_000_000, "gap was \(gap) ns for a 50 ms wait")
                #expect(gap <= 10_000_000_000, "gap was \(gap) ns for a 50 ms wait")
            }
        }

        @MainActor
        @Test func nothingIsWrittenWhenTheVariableIsUnset() async throws {
            try await ptWithFolder { dir in
                #expect(getenv("SESAME_PROBE_FILE") == nil)
                // no fallback value: no probe file appears in the places a fallback would be put either
                let places = [FileManager.default.temporaryDirectory,
                              URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)]
                let before = places.map { ptProbeNames($0) }
                Probe.emit("hotkey", 0)
                Probe.emit("key", 1)
                await ptWait(0.4)
                #expect(ptNames(dir).isEmpty, "a file appeared in the working folder: \(ptNames(dir))")
                for (place, names) in zip(places, before) {
                    #expect(ptProbeNames(place) == names, "a probe file appeared in \(place.path): \(ptProbeNames(place))")
                }
            }
        }

        @MainActor
        @Test func theVariableIsReadAtEachCall() async throws {
            try await ptWithFolder { dir in
                let a = dir.appendingPathComponent("a.jsonl")
                let b = dir.appendingPathComponent("b.jsonl")

                setenv("SESAME_PROBE_FILE", a.path, 1)
                Probe.emit("key", 1)
                setenv("SESAME_PROBE_FILE", b.path, 1)
                Probe.emit("key", 2)
                unsetenv("SESAME_PROBE_FILE")
                Probe.emit("key", 3)            // unset: written nowhere, and no earlier path is reused
                setenv("SESAME_PROBE_FILE", a.path, 1)
                Probe.emit("key", 4)

                let arrived = await ptEventually { ptLines(a).count >= 2 && ptLines(b).count >= 1 }
                #expect(arrived, "a: \(ptLines(a)), b: \(ptLines(b))")
                await ptWait(0.3)
                #expect(ptLines(a).compactMap(ptParse).map(\.ticket) == [1, 4], "a: \(ptLines(a))")
                #expect(ptLines(b).compactMap(ptParse).map(\.ticket) == [2], "b: \(ptLines(b))")
                #expect(ptNames(dir) == ["a.jsonl", "b.jsonl"], "files: \(ptNames(dir))")
            }
        }

        @MainActor
        @Test func emitAppendsToAFileThatAlreadyHasLines() async throws {
            try await ptWithFolder { dir in
                let file = dir.appendingPathComponent("probe.jsonl")
                let earlier = #"{"event":"hotkey","ticket":0,"ns":5}"#
                try (earlier + "\n").write(to: file, atomically: true, encoding: .utf8)
                setenv("SESAME_PROBE_FILE", file.path, 1)

                Probe.emit("shown", 0)
                let arrived = await ptEventually { ptLines(file).count >= 2 }
                #expect(arrived, "lines: \(ptLines(file))")
                let lines = ptLines(file)
                #expect(lines.first == earlier, "the earlier line was changed or removed: \(lines)")
                #expect(lines.count == 2)
                #expect(lines.last.flatMap(ptParse)?.event == "shown")
            }
        }

        @MainActor
        @Test func aTicketAboveThirtyTwoBitsIsWrittenWhole() async throws {
            try await ptWithFolder { dir in
                let file = dir.appendingPathComponent("probe.jsonl")
                setenv("SESAME_PROBE_FILE", file.path, 1)

                Probe.emit("ranked", 4_000_000_123)
                let arrived = await ptEventually { ptLines(file).count >= 1 }
                #expect(arrived, "lines: \(ptLines(file))")
                let parsed = ptLines(file).compactMap(ptParse)
                #expect(parsed.map(\.ticket) == [4_000_000_123], "lines: \(ptLines(file))")
            }
        }
    }
}
