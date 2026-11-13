import Foundation
import Testing
import SesameEngine

// plan-1-t32, tester step. The group a golden test (spec S2(a)): the right photo is first for at least 6 of the 10
// `photo` rows of fixtures/answers.csv and within the first 3 for at least 9. Written from the t32 entry, the plan's
// Conventions and design sections 3, 7, 9 and 11 only; no product source read.
//
// Through the engine's public interface only: `scripts/kit-golden.sh prepare` (a child process) makes the index of the
// 40 golden photos with the bundled helper and prints its path; `IndexReader` opens it; `LlamaEmbedder` (the cached text
// model) embeds each query as an `Embedder`; `Search` ranks. The rank of each row is the place of the row's expected
// file in the ranked list. Expected files come from `fixtures/answers.csv`, never from the code under test; the rank is
// what the engine measured.
//
// It prints one `GOLDEN <row id> rank <n|none>` line per photo row (the line `scripts/kit-golden.sh engine` reads) and
// writes `golden-engine.tsv` (query, expected, rank, pass) in the evidence folder of the kit's starting state in the
// kit's own format (header `id group query expected rank locator pass`, group `a`), so the kit's runner replaces these
// rows with its own and keeps the rows of any other group.
//
// It never skips: a missing model, a missing bundle, a helper that has no index mode or no photo batches, a missing or
// unreadable index are each a failure that names the missing piece.
//
// HOME is process-wide and `IndexReader` finds the index under HOME when it first answers, so the test sets HOME to the
// kit's throwaway home for that one call only and puts it back at once (the other test targets share this process).

private let minFirst = 6      // spec S2(a): first for at least 6 of 10 ...
private let minTop3 = 9       // ... and within the first 3 for at least 9

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private struct Answer {
    let id: String
    let query: String
    let file: String
}

/// The `photo` rows of answers.csv: `id,group,query,file,locator,window_s,note`, no comma inside a field.
private func photoAnswers() throws -> [Answer] {
    let url = projectRoot.appendingPathComponent("fixtures/answers.csv")
    let text = try #require(try? String(contentsOf: url, encoding: .utf8), "fixtures/answers.csv is missing: \(url.path)")
    var rows: [Answer] = []
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where index > 0 {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, fields[1] == "photo" else { continue }
        rows.append(Answer(id: fields[0], query: fields[2], file: fields[3]))
    }
    return rows
}

private func kitRoot() -> URL? {
    let env = ProcessInfo.processInfo.environment
    if let kit = env["KIT_ROOT"], !kit.isEmpty { return URL(fileURLWithPath: kit, isDirectory: true) }
    if let tmp = env["TMPDIR"], !tmp.isEmpty {
        return URL(fileURLWithPath: (tmp as NSString).appendingPathComponent("sesame-kit"), isDirectory: true)
    }
    return nil
}

/// Holds an advisory lock on a file in the kit root while `body` runs, so this test and the real-model test of
/// IndexPhotosTests (which builds the same golden folder) never touch the golden folder at once.
private func withGoldenLock<T>(_ kit: URL, _ body: () throws -> T) rethrows -> T {
    let path = kit.appendingPathComponent(".t32-golden.lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return try body()
}

/// Runs `scripts/kit-golden.sh prepare` to the end; its output (stdout and stderr together) and exit status.
private func runPrepare() -> (status: Int32, output: String)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [projectRoot.appendingPathComponent("scripts/kit-golden.sh").path, "prepare"]
    process.currentDirectoryURL = projectRoot
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return nil }
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 2400, execute: watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func tail(_ text: String, _ lines: Int = 6) -> String {
    text.split(separator: "\n").suffix(lines).joined(separator: " / ")
}

/// The folder the kit writes golden-engine.tsv into: the evidence folder of the starting state, else `run/`.
private func evidenceFolder(_ kit: URL) -> URL {
    let pointer = kit.appendingPathComponent("run/evidence-dir")
    if let text = try? String(contentsOf: pointer, encoding: .utf8) {
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
    }
    return kit.appendingPathComponent("run", isDirectory: true)
}

private func passWord(_ rank: Int?) -> String {
    switch rank {
    case 1: return "first"
    case 2, 3: return "top3"
    default: return "miss"
    }
}

@Suite("GroupATests")
struct GroupATests {

