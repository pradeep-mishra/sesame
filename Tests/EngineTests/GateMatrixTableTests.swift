import Foundation
import Testing

// plan-3-t1, tester step: the hand-written gate matrix table `scripts/kit-lib/gate-matrix.csv` and the extension list
// `scripts/kit-lib/extensions.txt`. Written from the spec (Goals, S8, Fixtures), the design (section 4, never read) and
// verify.md (Fixture key, the overlap pairs and the extras group) only. No product source is read, and no expected value
// below comes from `Rules`, `Walker` or any other product type: every table here is written by hand.
//
// The table is the hand-written source of every expected value in later tasks (the fixture builder, `expect matrix`,
// the S8.5 and S8.6 checks, the admission tests). This suite checks the table itself: its shape, the values of each
// required cell, and that the spec's six extension lists are in `extensions.txt`.

private let gmProjectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let gmCSV = gmProjectRoot.appendingPathComponent("scripts/kit-lib/gate-matrix.csv")
private let gmExtensions = gmProjectRoot.appendingPathComponent("scripts/kit-lib/extensions.txt")

// MARK: hand-written tables

private let gmHeader = "cell,path,picks,expected_in_index,expected_rows,expected_reason,group"

private let gmReasons: Set<String> = [
    "ok", "key-name", "hidden-folder", "caches", "app-bundle", "cloud-only", "link", "unsupported", "never-picked",
    "git-ignored", "vendored", "could-not-read",
]

