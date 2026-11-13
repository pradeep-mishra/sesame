import Foundation
import Testing

// plan-2 fix round C, part C1, item C1-7 (R2-05), tester step: S1.6 needs an overlap the kit can build, and `checks.floor` is
// recounted honestly.
//   - The kit built no overlap: the recipe `photos` picks golden/ and golden/photos/, and the folder picker adds golden/photos for
//     golden (its only subfolder), so the list never held the pair and S1.6 stayed NEEDS-A-PERSON. Fix: a fixture builder
//     (`kit-fixtures.sh build overlap`: a parent folder holding a photos/ subfolder, copied from the golden photos under
//     KIT_ROOT, driven by the hand-written table scripts/kit-lib/overlap.tsv), and S1.6 picks the parent and the subfolder
//     through the picker, then checks one `files` row per path and the menu's photo count equal to `expect counts`.
//   - The floor is the number of `auto` ids of slices 1 and 2 whose check can reach PASS without a person. An `auto` id that
//     verify.md itself says needs a person is `auto-or-person` in checks.tsv, and only where verify.md says so.
// Written from the fix-round document (C1-7), verify.md and the existing kit tables. Nothing is run: tables and scripts are read
// as text.
//
// THE PICKER IS A GUESS until the accept stage: whether the picker adds the parent itself (the parent also holds two loose photos,
// so it is not "a folder whose only entry is a subfolder") is not measured. If it cannot pick both, S1.6 says NEEDS-A-PERSON for
// the picker step only, as verify.md says (the Recipes line: "the ids whose subject is the picker itself stay NEEDS-A-PERSON").
//
// WHAT WOULD MAKE EACH CHECK FAIL ON A BROKEN PRODUCT:
//   - S1.6: a photo listed twice (a path in two `files` rows or twice in one result list), a different number of files rows under
//     overlap than `expect listing overlap` names, a menu photo count that is not golden's plus overlap's each counted once
//     (a product that counted the overlap twice shows 8 more).
//   - the floor tests: a floor that differs from the recount, or an `auto` id of the count that verify.md says needs a person.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