    @Test func theRightPhotoIsFirstForAtLeast6OfTheTenPhotoQueriesAndWithinTheFirstThreeForAtLeast9() throws {
        let answers = try photoAnswers()
        try #require(answers.count == 10, "fixtures/answers.csv has \(answers.count) photo rows, expected 10")
        let kit = try #require(kitRoot(), "no KIT_ROOT and no TMPDIR: cannot find the kit")

        // The cached text model embeds the queries (the helper embeds the photos with the other one).
        let textModel = kit.appendingPathComponent("cache/embeddinggemma-2-Q8_0.gguf")
        let mmModel = kit.appendingPathComponent("cache/mmproj-embeddinggemma-2-Q8_0.gguf")
        try #require(FileManager.default.fileExists(atPath: textModel.path),
                     "model file missing: \(textModel.path) (seed the cache: scripts/kit-mirror.sh seed --real)")
        try #require(FileManager.default.fileExists(atPath: mmModel.path),
                     "model file missing: \(mmModel.path) (seed the cache: scripts/kit-mirror.sh seed --real)")

        // The index of the 40 golden photos, made by the bundled helper through the kit.
        let prepared = withGoldenLock(kit) { runPrepare() }
        let prepare = try #require(prepared, "scripts/kit-golden.sh could not be run")
        if prepare.status != 0 {
            let said = prepare.output
            if said.contains("NEEDS A PERSON") {
                Issue.record("kit-golden.sh prepare needs a person: \(tail(said))")
            } else if said.contains("no index mode") || said.contains("does not hold 40 done photo files") {
                Issue.record("helper has no index mode or no photo batches: kit-golden.sh prepare exited \(prepare.status): \(tail(said))")
            } else {
                Issue.record("kit-golden.sh prepare exited \(prepare.status): \(tail(said))")
            }
            return
        }
        let lastLine = prepare.output.split(separator: "\n").last.map(String.init) ?? ""
        let suffix = "/Library/Application Support/Sesame/index.sqlite"
        try #require(lastLine.hasPrefix("/") && lastLine.hasSuffix(suffix),
                     "kit-golden.sh prepare did not end with the index path: \(tail(prepare.output))")
        try #require(FileManager.default.fileExists(atPath: lastLine), "the index is missing: \(lastLine)")
        let home = String(lastLine.dropLast(suffix.count))

        // IndexReader finds the index under HOME the first time it answers; HOME is back at once.
        var reader: IndexReader?
        var fileCount = -1
        for _ in 0..<25 {
            let previous = getenv("HOME").map { String(cString: $0) }
            setenv("HOME", home, 1)
            let candidate = IndexReader()
            fileCount = candidate.fileCount()
            if let previous { setenv("HOME", previous, 1) } else { unsetenv("HOME") }
            if fileCount == 40 { reader = candidate; break }
            candidate.close()
            Thread.sleep(forTimeInterval: 0.2)
        }
        let opened = try #require(reader, "the index at \(lastLine) holds \(fileCount) files, expected the 40 golden photos")
        defer { opened.close() }

        let embedder = LlamaEmbedder(textModel: textModel)
        try embedder.load()
        defer { embedder.unload() }
        let search = Search(reader: opened)

        // Every file of the fixture is under the golden folder; the index may name it through /private.
        let golden = kit.appendingPathComponent("fixtures/golden", isDirectory: true)
        let folders = Array(Set([golden.path, golden.resolvingSymlinksInPath().path]))
            .map { Settings.Folder(path: $0, code: false, reading: true) }
        let visible = Visible(folders: folders, codeSearchOn: false,
                              kindsOn: ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true])

        var ranks: [(answer: Answer, rank: Int?)] = []
        for answer in answers {
            let vector = try embedder.embed(answer.query, role: .query)
            let ticket = search.newTicket()
            let hits = search.rank(text: answer.query, vector: vector, ticket: ticket, visible: visible) ?? []
            let wanted = "/golden/" + answer.file
            let place = hits.firstIndex { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path.hasSuffix(wanted) }
            let rank = place.map { $0 + 1 }
            ranks.append((answer, rank))
            print("GOLDEN \(answer.id) rank \(rank.map(String.init) ?? "none")")
        }
        search.release()

        // golden-engine.tsv: query, expected, rank, pass; the rows of other groups stay.
        let folder = evidenceFolder(kit)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tsv = folder.appendingPathComponent("golden-engine.tsv")
        var kept: [String] = []
        if let old = try? String(contentsOf: tsv, encoding: .utf8) {
            for (index, line) in old.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where index > 0 {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                if fields.count > 1, fields[1] != "a" { kept.append(String(line)) }
            }
        }
        var out = "id\tgroup\tquery\texpected\trank\tlocator\tpass\n"
        for line in kept { out += line + "\n" }
        for (answer, rank) in ranks {
            out += "\(answer.id)\ta\t\(answer.query)\t\(answer.file)\t\(rank.map(String.init) ?? "none")\t\t\(passWord(rank))\n"
        }
        try Data(out.utf8).write(to: tsv, options: .atomic)

        let first = ranks.filter { $0.rank == 1 }.count
        let top3 = ranks.filter { ($0.rank ?? 99) <= 3 }.count
        let summary = ranks.map { "\($0.answer.id)=\($0.rank.map(String.init) ?? "none")" }.joined(separator: " ")
        print("GOLDEN engine group a: first \(first) of \(ranks.count) (need \(minFirst)), top-3 \(top3) of \(ranks.count) (need \(minTop3)); wrote \(tsv.path)")
        #expect(ranks.count == 10, "\(ranks.count) rows were ranked, expected 10")
        #expect(first >= minFirst, "the right photo was first for \(first) of 10 queries, need \(minFirst): \(summary)")
        #expect(top3 >= minTop3, "the right photo was within the first 3 for \(top3) of 10 queries, need \(minTop3): \(summary)")
    }
}