/// The spec's six extension lists (Goals, "Files Sesame reads, by extension"), one line per kind, written by hand.
private let gmSpecLists: [(kind: String, extensions: [String])] = [
    ("photo", ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"]),
    ("document", ["txt", "md", "rtf", "docx", "html", "odt"]),
    ("audio", ["mp3", "m4a", "wav", "aac", "flac"]),
    ("video", ["mp4", "mov", "m4v"]),
    ("pdf", ["pdf"]),
    ("code", ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"]),
]

/// One required cell with its hand value. `roots` (when set) is the expected effective pick roots, sorted; a blank
/// `picks` field means the cell's own top folder.
private struct Want {
    let id: String
    let inIndex: String
    let rows: String
    let reason: String
    var group = "spec"
    var ext: String?
    var dir: String?
    var dirSuffix: String?
    var name: String?
    var namePrefix: String?
    var roots: [String]?
}

private func want(
    _ id: String, _ inIndex: String, _ rows: String, _ reason: String, group: String = "spec",
    ext: String? = nil, dir: String? = nil, dirSuffix: String? = nil, name: String? = nil,
    namePrefix: String? = nil, roots: [String]? = nil
) -> Want {
    Want(id: id, inIndex: inIndex, rows: rows, reason: reason, group: group, ext: ext, dir: dir,
         dirSuffix: dirSuffix, name: name, namePrefix: namePrefix, roots: roots)
}

private let gmRequired: [Want] = [
    want("plain-photo", "yes", "1", "ok", ext: "png"),
    want("plain-doc", "yes", "1", "ok", ext: "txt"),
    want("plain-pdf", "yes", "1", "ok", ext: "pdf"),
    want("plain-audio", "yes", "1", "ok", ext: "wav"),
    want("plain-video", "yes", "1", "ok", ext: "mp4"),
    want("plain-code-off", "no", "0", "unsupported", ext: "py", roots: ["plain"]),
    want("plain-code-on", "no", "0", "unsupported", ext: "py", roots: ["plain-code-on"]),

    want("ext-jpeg", "yes", "1", "ok", ext: "jpeg"),
    want("ext-jpg", "yes", "1", "ok", ext: "jpg"),
    want("ext-png", "yes", "1", "ok", ext: "png"),
    want("ext-heic", "yes", "1", "ok", ext: "heic"),
    want("ext-webp", "yes", "1", "ok", ext: "webp"),
    want("ext-tiff", "yes", "1", "ok", ext: "tiff"),
    want("ext-tif", "yes", "1", "ok", ext: "tif"),
    want("ext-gif", "yes", "1", "ok", ext: "gif"),

    want("extdoc-txt", "yes", "1", "ok", ext: "txt", dir: "extdoc"),
    want("extdoc-md", "yes", "1", "ok", ext: "md", dir: "extdoc"),
    want("extdoc-rtf", "yes", "1", "ok", ext: "rtf", dir: "extdoc"),
    want("extdoc-docx", "yes", "1", "ok", ext: "docx", dir: "extdoc"),
    want("extdoc-html", "yes", "1", "ok", ext: "html", dir: "extdoc"),
    want("extdoc-odt", "yes", "1", "ok", ext: "odt", dir: "extdoc"),
    want("extdoc-pdf", "yes", "1", "ok", ext: "pdf", dir: "extdoc"),

    want("extav-mp3", "yes", "1", "ok", ext: "mp3", dir: "extav"),
    want("extav-m4a", "yes", "1", "ok", ext: "m4a", dir: "extav"),
    want("extav-wav", "yes", "1", "ok", ext: "wav", dir: "extav"),
    want("extav-aac", "yes", "1", "ok", ext: "aac", dir: "extav"),
    want("extav-flac", "yes", "1", "ok", ext: "flac", dir: "extav"),
    want("extav-mp4", "yes", "1", "ok", ext: "mp4", dir: "extav"),
    want("extav-mov", "yes", "1", "ok", ext: "mov", dir: "extav"),
    want("extav-m4v", "yes", "1", "ok", ext: "m4v", dir: "extav"),

    want("key-id_rsa-txt", "no", "0", "key-name", ext: "txt", namePrefix: "id_rsa"),
    want("key-id_rsa-png", "no", "0", "key-name", ext: "png", namePrefix: "id_rsa"),
    want("key-env-txt", "no", "0", "key-name", ext: "txt", namePrefix: ".env"),
    want("key-env-local-md", "no", "0", "key-name", ext: "md", namePrefix: ".env.local"),
    want("key-env-png", "no", "0", "key-name", ext: "png", namePrefix: ".env."),
    want("key-env-local-png", "no", "0", "key-name", ext: "png", namePrefix: ".env.local."),
    want("key-pem", "no", "0", "unsupported", ext: "pem"),
    want("key-key", "no", "0", "unsupported", ext: "key"),
    want("key-p12", "no", "0", "unsupported", ext: "p12"),
    want("key-pfx", "no", "0", "unsupported", ext: "pfx"),
    want("key-kdbx", "no", "0", "unsupported", ext: "kdbx"),
    want("key-id_rsa-bare", "no", "0", "unsupported", ext: "", namePrefix: "id_rsa"),
    want("key-env-bare", "no", "0", "unsupported", ext: "", namePrefix: ".env"),

    want("extra-id_dsa-md", "no", "0", "key-name", group: "extra", ext: "md", namePrefix: "id_dsa"),
    want("extra-id_ecdsa-txt", "no", "0", "key-name", group: "extra", ext: "txt", namePrefix: "id_ecdsa"),
    want("extra-id_ed25519-png", "no", "0", "key-name", group: "extra", ext: "png", namePrefix: "id_ed25519"),

    want("hidden-ssh-png", "no", "0", "hidden-folder", ext: "png", dir: ".ssh"),
    want("hidden-config-md", "no", "0", "hidden-folder", ext: "md", dir: ".config"),
    want("caches-png", "no", "0", "caches", ext: "png", dir: "Caches"),
    want("app-png", "no", "0", "app-bundle", ext: "png", dirSuffix: ".app"),
    want("app-txt", "no", "0", "app-bundle", ext: "txt", dirSuffix: ".app"),
    want("cloud-sparse-jpg", "no", "0", "cloud-only", ext: "jpg"),
    want("link-png", "no", "0", "link", ext: "png"),
    want("unsup-pptx", "no", "0", "unsupported", ext: "pptx"),
    want("unsup-xlsx", "no", "0", "unsupported", ext: "xlsx"),
    want("unsup-pages", "no", "0", "unsupported", ext: "pages"),
    want("unsup-dng", "no", "0", "unsupported", ext: "dng"),
    want("unsup-noext", "no", "0", "unsupported", ext: ""),
    want("never-picked-png", "no", "0", "never-picked", ext: "png"),
    want("never-picked-code", "no", "0", "unsupported", ext: "py"),
    want("damaged-png", "yes", "0", "could-not-read", ext: "png"),
    want("damaged-swift", "no", "0", "unsupported", ext: "swift", roots: ["damaged-code"]),
    want("good-swift", "no", "0", "unsupported", ext: "swift", roots: ["damaged-code"]),

    want("repo-off-png", "yes", "1", "ok", ext: "png", roots: ["repo-off"]),
    want("repo-off-txt", "yes", "1", "ok", ext: "txt", roots: ["repo-off"]),
    want("repo-off-pdf", "yes", "1", "ok", ext: "pdf", name: "paper_zq1601.pdf", roots: ["repo-off"]),
    want("repo-off-py", "no", "0", "unsupported", ext: "py", roots: ["repo-off"]),
    want("ignored-off-png", "no", "0", "git-ignored", ext: "png", roots: ["ignored-off"]),
    want("ignored-off-txt", "no", "0", "git-ignored", ext: "txt", name: "local_zq1602.txt", roots: ["ignored-off"]),
    want("ignored-on-py", "no", "0", "unsupported", ext: "py", roots: ["ignored-on"]),
    want("ignored-on-txt", "no", "0", "git-ignored", ext: "txt", name: "local_zq1603.txt", roots: ["ignored-on"]),
    want("ignored-on-folder-py", "no", "0", "unsupported", ext: "py", roots: ["ignored-on"]),

    want("vend-in-node_modules-png", "no", "0", "vendored", ext: "png", dir: "node_modules"),
    want("vend-in-Pods-png", "no", "0", "vendored", ext: "png", dir: "Pods"),
    want("vend-in-build-png", "no", "0", "vendored", ext: "png", dir: "build"),
    want("vend-in-dist-png", "no", "0", "vendored", ext: "png", dir: "dist"),
    want("vend-in-dot-build-png", "no", "0", "vendored", ext: "png", dir: ".build"),
    want("vend-in-vendor-png", "no", "0", "vendored", ext: "png", dir: "vendor"),
    want("vend-in-node_modules-txt", "no", "0", "vendored", ext: "txt", dir: "node_modules", name: "note_zq1611.txt", roots: ["vend-in"]),
    want("vend-in-Pods-txt", "no", "0", "vendored", ext: "txt", dir: "Pods", name: "note_zq1612.txt", roots: ["vend-in"]),
    want("vend-in-node_modules-py", "no", "0", "unsupported", ext: "py", dir: "node_modules", roots: ["vend-in"]),

    want("vend-out-node_modules-png", "yes", "1", "ok", ext: "png", dir: "node_modules"),
    want("vend-out-Pods-png", "yes", "1", "ok", ext: "png", dir: "Pods"),
    want("vend-out-build-png", "yes", "1", "ok", ext: "png", dir: "build"),
    want("vend-out-dist-png", "yes", "1", "ok", ext: "png", dir: "dist"),
    want("vend-out-vendor-png", "yes", "1", "ok", ext: "png", dir: "vendor"),
    want("vend-out-dot-build-png", "no", "0", "hidden-folder", ext: "png", dir: ".build"),

    want("ov-a-inner-code", "no", "0", "unsupported", ext: "py", name: "ovainner_zq1101.py",
         roots: ["ov-a/outer", "ov-a/outer/inner"]),
    want("ov-a-outer-code", "no", "0", "unsupported", ext: "py", name: "ovaouter_zq1102.py",
         roots: ["ov-a/outer", "ov-a/outer/inner"]),
    want("ov-a-inner-photo", "yes", "1", "ok", ext: "png", name: "ovaphoto_zq1103.png",
         roots: ["ov-a/outer", "ov-a/outer/inner"]),
    want("ov-a-outer-photo", "yes", "1", "ok", ext: "png", name: "ovaouter_zq1621.png",
         roots: ["ov-a/outer", "ov-a/outer/inner"]),
    want("ov-b-inner-code", "no", "0", "unsupported", ext: "py", name: "ovbinner_zq1104.py",
         roots: ["ov-b/outer", "ov-b/outer/inner"]),
    want("ov-b-outer-code", "no", "0", "unsupported", ext: "py", name: "ovbouter_zq1105.py",
         roots: ["ov-b/outer", "ov-b/outer/inner"]),
    want("ov-b-inner-photo", "yes", "1", "ok", ext: "png",
         roots: ["ov-b/outer", "ov-b/outer/inner"]),
    want("ov-b-outer-photo", "yes", "1", "ok", ext: "png", name: "ovbouter_zq1622.png",
         roots: ["ov-b/outer", "ov-b/outer/inner"]),
    want("ov-c-inner-code", "no", "0", "unsupported", ext: "py", name: "ovcinner_zq1106.py",
         roots: ["ov-c/outer", "ov-c/outer/inner"]),
    want("ov-c-inner-photo", "yes", "1", "ok", ext: "png",
         roots: ["ov-c/outer", "ov-c/outer/inner"]),
    want("ov-c-outer-photo", "yes", "1", "ok", ext: "png",
         roots: ["ov-c/outer", "ov-c/outer/inner"]),
    want("ov-d-inner-code", "no", "0", "unsupported", ext: "py", name: "ovdinner_zq1107.py",
         roots: ["ov-d/outer", "ov-d/outer/inner"]),
    want("ov-d-inner-photo", "yes", "1", "ok", ext: "png",
         roots: ["ov-d/outer", "ov-d/outer/inner"]),
    want("ov-d-outer-photo", "yes", "1", "ok", ext: "png",
         roots: ["ov-d/outer", "ov-d/outer/inner"]),
]

/// Every cell whose file has a code extension, written by hand: each reads no, 0 rows, unsupported, and none is ticked.
private let gmCodeCells: Set<String> = [
    "ext-swift", "ext-py", "ext-js", "ext-ts", "ext-tsx", "ext-jsx", "ext-go", "ext-rs", "ext-java", "ext-kt", "ext-c", "ext-h",
    "ext-cpp", "ext-rb", "ext-sh",
    "plain-code-off", "plain-code-on", "key-code-id_rsa-py", "key-code-env-py", "never-picked-code", "damaged-swift", "good-swift",
    "repo-off-py", "ignored-on-py", "ignored-on-folder-py",
    "vend-in-node_modules-py", "vend-in-Pods-py", "vend-in-build-py", "vend-in-dist-py", "vend-in-dot-build-py", "vend-in-vendor-py",
    "ov-a-inner-code", "ov-a-outer-code", "ov-b-inner-code", "ov-b-outer-code", "ov-c-inner-code", "ov-d-inner-code",
]

private let gmCodeExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "sh"]

/// The extras group, and only these.
private let gmExtras: Set<String> = ["extra-id_dsa-md", "extra-id_ecdsa-txt", "extra-id_ed25519-png"]

// MARK: reading the table

private struct Cell {
    let id: String
    let path: String
    let picks: String
    let inIndex: String
    let rows: String
    let reason: String
    let group: String

    var components: [String] { path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) }
    /// The first component of `path` under matrix/.
    var top: String { components.first ?? "" }
    var fileName: String { components.last ?? "" }
    var folderComponents: [String] { Array(components.dropLast()) }
    var ext: String { (fileName as NSString).pathExtension.lowercased() }
    var isNeverPicked: Bool { picks == "-" }

    /// The pick roots, or nil when `picks` is malformed. Blank: the top folder. `-`: none. A pick is a folder path alone.
    var effectiveRoots: [String]? {
        if picks.isEmpty { return [top] }
        if picks == "-" { return [] }
        var out: [String] = []
        for entry in picks.split(separator: "|", omittingEmptySubsequences: false) {
            let folder = String(entry)
            guard !folder.isEmpty, !folder.contains(":"), !folder.hasPrefix("/"), !folder.hasSuffix("/"), !folder.contains("..") else { return nil }
            out.append(folder)
        }
        return out
    }
}

