import Foundation
import Testing
import SesameEngine

// plan-3-t18, tester step. S2.17: every photo extension is read and found by its name. Written from the t18 entry, the hand
// written table scripts/kit-lib/gate-matrix.csv (the `ext-*` cells), GroupATests and IndexOverlapTests for the interface and
// the helper rig; no product source read. The expected values are the table's (the cell names, their file names and the
// unique token `zq` plus four digits in each) and are never computed from the code under test.
//
// The matrix is built by `kit-fixtures.sh build matrix` in a temp kit root (nothing shared is touched). The bundled helper
// alone (no app, no window) with the fake embedder indexes `matrix/ext/`, one file per photo extension. Then, for each
// `ext-*` cell: its row is `done`, and its unique name stem typed alone (for example `jpeg_zq0011`) puts the file first in
// the ranked list of `Search` (the query vector comes from the cached text model, as in GroupATests).
//
// The entry says this suite may already be green when it arrives (the name tier exists today for a unique stem); the tester
// says which in the report.

/// Every extension cell of the table, written by hand from the spec's photo list (jpeg, jpg, png, heic, webp, tiff, tif, gif).
private let extCells = ["ext-jpeg", "ext-jpg", "ext-png", "ext-heic", "ext-webp", "ext-tiff", "ext-tif", "ext-gif"]

private struct ExtCell: Sendable {
    let cell: String
    let path: String      // under matrix/
    var file: String { (path as NSString).lastPathComponent }
    var stem: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    var ext: String { (path as NSString).pathExtension }
}

private struct ExtOutcome: Sendable {
    let cells: [ExtCell]
    let statuses: [String: String]        // cell file name to its row status ("" when there is no row)
    let rowCount: Int
    let lists: [String: [String]]         // cell to the ranked paths of its stem
}

private final class ExtRun: @unchecked Sendable {
    static let shared: Result<ExtOutcome, GBFailure> = {
        do { return .success(try perform()) } catch let failure as GBFailure { return .failure(failure) } catch {
            return .failure(GBFailure("\(error)"))
        }
    }()

    /// The `ext-*` rows of the table: `cell,path,picks,expected_in_index,expected_rows,expected_reason,group`.
    private static func tableCells() throws -> [ExtCell] {
        let url = GB.projectRoot.appendingPathComponent("scripts/kit-lib/gate-matrix.csv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw GBFailure("scripts/kit-lib/gate-matrix.csv is missing: \(url.path)")
        }
        var cells: [ExtCell] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where index > 0 {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7, f[0].hasPrefix("ext-") else { continue }
            if f[3] == "no", f[4] == "0", f[5] == "unsupported" { continue }
            guard f[3] == "yes", f[4] == "1" else { throw GBFailure("the table's cell \(f[0]) is not a read cell: \(line)") }
            cells.append(ExtCell(cell: f[0], path: f[1]))
        }
        return cells
    }

    private static func perform() throws -> ExtOutcome {
        let cells = try tableCells()
        guard cells.map(\.cell) == extCells else {
            throw GBFailure("the table's ext cells are \(cells.map(\.cell)), expected \(extCells)")
        }
        guard let kit = GB.kitRoot() else { throw GBFailure("no KIT_ROOT and no TMPDIR: cannot find the kit") }
        let models = try GB.models(kit: kit)
        guard FileManager.default.isExecutableFile(atPath: GB.bundledHelper.path) else {
            throw GBFailure("the bundled helper is missing: run `scripts/bundle.sh` (expected \(GB.bundledHelper.path))")
        }

        let work = GB.realpathOf(FileManager.default.temporaryDirectory.appendingPathComponent("sesame-ext-" + UUID().uuidString).path)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }

        // The matrix in a temp kit root.
        let tempKit = work + "/sesame-kit-ext"
        let tmp = work + "/tmp"
        let decoyHome = work + "/decoy-home"
        for dir in [tempKit + "/run", tmp, decoyHome] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let env = ["KIT_ROOT": tempKit, "TMPDIR": tmp + "/", "HOME": decoyHome,
                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        let build = GB.runChild("/bin/bash", [GB.projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path, "build", "matrix"],
                                env: env, limit: 1800)
        guard let built = build, built.status == 0 else {
            throw GBFailure("kit-fixtures.sh build matrix failed: \(GB.tail(build?.output ?? "not started"))")
        }
        let extFolder = tempKit + "/fixtures/matrix/ext"
        for cell in cells {
            let file = tempKit + "/fixtures/matrix/" + cell.path
            guard FileManager.default.fileExists(atPath: file) else { throw GBFailure("cell \(cell.cell): \(file) was not built") }
        }

        // The query vectors: the cached text model embeds each stem.
        let vectors = try GB.embedQueries(cells.map(\.stem), textModel: models.text)

        // The helper alone, fake embedder, over matrix/ext.
        let home = work + "/home"
        try GB.makeSupportFolder(home: home)
        let helper = try GBHelper(home: home, models: nil, scratch: URL(fileURLWithPath: work))
        defer { helper.stop() }
        helper.sendFolders([extFolder])
        let settled = GB.settle(home: home, helper: helper, rows: cells.count, stall: 300, cap: 900)
        guard settled.ok else { throw GBFailure("indexing \(extFolder): \(settled.note)") }
        helper.stop()

        var statuses: [String: String] = [:]
        for cell in cells { statuses[cell.cell] = settled.rows.first { $0.path.hasSuffix("/" + cell.file) }?.status ?? "" }

        let opened = GB.openReader(home: home, files: cells.count)
        guard let reader = opened.reader else { throw GBFailure("the index holds \(opened.count) files, expected \(cells.count)") }
        defer { reader.close() }
        let search = Search(reader: reader)
        defer { search.release() }
        let visible = GB.visible([extFolder])
        var lists: [String: [String]] = [:]
        for cell in cells {
            guard let vector = vectors[cell.stem] else { throw GBFailure("no vector for \(cell.stem)") }
            lists[cell.cell] = GB.ranked(search, cell.stem, vector, visible) ?? []
        }
        return ExtOutcome(cells: cells, statuses: statuses, rowCount: settled.rows.count, lists: lists)
    }
}

private func outcome() throws -> ExtOutcome {
    switch ExtRun.shared {
    case .success(let value): return value
    case .failure(let failure): throw failure
    }
}

@Suite("ExtensionsTests", .serialized)
struct ExtensionsTests {

    @Test func everyExtCellOfTheBuiltMatrixIsDone() throws {
        let run = try outcome()
        #expect(run.rowCount == 8, "the helper indexed \(run.rowCount) files under matrix/ext, expected one per photo extension (8)")
        for cell in run.cells {
            #expect(run.statuses[cell.cell] == "done",
                    "\(cell.cell) (\(cell.file)): row status \(run.statuses[cell.cell].map { $0.isEmpty ? "no row" : $0 } ?? "no row"), expected done")
        }
    }

    @Test func theUniqueNameStemOfEveryExtCellTypedAlonePutsItsFileFirst() throws {
        let run = try outcome()
        var notFirst: [String] = []
        for cell in run.cells {
            let list = run.lists[cell.cell] ?? []
            let place = list.firstIndex { $0.hasSuffix("/" + cell.file) }.map { $0 + 1 }
            print("EXT \(cell.cell) \(cell.ext) stem \(cell.stem) rank \(place.map(String.init) ?? "none")")
            if place != 1 {
                notFirst.append("\(cell.cell) \"\(cell.stem)\" rank \(place.map(String.init) ?? "none") (list: \(list.map { ($0 as NSString).lastPathComponent }))")
            }
        }
        #expect(notFirst.isEmpty, "the file is not first for \(notFirst.count) of \(run.cells.count) cells: \(notFirst.joined(separator: "; "))")
    }
}