private func stripComments(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

private func has(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func shellFunctions(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    var name: String?
    var body: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if name == nil {
            if let r = line.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\(\\) \\{( #.*)?$", options: .regularExpression) {
                name = String(line[r].split(separator: "(")[0])
                body = []
            } else if let r = line.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\(\\) \\{ .* \\}$", options: .regularExpression) {
                result[String(line[r].split(separator: "(")[0])] = line
            }
        } else if line == "}" {
            result[name!] = body.joined(separator: "\n")
            name = nil
        } else {
            body.append(line)
        }
    }
    return result
}

private func firstIndex(_ text: String, _ pattern: String, after: Int = 0) -> Int? {
    guard let start = text.index(text.startIndex, offsetBy: after, limitedBy: text.endIndex),
          let r = text.range(of: pattern, options: .regularExpression, range: start..<text.endIndex) else { return nil }
    return text.distance(from: text.startIndex, to: r.lowerBound)
}

private func inOrder(_ text: String, _ patterns: [String], _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
    var from = 0
    for p in patterns {
        guard let at = firstIndex(text, p, after: from) else {
            ok(false, "\(what): `\(p)` is missing, or comes before the pattern before it", sourceLocation: sourceLocation)
            return
        }
        from = at + 1
    }
}

private func tsv(_ name: String) -> [[String]] {
    (read(libDir.appendingPathComponent(name)) ?? "").split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
}

private func extensions(kind: String) -> Set<String> {
    for line in (read(libDir.appendingPathComponent("extensions.txt")) ?? "").split(separator: "\n") where line.hasPrefix(kind + ": ") {
        return Set(line.dropFirst(kind.count + 2).split(separator: " ").map(String.init))
    }
    return []
}

// MARK: the overlap fixture

@Suite("KitRunOverlapFixtureTests")
struct KitRunOverlapFixtureTests {

    @Test("overlap.tsv is a hand-written table: golden photos to places under overlap, a photos/ subfolder and loose photos in the parent")
    func table() {
        let rows = tsv("overlap.tsv")
        ok(!rows.isEmpty, "scripts/kit-lib/overlap.tsv is missing or empty")
        ok(rows.allSatisfy { $0.count == 2 }, "a row of overlap.tsv does not have two columns (source under golden/, place under overlap/)")
        let scenes = Set(tsv("golden-photos.tsv").compactMap { $0.first })
        for r in rows where r.count == 2 {
            ok(scenes.contains(r[0]), "overlap.tsv takes \(r[0]) from golden, which golden-photos.tsv does not make")
            ok(!r[1].hasPrefix("/") && !r[1].contains(".."), "overlap.tsv names a place that leaves the folder: \(r[1])")
        }
        let places = rows.compactMap { $0.count == 2 ? $0[1] : nil }
        ok(Set(places).count == places.count, "overlap.tsv names a place twice")
        ok(places.contains { $0.hasPrefix("photos/") }, "overlap.tsv puts no photo in the photos/ subfolder")
        ok(places.contains { !$0.contains("/") }, "overlap.tsv puts no loose photo in the parent (a parent that holds only its photos/ subfolder is the case the picker turns into the subfolder)")
        ok(places.filter { $0.hasPrefix("photos/") }.count >= 2, "the photos/ subfolder holds fewer than two photos")
    }

    @Test("expected-counts.tsv has a hand-written row for overlap that equals the photos of overlap.tsv")
    func expectedCounts() {
        let photo = extensions(kind: "photo")
        ok(!photo.isEmpty, "extensions.txt lists no photo extensions")
        let table = tsv("overlap.tsv").compactMap { $0.count == 2 ? $0[1] : nil }
        let fromTable = table.filter { photo.contains(($0 as NSString).pathExtension.lowercased()) }.count
        let rows = tsv("expected-counts.tsv").filter { $0.first == "overlap" }
        ok(rows.count == 1 && rows[0].count == 3 && rows[0][1] == "photo", "expected-counts.tsv has no single `overlap photo <n>` row (found \(rows))")
        ok(Int(rows.first?[2] ?? "") == fromTable && fromTable == table.count,
           "expected-counts.tsv says \(rows.first?[2] ?? "nothing") photos for overlap, overlap.tsv makes \(fromTable) of \(table.count) files")
    }

    @Test("kit-fixtures.sh builds overlap: usage line, the dispatch, and a builder that copies from golden under KIT_ROOT and deletes only inside overlap")
    func builder() {
        let text = read(scriptsDir.appendingPathComponent("kit-fixtures.sh")) ?? ""
        let code = stripComments(text)
        ok(text.contains("kit-fixtures.sh build overlap"), "kit-fixtures.sh usage has no `kit-fixtures.sh build overlap` line")
        ok(has(code, "overlap\\)[^\\n]*build_overlap"), "kit-fixtures.sh main has no `overlap)` branch that runs build_overlap")
        let fns = shellFunctions(in: code)
        let b = fns["build_overlap"] ?? ""
        ok(!b.isEmpty, "kit-fixtures.sh has no build_overlap")
        ok(b.contains("overlap.tsv") || b.contains("OVERLAP_TABLE") || b.contains("overlap_rows"), "build_overlap does not read overlap.tsv")
        ok(has(b, "cp -p[^\\n]*golden"), "build_overlap does not copy the golden photos (with their times, cp -p)")
        ok(has(b, "\\$FIX/golden"), "build_overlap does not take its photos from fixtures/golden under KIT_ROOT")
        ok(!has(b, "\\bsudo\\b|git |curl"), "build_overlap uses sudo, git or the network")
        // every removal is inside fixtures/overlap
        for line in b.split(separator: "\n") where has(String(line), "\\brm\\b") {
            ok(has(String(line), "\\$stray|\\$FIX/overlap"), "build_overlap removes something that is not inside fixtures/overlap: \(line)")
        }
        ok(!has(b, "build_golden"), "build_overlap builds golden itself (it must stop with a clear line when golden is missing, so the helper tool is not compiled here)")
        ok(has(b, "build golden first|golden first"), "build_overlap says nothing about golden having to be built first")
    }
}

// MARK: the builder, run in a throwaway KIT_ROOT

/// `kit-fixtures.sh <args>` as a child process with its own throwaway KIT_ROOT (a folder named sesame-kit*, under a private
/// base folder), a private TMPDIR and a decoy HOME, as KitFixturesSlice2Tests runs it. The build modes write only under that
/// KIT_ROOT. The golden photos are not drawn here (that compiles the picture tool): the test writes stand-in files at the
/// places overlap.tsv names, because the overlap builder only copies them.
private struct OverlapRig {
    let base: URL
    var kit: URL { base.appendingPathComponent("sesame-kit-ovtest", isDirectory: true) }
    var fixtures: URL { kit.appendingPathComponent("fixtures", isDirectory: true) }
    var overlap: URL { fixtures.appendingPathComponent("overlap", isDirectory: true) }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("kitov-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    /// Stand-ins for the golden photos the table takes: distinct bytes, a fixed old modified time.
    func writeGolden(_ sources: [String], time: Date = Date(timeIntervalSince1970: 1_768_473_000)) throws {
        for (i, s) in sources.enumerated() {
            let url = fixtures.appendingPathComponent("golden/" + s)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("golden stand-in \(i) \(s)".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: url.path)
        }
    }

    func kitFixtures(_ args: [String]) throws -> (status: Int32, output: String) {
        let out = base.appendingPathComponent("out-" + UUID().uuidString)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptsDir.appendingPathComponent("kit-fixtures.sh").path] + args
        var env = ProcessInfo.processInfo.environment
        env["KIT_ROOT"] = kit.path
        env["TMPDIR"] = base.appendingPathComponent("tmp").path + "/"
        env["HOME"] = base.appendingPathComponent("home").path
        env["KIT_NO_EVIDENCE"] = "1"
        p.environment = env
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try? handle.synchronize()
        return (p.terminationStatus, (try? String(contentsOf: out, encoding: .utf8)) ?? "")
    }

    func files(under url: URL) -> [String] {
        // both sides spelled the same way (the enumerator reports /private/var/..., the rig's URL /var/...)
        let root = url.resolvingSymlinksInPath().path
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { ($0 as? URL) }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.resolvingSymlinksInPath().path.dropFirst(root.count + 1)) }.sorted()
    }

    func mtime(_ url: URL) -> Int {
        Int(((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? -1)
    }
}

@Suite("KitRunOverlapBuildTests", .serialized)
struct KitRunOverlapBuildTests {
    private let rows = tsv("overlap.tsv").filter { $0.count == 2 }

    @Test("build overlap without golden stops with one line naming `build golden first` and writes nothing under overlap")
    func needsGolden() throws {
        let rig = try OverlapRig()
        defer { rig.remove() }
        let ran = try rig.kitFixtures(["build", "overlap"])
        #expect(ran.status != 0, "build overlap exited 0 with no golden photos: \(ran.output)")
        #expect(ran.output.contains("build golden first"), "no line says golden must be built first: \(ran.output)")
        #expect(rig.files(under: rig.overlap).isEmpty, "files were written without golden: \(rig.files(under: rig.overlap))")
    }

    @Test("build overlap copies each photo of overlap.tsv to its place with the golden time kept: six under photos/, two loose, nothing else")
    func copies() throws {
        let rig = try OverlapRig()
        defer { rig.remove() }
        try rig.writeGolden(rows.map { $0[0] })
        let ran = try rig.kitFixtures(["build", "overlap"])
        #expect(ran.status == 0, "build overlap exited \(ran.status): \(ran.output)")
        #expect(ran.output.contains("BUILT overlap: 8 files written"), "the build line: \(ran.output)")
        #expect(rig.files(under: rig.overlap) == rows.map { $0[1] }.sorted(), "overlap holds \(rig.files(under: rig.overlap))")
        for r in rows {
            let from = rig.fixtures.appendingPathComponent("golden/" + r[0]), to = rig.overlap.appendingPathComponent(r[1])
            #expect((try? Data(contentsOf: from)) == (try? Data(contentsOf: to)), "\(r[1]) is not a copy of golden/\(r[0])")
            #expect(rig.mtime(to) == rig.mtime(from) && rig.mtime(to) > 0, "\(r[1]) lost the golden modified time")
        }
        #expect(rig.files(under: rig.overlap).filter { $0.hasPrefix("photos/") }.count == 6)
        #expect(rig.files(under: rig.overlap).filter { !$0.contains("/") }.count == 2, "two photos must lie loose in the parent")
        // golden itself is untouched
        #expect(rig.files(under: rig.fixtures.appendingPathComponent("golden")).count == rows.count)
    }

    @Test("a second build writes nothing; a stray file goes, a changed copy is written again, a changed time is written again")
    func idempotentAndRepairs() throws {
        let rig = try OverlapRig()
        defer { rig.remove() }
        try rig.writeGolden(rows.map { $0[0] })
        _ = try rig.kitFixtures(["build", "overlap"])
        let again = try rig.kitFixtures(["build", "overlap"])
        #expect(again.status == 0 && again.output.contains("UNCHANGED overlap: 8 files already right"), "second build: \(again.output)")
        // a stray, a changed copy, a copy with a new time
        let stray = rig.overlap.appendingPathComponent("photos/stray.jpg"), loose = rig.overlap.appendingPathComponent("top-stray.png")
        try Data("x".utf8).write(to: stray)
        try Data("y".utf8).write(to: loose)
        let first = rig.overlap.appendingPathComponent(rows[0][1]), second = rig.overlap.appendingPathComponent(rows[1][1])
        try Data("changed".utf8).write(to: first)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: second.path)
        let fixed = try rig.kitFixtures(["build", "overlap"])
        #expect(fixed.status == 0 && fixed.output.contains("BUILT overlap: 2 files written, 6 left as they were, 2 removed"), "repair build: \(fixed.output)")
        #expect(!FileManager.default.fileExists(atPath: stray.path) && !FileManager.default.fileExists(atPath: loose.path), "a stray file was kept")
        #expect(rig.files(under: rig.overlap) == rows.map { $0[1] }.sorted())
        let golden = rig.fixtures.appendingPathComponent("golden/" + rows[0][0])
        #expect((try? Data(contentsOf: first)) == (try? Data(contentsOf: golden)), "the changed copy was not written again")
        #expect(rig.mtime(second) == rig.mtime(rig.fixtures.appendingPathComponent("golden/" + rows[1][0])), "the copy with a new time was not written again")
    }

    @Test("expect counts overlap equals the hand-written row: 8 photos, however they lie, each counted once")
    func expectCounts() throws {
        let rig = try OverlapRig()
        defer { rig.remove() }
        try rig.writeGolden(rows.map { $0[0] })
        _ = try rig.kitFixtures(["build", "overlap"])
        let ran = try rig.kitFixtures(["expect", "counts", "overlap"])
        #expect(ran.status == 0 && ran.output.contains("photo 8") && ran.output.contains("COUNTS OK overlap"), "expect counts overlap: \(ran.output)")
        let listing = try rig.kitFixtures(["expect", "listing", "overlap"])
        #expect(listing.output.contains("LISTING OK overlap: 8 paths"), "expect listing overlap: \(listing.output)")
        // PLANT: one photo gone, so the count differs and expect counts must say so
        try FileManager.default.removeItem(at: rig.overlap.appendingPathComponent(rows[0][1]))
        let broken = try rig.kitFixtures(["expect", "counts", "overlap"])
        #expect(broken.status != 0 && broken.output.contains("COUNTS FAILED overlap"), "a missing photo was not named: \(broken.output)")
    }
}