private func gmRawLines() -> [String]? {
    guard FileManager.default.fileExists(atPath: gmCSV.path),
          let text = try? String(contentsOf: gmCSV, encoding: .utf8) else {
        Issue.record("scripts/kit-lib/gate-matrix.csv does not exist: the hand-written gate matrix table is missing")
        return nil
    }
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
}

/// Every well-formed data row (seven fields). A malformed row is reported by `headerAndFieldsAreWellFormed`.
private func gmCells() -> [Cell]? {
    guard let lines = gmRawLines() else { return nil }
    var cells: [Cell] = []
    for line in lines.dropFirst() {
        let f = line.components(separatedBy: ",")
        guard f.count == 7 else { continue }
        cells.append(Cell(id: f[0], path: f[1], picks: f[2], inIndex: f[3], rows: f[4], reason: f[5], group: f[6]))
    }
    return cells
}

private func gmTokens(in text: String) -> [String] {
    var out: [String] = []
    var rest = Substring(text)
    while let r = rest.range(of: "zq") {
        let after = rest[r.upperBound...]
        let digits = after.prefix(4)
        if digits.count == 4, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) { out.append("zq" + digits) }
        rest = after
    }
    return out
}

private func gmRoots(_ cells: [Cell]) -> Set<String> {
    var out: Set<String> = []
    for c in cells { out.formUnion(c.effectiveRoots ?? []) }
    return out
}