// MARK: S1.6

@Suite("KitRunS16OverlapTests")
struct KitRunS16OverlapTests {
    private var body: String { shellFunctions(in: stripComments(read(libDir.appendingPathComponent("checks-s1c.sh")) ?? ""))["s1_check_6"] ?? "" }

    @Test("S1.6 builds the overlap and picks the parent and the subfolder through the picker in Settings, one section at a time")
    func picks() {
        let b = body
        ok(!b.isEmpty, "checks-s1c.sh has no s1_check_6")
        ok(has(b, "build overlap"), "S1.6 does not build the overlap fixture")
        inOrder(b, ["build overlap", "settings_section[ ]+Folders", "drive_picker[^\\n]*overlap\"?[ ]*\\)?[;\\n ]", "drive_picker[^\\n]*overlap/photos", "settings_section[ ]+Indexing", "click \"Start indexing\"",
                    "wait done"], "S1.6 order: build, Folders, the two picks, Indexing, Start indexing, wait for done")
        ok(has(b, "PK_WINDOW=settings[ ]+drive_picker"), "S1.6 picks in the setup window instead of Settings")
    }

    @Test("S1.6 needs both exact paths in the list, and is NEEDS-A-PERSON for the picker step alone when the picker did not add both")
    func exactPair() {
        let b = body
        ok(has(b, "ax_folders|s1c_folders"), "S1.6 does not read the picked list through the folder reader")
        ok(has(b, "real_path[^\\n]*overlap"), "S1.6 does not compare the list with the real path of overlap")
        ok(b.contains("NEEDS-A-PERSON"), "S1.6 never prints NEEDS-A-PERSON (the pair not picked: the check would prove nothing and must not pass)")
        ok(has(b, "pick[^\\n]*by hand|Add folder…[^\\n]*pick"), "the NEEDS-A-PERSON line does not say which folder to pick by hand")
        ok(has(b, "kit-run\\.sh S1 --ids S1\\.6|--ids S1.6"), "the NEEDS-A-PERSON line does not say how to run the check again")
    }

    @Test("S1.6 reads one files row per path under overlap and under golden/photos, no path twice in a list, and the menu's photo count")
    func reads() {
        let b = body
        ok(has(b, "under[ ]+overlap"), "S1.6 never reads `kit-index.sh under overlap`")
        ok(has(b, "under[ ]+golden/photos"), "S1.6 no longer reads `kit-index.sh under golden/photos`")
        ok(has(b, "expect[ ]+listing[ ]+overlap"), "S1.6 does not compare the rows under overlap with `kit-fixtures.sh expect listing overlap`")
        ok(has(b, "expect[ ]+listing[ ]+golden"), "S1.6 no longer compares golden's rows with `expect listing golden`")
        ok(has(b, "s6b_expected[^\\n]*overlap") && has(b, "s6b_expected[^\\n]*golden"), "S1.6 does not take the photo count from `expect counts` of overlap and of golden")
        ok(has(b, "twice|duplicate|uniq|seen\\["), "S1.6 does not look for a path that appears twice")
        ok(has(b, "dump[ ]+menu|s7_menu"), "S1.6 never reads the status item's menu")
        // the expected count is golden's plus overlap's, each once
        ok(has(b, "exp_g[^\\n]*\\+[^\\n]*exp_o|\\$\\(\\(.*exp_g.*exp_o") || has(b, "\\+[^\\n]*overlap"), "S1.6 does not add the two expected photo counts")
        ok(has(b, "\\$S1_RC|return 4"), "S1.6 has no RERUN or exit path for a precondition that did not hold")
    }