// MARK: the suite

@Suite("GateMatrixTableTests")
struct GateMatrixTableTests {

    @Test func headerAndFieldsAreWellFormed() {
        guard let lines = gmRawLines() else { return }
        #expect(lines.first == gmHeader, "header is not exactly `\(gmHeader)`: \(lines.first ?? "<empty>")")
        #expect(lines.count > 1, "the table has no data row")
        for (index, line) in lines.enumerated() {
            #expect(!line.contains("\r"), "line \(index + 1) holds a carriage return")
            #expect(!line.contains("\""), "line \(index + 1) holds a quote: a field cannot hold a comma")
            #expect(!line.isEmpty, "line \(index + 1) is empty")
            #expect(line.components(separatedBy: ",").count == 7,
                    "line \(index + 1) has \(line.components(separatedBy: ",").count) fields, expected 7 (no comma inside a field): \(line)")
        }
    }

    @Test func cellIdsAndPathsAreUniqueAndFieldsHoldTheAllowedValues() {
        guard let cells = gmCells() else { return }
        #expect(Set(cells.map(\.id)).count == cells.count, "a cell id is used twice")
        #expect(Set(cells.map(\.path)).count == cells.count, "a path is used twice")
        for c in cells {
            #expect(!c.id.isEmpty && !c.path.isEmpty, "cell `\(c.id)` has an empty id or path")
            #expect(!c.path.hasPrefix("/") && !c.path.hasPrefix("matrix/") && !c.path.contains(".."),
                    "\(c.id): path must be relative to matrix/, got `\(c.path)`")
            #expect(c.components.count >= 2, "\(c.id): a cell sits inside a top folder, got `\(c.path)`")
            #expect(c.group == "spec" || c.group == "extra", "\(c.id): group is `\(c.group)`")
            #expect(c.inIndex == "yes" || c.inIndex == "no", "\(c.id): expected_in_index is `\(c.inIndex)`")
            #expect(gmReasons.contains(c.reason), "\(c.id): expected_reason `\(c.reason)` is not in the closed list")
            if c.inIndex == "yes" {
                #expect(c.reason == "ok" || c.reason == "could-not-read",
                        "\(c.id): a yes cell holds ok or could-not-read, got `\(c.reason)`")
            } else {
                #expect(c.reason != "ok" && c.reason != "could-not-read",
                        "\(c.id): a no cell holds a reason other than ok and could-not-read, got `\(c.reason)`")
            }
            let rowsOK: Bool
            switch (c.inIndex, c.reason) {
            case ("yes", "ok"): rowsOK = c.rows == "1"
            case ("yes", "could-not-read"): rowsOK = c.rows == "0"
            default: rowsOK = c.rows == "0"
            }
            #expect(rowsOK, "\(c.id): expected_rows is `\(c.rows)` for \(c.inIndex)/\(c.reason)")
            #expect(c.effectiveRoots != nil,
                    "\(c.id): picks `\(c.picks)` is not blank, `-` or `folder|folder|...`")
            #expect(!c.picks.contains(":"), "\(c.id): picks `\(c.picks)` holds a tick suffix, a pick is the folder path alone")
        }
        let couldNotRead = cells.filter { $0.reason == "could-not-read" }.map(\.id)
        #expect(couldNotRead == ["damaged-png"], "could-not-read cells are \(couldNotRead), expected only damaged-png: a damaged .swift is unsupported, not unreadable")
    }

    @Test func picksAreConsistentAndOnlyTheNeverPickedCellIsInNoPick() {
        guard let cells = gmCells() else { return }
        let dashed = cells.filter(\.isNeverPicked).map(\.id)
        #expect(dashed == ["never-picked-png", "never-picked-code"], "picks `-` is on \(dashed), expected only never-picked-png and never-picked-code")
        let neverReason = cells.filter { $0.reason == "never-picked" }.map(\.id)
        #expect(neverReason == ["never-picked-png"], "expected_reason never-picked is on \(neverReason), expected only never-picked-png: the code file there is unsupported")
        if let nv = cells.first(where: { $0.id == "never-picked-png" }) {
            let sharing = cells.filter { $0.id != nv.id && $0.id != "never-picked-code" && $0.top == nv.top }.map(\.id)
            #expect(sharing.isEmpty, "the top folder of never-picked-png (\(nv.top)) is also the top folder of \(sharing)")
            // no other row can pick it: no pick root of any other cell is the folder or above it
            for c in cells where c.id != nv.id {
                for folder in c.effectiveRoots ?? [] {
                    #expect(!(nv.path == folder || nv.path.hasPrefix(folder + "/")),
                            "\(c.id) picks `\(folder)`, which holds never-picked-png")
                }
            }
        }
        // every cell that is picked is reachable from one of its pick roots
        for c in cells where !c.isNeverPicked {
            let roots = c.effectiveRoots ?? []
            #expect(roots.contains { c.path.hasPrefix($0 + "/") },
                    "\(c.id): no pick root of `\(c.picks)` holds the path `\(c.path)`")
            #expect(Set(roots).count == roots.count, "\(c.id): a folder is listed twice in `\(c.picks)`")
        }
    }

    @Test func everyFileNameCarriesItsOwnToken() {
        guard let cells = gmCells() else { return }
        var seen: [String: String] = [:]
        for c in cells {
            let inName = gmTokens(in: c.fileName)
            let inPath = gmTokens(in: c.path)
            #expect(inName.count == 1, "\(c.id): the file name `\(c.fileName)` must carry exactly one token zq<4 digits>")
            #expect(inPath.count == 1, "\(c.id): the token must be only in the file name, path `\(c.path)`")
            if let token = inName.first {
                if let other = seen[token] {
                    #expect(Bool(false), "\(c.id): token \(token) is also in \(other)")
                }
                seen[token] = c.id
            }
        }
    }

    @Test func everyRequiredCellIsPresentWithItsHandValue() {
        guard let cells = gmCells() else { return }
        let byID = Dictionary(cells.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for w in gmRequired {
            guard let c = byID[w.id] else {
                #expect(Bool(false), "required cell `\(w.id)` is missing")
                continue
            }
            #expect(c.inIndex == w.inIndex, "\(w.id): expected_in_index is `\(c.inIndex)`, hand value `\(w.inIndex)`")
            #expect(c.rows == w.rows, "\(w.id): expected_rows is `\(c.rows)`, hand value `\(w.rows)`")
            #expect(c.reason == w.reason, "\(w.id): expected_reason is `\(c.reason)`, hand value `\(w.reason)`")
            #expect(c.group == w.group, "\(w.id): group is `\(c.group)`, hand value `\(w.group)`")
            if let ext = w.ext {
                #expect(c.ext == ext, "\(w.id): the file's extension is `\(c.ext)`, the cell is about `\(ext)`: \(c.path)")
            }
            if let dir = w.dir {
                #expect(c.folderComponents.contains(dir), "\(w.id): the path must pass through a folder `\(dir)`: \(c.path)")
            }
            if let suffix = w.dirSuffix {
                #expect(c.folderComponents.contains { $0.hasSuffix(suffix) },
                        "\(w.id): the path must pass through a folder ending `\(suffix)`: \(c.path)")
            }
            if let name = w.name {
                #expect(c.fileName == name, "\(w.id): the file name is `\(c.fileName)`, verify.md names `\(name)`")
            }
            if let prefix = w.namePrefix {
                #expect(c.fileName.hasPrefix(prefix), "\(w.id): the file name must start `\(prefix)`: \(c.fileName)")
            }
            if let roots = w.roots {
                #expect((c.effectiveRoots ?? []).sorted() == roots.sorted(),
                        "\(w.id): pick roots are \(c.effectiveRoots ?? []), hand value \(roots)")
            }
        }
        #expect(Set(gmRequired.map(\.id)).count == gmRequired.count, "the test's own required list repeats a cell")
    }

    @Test func onlyTheThreeExtrasAreInTheExtraGroup() {
        guard let cells = gmCells() else { return }
        let extra = Set(cells.filter { $0.group == "extra" }.map(\.id))
        #expect(extra == gmExtras, "group extra holds \(extra.sorted()), expected \(gmExtras.sorted())")
    }

    @Test func theTableHoldsOneHundredTwentySevenCellsOfWhichFortyNineAreReadAndEveryCodeFileIsUnsupported() {
        guard let cells = gmCells() else { return }
        #expect(cells.count == 127, "the table holds \(cells.count) cells, hand count 127")
        #expect(cells.filter { $0.inIndex == "yes" }.count == 49, "yes cells: \(cells.filter { $0.inIndex == "yes" }.count), hand count 49")
        let codeFiles = Set(cells.filter { gmCodeExtensions.contains($0.ext) }.map(\.id))
        #expect(codeFiles == gmCodeCells, "cells with a code extension: extra \(codeFiles.subtracting(gmCodeCells).sorted()), missing \(gmCodeCells.subtracting(codeFiles).sorted())")
        #expect(gmCodeCells.count == 37, "the hand list of code cells holds \(gmCodeCells.count), expected 37")
        for c in cells where gmCodeCells.contains(c.id) {
            #expect(c.inIndex == "no" && c.rows == "0" && c.reason == "unsupported", "\(c.id): a code file reads no, 0, unsupported, got \(c.inIndex), \(c.rows), \(c.reason)")
        }
        #expect(!cells.contains { $0.reason == "code-not-ticked" || $0.reason == "repo-not-ticked" }, "a cell still names a tick as its reason")
        #expect(!cells.contains { $0.picks.contains(":") }, "a picks field still holds a `:on` or `:off` suffix")
    }

    @Test func theTickedRepoIsGoneAndAnUntickedRepoReadsEveryKind() {
        guard let cells = gmCells() else { return }
        #expect(!cells.contains { $0.id.hasPrefix("repo-on-") || $0.top == "repo-on" }, "a repo-on cell is still in the table: without ticks it equals repo-off")
        let off = cells.filter { $0.top == "repo-off" }.map(\.id).sorted()
        #expect(off == ["repo-off-pdf", "repo-off-png", "repo-off-py", "repo-off-txt"], "repo-off holds \(off)")
        let byID = Dictionary(cells.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ["repo-off-png", "repo-off-txt", "repo-off-pdf"] {
            #expect(byID[id]?.inIndex == "yes" && byID[id]?.rows == "1" && byID[id]?.reason == "ok", "\(id): a repo reads every kind, expected yes, 1, ok")
        }
        let ignored = cells.filter { $0.reason == "git-ignored" }.map(\.id).sorted()
        #expect(ignored == ["ignored-off-png", "ignored-off-txt", "ignored-on-txt"], "git-ignored cells are \(ignored)")
        let vendored = cells.filter { $0.reason == "vendored" && $0.ext == "txt" }.map(\.id).sorted()
        #expect(vendored == ["vend-in-Pods-txt", "vend-in-node_modules-txt"], "vendored txt cells are \(vendored)")
    }

    @Test func everyOverlapPairHasOneInnerAndOneOuterPhotoAndPicksBothFolders() {
        guard let cells = gmCells() else { return }
        for pair in ["ov-a", "ov-b", "ov-c", "ov-d"] {
            for place in ["inner", "outer"] {
                let photos = cells.filter { $0.id == "\(pair)-\(place)-photo" }
                #expect(photos.count == 1, "\(pair): \(photos.count) \(place) photo cells, expected one")
                #expect(photos.first?.inIndex == "yes" && photos.first?.rows == "1" && photos.first?.reason == "ok", "\(pair)-\(place)-photo: yes, 1, ok")
                #expect(photos.first?.picks == "\(pair)/outer|\(pair)/outer/inner", "\(pair)-\(place)-photo: picks are \(photos.first?.picks ?? "none")")
            }
        }
    }

    @Test func theOverlapPairsLieInsideEachOther() {
        guard let cells = gmCells() else { return }
        for pair in ["ov-a", "ov-b", "ov-c", "ov-d"] {
            let members = cells.filter { $0.id.hasPrefix(pair + "-") }
            #expect(!members.isEmpty, "no cell of the pair \(pair)")
            for c in members {
                #expect(c.top == pair, "\(c.id): top folder is `\(c.top)`, expected `\(pair)`")
                let roots = (c.effectiveRoots ?? []).sorted()
                #expect(roots == ["\(pair)/outer", "\(pair)/outer/inner"],
                        "\(c.id): the pair's two pick roots are \(roots)")
                if c.id.contains("-inner-") {
                    #expect(c.path.hasPrefix("\(pair)/outer/inner/"), "\(c.id): an inner cell lies in outer/inner: \(c.path)")
                } else {
                    #expect(c.path.hasPrefix("\(pair)/outer/") && !c.path.hasPrefix("\(pair)/outer/inner/"),
                            "\(c.id): an outer cell lies in outer, not in inner: \(c.path)")
                }
            }
        }
    }

    /// The folder picker selects a lone subfolder and adds it instead of the root (`folders_hold` in recipes.sh), so a
    /// pick root whose only visible entry is one subfolder would be picked as that subfolder and its cell would go red
    /// on a correct product. The visible entries are counted by hand from the `path` column; a hidden name is not visible.
    @Test func noPickRootHoldsOnlyOneVisibleSubfolder() {
        guard let cells = gmCells() else { return }
        let roots = gmRoots(cells).sorted()
        #expect(!roots.isEmpty, "no pick root in the table")
        for root in roots {
            let rootParts = root.split(separator: "/").map(String.init)
            var entries: [String: Bool] = [:]  // name -> is a folder
            for c in cells {
                let parts = c.components
                guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { continue }
                let name = parts[rootParts.count]
                entries[name] = (entries[name] ?? false) || parts.count > rootParts.count + 1
            }
            let visible = entries.filter { !$0.key.hasPrefix(".") }
            #expect(!(visible.count == 1 && visible.values.first == true),
                    "pick root `\(root)` holds one visible subfolder (\(visible.keys.first ?? "")) and nothing else visible: add a `<cell>-top` photo directly in it")
        }
        // the `-top` rows are plain photos
        for c in cells where c.id.hasSuffix("-top") {
            #expect(c.inIndex == "yes" && c.rows == "1" && c.reason == "ok" && c.group == "spec" && c.folderComponents.count == 1,
                    "\(c.id): a -top row is a plain photo directly in its pick root (yes, 1, ok, spec)")
            #expect(cells.contains { $0.id == String(c.id.dropLast(4)) }, "\(c.id): there is no cell `\(c.id.dropLast(4))`")
        }
    }

    // MARK: the extension list

    @Test func extensionsFileEqualsTheSpecsSixLists() throws {
        let text = try String(contentsOf: gmExtensions, encoding: .utf8)
        let got: [(kind: String, extensions: [String])] = text.components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                let halves = line.components(separatedBy: ":")
                let kind = halves[0]
                let list = halves.count > 1 ? halves[1].split(separator: " ").map(String.init) : []
                return (kind, list)
            }
        #expect(got.map(\.kind) == gmSpecLists.map(\.kind), "kinds (in order) are \(got.map(\.kind))")
        for (a, b) in zip(got, gmSpecLists) {
            #expect(a.extensions == b.extensions, "\(b.kind): extensions.txt has \(a.extensions), the spec lists \(b.extensions)")
        }
    }

    @Test func everyPhotoExtensionHasAnExtCell() {
        guard let cells = gmCells() else { return }
        let photos = gmSpecLists.first { $0.kind == "photo" }?.extensions ?? []
        #expect(!photos.isEmpty)
        for e in photos {
            let cell = cells.first { $0.id == "ext-\(e)" }
            #expect(cell != nil, "photo extension `\(e)` has no `ext-\(e)` cell")
            #expect(cell?.ext == e, "ext-\(e): the file's extension is `\(cell?.ext ?? "")`")
            #expect(cell?.inIndex == "yes" && cell?.rows == "1" && cell?.reason == "ok", "ext-\(e): a photo extension is yes, 1, ok")
        }
    }

    // Added in plan-4-t2 beside everyPhotoExtensionHasAnExtCell (which is unchanged): the document and pdf extensions have
    // their own cells `extdoc-<ext>` under extdoc/, because ExtensionsTests pins the eight `ext-` photo cells and matrix/ext.
    @Test func everyDocumentAndPdfExtensionHasAnExtdocCell() {
        guard let cells = gmCells() else { return }
        let wanted = (gmSpecLists.first { $0.kind == "document" }?.extensions ?? []) + (gmSpecLists.first { $0.kind == "pdf" }?.extensions ?? [])
        #expect(wanted.count == 7, "the hand list holds \(wanted.count) document and pdf extensions, expected 7")
        for e in wanted {
            let cell = cells.first { $0.id == "extdoc-\(e)" }
            #expect(cell != nil, "extension `\(e)` has no `extdoc-\(e)` cell")
            #expect(cell?.ext == e, "extdoc-\(e): the file's extension is `\(cell?.ext ?? "")`")
            #expect(cell?.path.hasPrefix("extdoc/") == true, "extdoc-\(e): the path is under extdoc/: \(cell?.path ?? "")")
            #expect(cell?.inIndex == "yes" && cell?.rows == "1" && cell?.reason == "ok" && cell?.group == "spec", "extdoc-\(e): yes, 1, ok, spec")
        }
        #expect(!cells.contains { $0.id.hasPrefix("extdoc-") && $0.path.hasPrefix("ext/") }, "an extdoc cell is under ext/")
        #expect(cells.filter { $0.path.hasPrefix("ext/") }.map(\.id).sorted() == photoCellIds.sorted(), "matrix/ext holds more than the eight ext- photo cells")
    }

    // Added in plan-5-t1 beside everyDocumentAndPdfExtensionHasAnExtdocCell (unchanged): every audio and video extension has an
    // `extav-<ext>` cell under extav/ (a real 1 s clip, a unique zq token in the name, yes, 1, ok, spec).
    @Test func everyAudioAndVideoExtensionHasAnExtavCell() {
        guard let cells = gmCells() else { return }
        let wanted = (gmSpecLists.first { $0.kind == "audio" }?.extensions ?? []) + (gmSpecLists.first { $0.kind == "video" }?.extensions ?? [])
        #expect(wanted.count == 8, "the hand list holds \(wanted.count) audio and video extensions, expected 8")
        for e in wanted {
            let cell = cells.first { $0.id == "extav-\(e)" }
            #expect(cell != nil, "extension `\(e)` has no `extav-\(e)` cell")
            #expect(cell?.ext == e, "extav-\(e): the file's extension is `\(cell?.ext ?? "")`")
            #expect(cell?.path.hasPrefix("extav/") == true, "extav-\(e): the path is under extav/: \(cell?.path ?? "")")
            #expect(cell?.inIndex == "yes" && cell?.rows == "1" && cell?.reason == "ok" && cell?.group == "spec", "extav-\(e): yes, 1, ok, spec")
        }
        #expect(!cells.contains { $0.id.hasPrefix("extav-") && ($0.path.hasPrefix("ext/") || $0.path.hasPrefix("extdoc/")) }, "an extav cell is under ext/ or extdoc/")
    }

    // plan-6-t9 (added by the tester, a new pin and nothing else changed; reason: the golden repo cells cannot take the one-file-per-cell shape this suite
    // requires (a repo cell holds many files and retry-notes.md), so the two cells live in repo-cells.tsv and this table and tree.tsv hold none of them).
    @Test("gate-matrix.csv and tree.tsv hold no golden-repo-* row, and every row of repo-cells.tsv names a folder that `build repos` makes under home/Developer")
    func goldenRepoCellsAreApart() throws {
        let lib = gmProjectRoot.appendingPathComponent("scripts/kit-lib")
        let csv = (try? String(contentsOf: gmCSV, encoding: .utf8)) ?? ""
        let tree = (try? String(contentsOf: lib.appendingPathComponent("tree.tsv"), encoding: .utf8)) ?? ""
        #expect(!csv.isEmpty && !tree.isEmpty, "gate-matrix.csv or tree.tsv could not be read")
        #expect(!csv.contains("golden-repo-"), "gate-matrix.csv holds a golden-repo-* row")
        #expect(!tree.contains("golden-repo-"), "tree.tsv holds a golden-repo-* row")
        let cells = ((try? String(contentsOf: lib.appendingPathComponent("repo-cells.tsv"), encoding: .utf8)) ?? "").split(separator: "\n")
            .filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(cells.count == 2, "repo-cells.tsv holds \(cells.count) cells, expected the two golden repos")
        let repos = ((try? String(contentsOf: lib.appendingPathComponent("repos.tsv"), encoding: .utf8)) ?? "").split(separator: "\n")
            .filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let made = Set(repos.compactMap { $0.count > 1 ? $0[1] : nil })
        for c in cells {
            #expect(c.count == 4, "a repo cell has \(c.count) columns, expected 4 (cell, folder, in the index, not in the index): \(c.first ?? "")")
            #expect(c.first?.hasPrefix("golden-repo-") == true, "a repo cell is not named golden-repo-*: \(c.first ?? "")")
            #expect(c.count > 1 && made.contains(c[1]), "\(c.first ?? ""): the folder \(c.count > 1 ? c[1] : "") is not a repo `build repos` makes (repos.tsv names \(made.sorted()))")
        }
        let byCell = Dictionary(cells.compactMap { $0.count == 4 ? ($0[0], $0) : nil }, uniquingKeysWith: { first, _ in first })
        let api = byCell["golden-repo-api-client"]
        #expect(api?[2].split(separator: ",").map(String.init) == ["docs/retry-notes.md", "docs/retry-diagram.png"], "api-client in the index: \(api?[2] ?? "none")")
        let apiOut = Set((api?[3] ?? "").split(separator: ",").map(String.init))
        let codeFiles = ["retry.swift", "auth.swift", "pagination.swift", "cache.swift", "ratelimit.swift", "url.swift", "upload.swift", "errors.swift",
                         "signing.swift", "json.swift", "client.swift", "session.swift"]
        let excluded = ["scratch-output.swift", "node_modules/leftpad/index.js", "Pods/Alamofire/Source.swift", "build/output.js", "dist/bundle.js",
                        ".build/debug/module.swift", "vendor/github/lib.go", "certs/server.pem", "certs/signing.key", "certs/bundle.p12",
                        "certs/client.pfx", "id_rsa.txt", ".env.local.md", "vault.kdbx"]
        #expect(apiOut == Set(codeFiles + excluded), "api-client not in the index: extra \(apiOut.subtracting(codeFiles + excluded).sorted()), missing \(Set(codeFiles + excluded).subtracting(apiOut).sorted())")
        let legacy = byCell["golden-repo-legacy-sync"]
        #expect(legacy?[2] == "docs/diagram.png" && legacy?[3] == "merge.swift", "legacy-sync: in \(legacy?[2] ?? "none"), out \(legacy?[3] ?? "none")")
    }

    private var photoCellIds: [String] { (gmSpecLists.first { $0.kind == "photo" }?.extensions ?? []).map { "ext-\($0)" } }
}