    @Test("S1.6 reads the picked list through ax_folders (s1c_folders), not the old absolute-path label")
    func listReader() {
        let fns = shellFunctions(in: stripComments(read(libDir.appendingPathComponent("checks-s1c.sh")) ?? ""))
        ok(has(fns["s1c_folders"] ?? "", "ax_folders"), "s1c_folders does not read folder rows through ax_folders")
    }
}

// MARK: checks.floor

@Suite("KitRunFloorHonestyTests")
struct KitRunFloorHonestyTests {
    /// The ids of slices 1 to 3 whose check, as the shell runs it, primes or uses the administrator session: S6.8 (the file
    /// trace), and from slice 3 S8.2, S8.3 (the file trace), S8.7 and S6.13 (the network summary, which reads a trace); S7.4 and
    /// S7.18 are `auto-or-person`. Hand-written, as in KitRunS1S8ChecksTests. plan-3-t12b, reason for this edit: slice 3 adds four
    /// administrator ids, and S8.1 and S8.9 stay counted (their trace is optional, plan-3 D15).
    private let adminAuto: Set<String> = ["S6.8", "S8.2", "S8.3", "S8.7", "S6.13"]
    /// The hand recount of the floor at slice 3 (plan-3-t12b): 75 `auto` ids of slices 1 to 3 minus the five administrator ids = 70
    /// (plan 2's 62 plus S2.2, S2.3, S2.8, S2.17, S8.1, S8.5, S8.6, S8.9). Written by hand, not read from checks.floor.
    /// plan-4-t3 (amended by the tester, never lowered): slice 4 adds eleven ids, nine of them `auto` (S2.4, S3.1, S3.2, S3.3, S3.5, S3.6, S3.7,
    /// S3.8, S3.10) and two `auto-or-person` that never count (S3.4, S3.9), none of them an administrator id: 70 + 9 = 79 (the entry's
    /// 81 was a guess that counted S3.4 and S3.9). Written by hand, not read from checks.floor.
    /// plan-5-t1b (amended by the tester, reason: slice 5 is built, so the kit runs the ids of slices 1 to 5): slice 5 adds twelve ids, seven of
    /// them `auto` (S2.5, S4.1, S4.3, S4.4, S4.6, S4.9, S4.10) and five `auto-or-person` that never count (S4.2, S4.5, S4.7, S4.8, S8.8), none
    /// of them an administrator id that counts: 79 + 7 = 86 (the entry's "81 plus the new ids" was a guess). Written by hand, not read from
    /// checks.floor. The floor is raised and never lowered.
    private let recountedFloorAtSlice5 = 85
    private let recountedFloorWithoutCode = 93
    /// The `auto-or-person` ids of slices 1 and 2: verify.md, Build slices, Slice 2: "S7.1 to S7.18 (S7.4 is `auto-or-person`)",
    /// and its Launch at login entry (Not covered: S7.18 is NEEDS-A-PERSON when sfltool shows no entry).
    private let personIds: Set<String> = ["S7.4", "S7.18"]

    private func rows() -> [(id: String, slice: Int, kind: String)] {
        tsv("checks.tsv").filter { $0.count >= 3 }.map { ($0[0], Int($0[1]) ?? 99, $0[2]) }
    }

    // plan-3-t12b: moved by hand from `slice <= 2` and the one-id list to `slice <= 3` and the five-id list (slice 3 is built); the floor
    // must equal the recount, 70, and is never lowered.
    // plan-4-t3 (amended by the tester, reason: slice 4 is built, so the kit runs the ids of slices 1 to 4): `slice <= 4`, the recount 79.
    // The five administrator ids are the same (no id of slice 4 primes the administrator session or reads a trace); the figure only grew.
    @Test("checks.floor is the number of auto ids of slices 1 to 5 whose check can reach PASS without a person, recounted from checks.tsv")
    func floorIsTheRecount() {
        let all = rows()
        let counted = all.filter { $0.kind == "auto" && $0.slice <= 5 && !adminAuto.contains($0.id) }
        let floorText = (read(libDir.appendingPathComponent("checks.floor")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ok(!all.contains { $0.id.hasPrefix("S5.") }, "checks.tsv still holds an S5 id")
        let second = ["S2.15"].filter { id in all.contains { $0.id == id && $0.slice == 6 && $0.kind == "auto" } }
        ok(second.count == 1, "checks.tsv does not hold S2.15 as an auto id of slice 6")
        let seventh = all.filter { $0.slice == 7 && $0.kind == "auto" && !adminAuto.contains($0.id) }
        ok(seventh.map(\.id) == ["S9.1", "S9.2", "S9.3", "S9.4", "S9.5"], "the auto ids of slice 7 are \(seventh.map(\.id)), expected S9.1 to S9.5")
        let eighth = all.filter { $0.slice == 8 && $0.kind == "auto" && !adminAuto.contains($0.id) }
        ok(eighth.map(\.id) == ["S10.5", "S10.8"], "the auto ids of slice 8 are \(eighth.map(\.id)), expected S10.5 and S10.8 (plan-8-t9 amended: floor 91 + 2 = 93)")
        ok(Int(floorText) == counted.count + second.count + seventh.count + eighth.count, "checks.floor reads \(floorText), the recount is \(counted.count) auto ids of slices 1 to 5 without administrator rights plus \(second.count) of slice 6 plus \(seventh.count) of slice 7 plus \(eighth.count) of slice 8")
        ok(counted.count == recountedFloorAtSlice5, "the recount from checks.tsv is \(counted.count), the hand recount is \(recountedFloorAtSlice5)")
        ok(Int(floorText) == recountedFloorWithoutCode, "checks.floor reads \(floorText), the hand recount without the code ids is \(recountedFloorWithoutCode)")
        ok(Set(counted.map(\.id)).count == counted.count, "an id is counted twice")
        for r in counted { ok(!personIds.contains(r.id), "\(r.id) is counted by the floor but verify.md says it needs a person") }
    }

    @Test("the auto-or-person ids of slices 1 and 2 are exactly the ones verify.md names, S7.4 and S7.18")
    func personIdsAreVerifyMds() {
        let marked = Set(rows().filter { $0.kind == "auto-or-person" && $0.slice <= 2 }.map(\.id))
        ok(marked == personIds, "checks.tsv marks \(marked.sorted()) auto-or-person in slices 1 and 2, verify.md names \(personIds.sorted())")
    }

    // An id is reclassified only where verify.md says it needs a person: for each id the review and the accept log name
    // (S1.9, S1.14, S1.29), the kind in checks.tsv follows whether a line of verify.md names it together with a needs-a-person
    // statement. Today no line does, so they stay `auto`; a later verify.md edit makes this test ask for the change.
    @Test("S1.9, S1.14 and S1.29 are auto-or-person exactly when a line of verify.md says that id needs a person", arguments: ["S1.9", "S1.14", "S1.29"])
    func reclassifiedOnlyWhereVerifyMdSays(_ id: String) {
        let verify = read(projectRoot.appendingPathComponent(".ril/docs/verification/verify.md")) ?? ""
        ok(!verify.isEmpty, "verify.md not found")
        // a clause is what lies between two semicolons of a line: a list of ids ("S6.1 to S6.4, ...; S7.1 to S7.18 (S7.4 is
        // `auto-or-person`)") says something of one id only inside its own clause
        let lines = verify.split(separator: "\n").flatMap { $0.split(separator: ";") }.map(String.init).filter { clause in
            has(clause, "\\b" + NSRegularExpression.escapedPattern(for: id) + "\\b") && has(clause.lowercased(), "needs-a-person|needs a person|auto-or-person")
        }
        let kind = rows().first { $0.id == id }?.kind
        ok(kind == (lines.isEmpty ? "auto" : "auto-or-person"),
           "\(id) is \(kind ?? "missing") in checks.tsv; \(lines.isEmpty ? "no line of verify.md says it needs a person, so it stays auto" : "verify.md says it needs a person (\(lines.first ?? "")), so it is auto-or-person")")
    }

    @Test("checks.floor is one number, and S1.6 is still an auto id of slice 2 that the floor counts")
    func floorShapeAndS16() {
        let text = read(libDir.appendingPathComponent("checks.floor")) ?? ""
        ok(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil && text.split(separator: "\n").count == 1, "checks.floor is not one number: \(text.debugDescription)")
        ok(rows().contains { $0.id == "S1.6" && $0.slice == 2 && $0.kind == "auto" }, "S1.6 is no longer an auto id of slice 2")
    }
}
