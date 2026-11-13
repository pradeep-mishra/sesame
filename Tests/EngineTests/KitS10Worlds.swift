import Foundation

let s10Sections = ["Folders", "File types", "Search", "Indexing"]
let s10LongFolder = "zqlongfolder" + String(repeating: "d", count: 108)
let s10LongFile = "zqlongfile" + String(repeating: "f", count: 110)
let s10ReadNote = "Photos, PDFs, documents, audio and video are read."
let s10ShortcutHeading = "Open Sesame from anywhere"
let s10ShortcutLead = "Press these keys together."
let s10ShortcutKeys = "Control Option Space"
let s10ShortcutNote = "You can change the shortcut later in Settings."
let s10HintStart = "Indexing starts when you press Start indexing, and runs in the background."
let s10HintTick = "Tick at least one folder to start."
let s10Running = "Indexing is running. Watch it from the magnifier in the menu bar."

enum S10Folders {
    case whole
    case noTick
    case notWhole
    case started
}

func s10Slug(_ text: String) -> String { String(text.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }) }

struct S10Dump {
    let old: Bool
    let ox: Int
    let oy: Int
    var lines: [String] = []

    init(_ title: String, _ w: Int, _ h: Int, old: Bool, window: Bool = true) {
        self.old = old
        ox = window ? 100 : 0
        oy = window ? 50 : 0
        if window {
            lines.append("window \(w) x \(h) at 100, 50 title \(title)")
            lines.append("AXWindow label=\"\(title)\"" + (old ? "" : " frame=100,50,\(w),\(h)"))
        } else {
            lines.append("AXMenu" + (old ? "" : " frame=\(w),\(h),260,300"))
        }
    }

    mutating func add(_ depth: Int, _ role: String, _ label: String? = nil, _ x: Int = 0, _ y: Int = 0, _ w: Int = 0, _ h: Int = 0, _ attrs: String = "", flags: String = "") {
        var line = String(repeating: "  ", count: depth) + role
        if let label { line += " label=\"\(label)\"" }
        if !attrs.isEmpty { line += " " + attrs }
        if !flags.isEmpty { line += " " + flags }
        if !old { line += " frame=\(x + ox),\(y + oy),\(w),\(h)" }
        lines.append(line)
    }

    var text: String { lines.joined(separator: "\n") + "\n" }
}

func s10Moved(_ text: String, _ label: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, window: Bool = true, nth: Int = 0) -> String {
    var seen = 0
    return text.components(separatedBy: "\n").map { line in
        guard line.contains("label=\"\(label)\"") else { return line }
        defer { seen += 1 }
        guard seen == nth, let r = line.range(of: " frame=") else { return line }
        return String(line[..<r.lowerBound]) + " frame=\(x + (window ? 100 : 0)),\(y + (window ? 50 : 0)),\(w),\(h)"
    }.joined(separator: "\n")
}

func s10Without(_ text: String, containing needle: String) -> String {
    text.components(separatedBy: "\n").filter { !$0.contains(needle) }.joined(separator: "\n")
}

func s10Append(_ text: String, _ line: String) -> String {
    text.hasSuffix("\n") ? text + line + "\n" : text + "\n" + line + "\n"
}

func s10SetupDump(_ n: Int, old: Bool, long: Bool, root: String, folders state: S10Folders = .whole, started: Bool = false) -> String {
    let names = ["Welcome", "Folders", "Permissions", "Shortcut"]
    let titles = ["Welcome to Sesame", "Folders to read", "Permissions", old ? "Open Sesame with" : "Open Sesame from anywhere"]
    let name = names[n - 1]
    var d = S10Dump("Set up Sesame", 560, 628, old: old)
    if old {
        d.add(1, "AXStaticText", "Step \(n) of 4: \(name)")
    } else {
        d.add(1, "AXGroup", "Step \(n) of 4: \(name)", 252, 564, 56, 8)
    }
    if n > 1 { d.add(1, "AXStaticText", titles[n - 1], 130, 24, 300, 30) }
    switch n {
    case 1:
        if old {
            d.add(1, "AXScrollArea")
            d.add(2, "AXTextArea", "Welcome to Sesame", 0, 0, 0, 0, "value=\"Welcome to SesameSesame finds files by what is inside them. Everything stays on this Mac.Nothing is read until you press Start indexing.\"")
            d.add(2, "AXScrollBar", nil, 0, 0, 0, 0, "value=\"0.0\"", flags: "[disabled]")
            d.add(1, "AXStaticText", "The search model")
            d.add(1, "AXGroup", "Model download", 0, 0, 0, 0, "value=\"9 of 865 MB\"")
            d.add(1, "AXButton", "Back", flags: "[disabled]")
            d.add(1, "AXButton", "Next")
        } else {
            d.add(1, "AXStaticText", "Welcome to Sesame", 130, 150, 300, 30)
            d.add(1, "AXStaticText", "Search your files by what is inside them.", 100, 190, 360, 18)
            let promises = [("Search by meaning", "Type what a photo shows or what a document says."), ("Private by design", "Everything stays on this Mac."), ("You choose when", "Nothing is read until you press Start indexing.")]
            for (i, p) in promises.enumerated() {
                d.add(1, "AXStaticText", p.0, 132, 240 + 44 * i, 300, 16)
                d.add(1, "AXStaticText", p.1, 132, 258 + 44 * i, 328, 14)
            }
            d.add(1, "AXStaticText", "Search model ready", 180, 522, 200, 18)
            d.add(1, "AXButton", "Next", 440, 556, 100, 24)
        }
    case 2:
        let folders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies"]
        if old {
            d.add(1, "AXStaticText", "10 files in the ticked folders.")
            d.add(1, "AXStaticText", "About 5 min in total")
            d.add(1, "AXStaticText", "Photos: about 2 s each")
            d.add(1, "AXGroup", nil, 20, 110, 520, 330)
            d.add(2, "AXScrollArea", nil, 20, 110, 520, 330)
            for (i, f) in folders.enumerated() {
                d.add(3, "AXCheckBox", f, 36, 116 + 30 * i, 300, 20, "desc=\"\(f), 2 photos, about 1 min\" help=\"\(root)/home/\(f)\" value=\"1\"")
            }
            d.add(1, "AXButton", "Add folder…", 20, 446, 110, 24)
            d.add(1, "AXButton", "Start indexing", 430, 446, 110, 24, flags: "[disabled]")
            d.add(1, "AXButton", "Back", 20, 556, 80, 24)
            d.add(1, "AXButton", "Next", 440, 556, 100, 24, flags: "[focused]")
        } else {
            let rows = folders.count + (long ? 1 : 0)
            let ticked = state != .noTick
            let tick = ticked ? 1 : 0
            let card = rows * 16 + (rows - 1) * 16 + 32
            let foot = 110 + card + 12
            let startMode = state == .whole || state == .noTick
            d.add(1, "AXStaticText", ticked ? "\(rows * 2) files in \(rows) folders" : "Nothing will be indexed.", 130, 60, 300, 18)
            if ticked { d.add(1, "AXStaticText", "About 5 min in total", 130, 86, 300, 16) }
            d.add(1, "AXGroup", nil, 20, 110, 520, card)
            d.add(2, "AXScrollArea", nil, 20, 110, 520, card)
            for (i, f) in folders.enumerated() {
                d.add(3, "AXCheckBox", f, 36, 126 + 32 * i, 300, 16, "desc=\"\(f), 2 photos, about 1 min\" help=\"\(root)/home/\(f)\" value=\"\(tick)\"")
            }
            if long {
                d.add(3, "AXCheckBox", s10LongFolder, 36, 126 + 32 * folders.count, 380, 16, "desc=\"\(s10LongFolder), 2 photos, about 1 min\" help=\"\(root)/fixtures/long-names/\(s10LongFolder)\" value=\"\(tick)\"")
            }
            d.add(1, "AXButton", "Add folder…", 20, foot, 110, 20)
            if startMode {
                d.add(1, "AXStaticText", ticked ? s10HintStart : s10HintTick, 80, foot + 32, 400, 14)
                d.add(1, "AXStaticText", s10ReadNote, 80, foot + 58, 400, 14)
                d.add(1, "AXButton", "Not now", 235, foot + 84, 90, 20)
            } else {
                d.add(1, "AXStaticText", s10ReadNote, 80, foot + 32, 400, 14)
            }
            if state == .notWhole {
                d.add(1, "AXStaticText", "The search model", 20, 470, 200, 16)
                d.add(1, "AXGroup", "Model download", 20, 490, 520, 46, "value=\"9 of 865 MB\"")
            }
            d.add(1, "AXButton", "Back", 20, 556, 80, 24)
            if startMode {
                d.add(1, "AXButton", "Start indexing", 420, 556, 120, 24, flags: ticked ? "" : "[disabled]")
            } else {
                d.add(1, "AXButton", "Next", 440, 556, 100, 24)
            }
        }
    case 3:
        let places = ["Desktop", "Documents", "Downloads", "Removable volumes"]
        if old {
            d.add(1, "AXStaticText", "macOS asks once, the first time Sesame reads each of these:")
            for (i, f) in places.enumerated() { d.add(1, "AXStaticText", "• \(f): files there", 36, 130 + 40 * i, 400, 16) }
            d.add(1, "AXStaticText", "Sesame never asks for Full Disk Access, camera or microphone.", 20, 330, 500, 14)
        } else {
            d.add(1, "AXStaticText", "macOS asks once, the first time Sesame reads each of these:", 94, 62, 373, 18)
            d.add(1, "AXGroup", nil, 20, 88, 520, 212)
            for (i, f) in places.enumerated() {
                d.add(2, "AXStaticText", f, 36, 104 + 49 * i, 200, 16)
                d.add(2, "AXStaticText", ["Files on your Desktop", "Files in your Documents folder", "Files in your Downloads folder", "USB drives and external disks"][i], 36, 122 + 49 * i, 300, 15)
            }
            d.add(1, "AXStaticText", "Sesame never asks for Full Disk Access, camera or microphone.", 99, 312, 362, 15)
        }
        d.add(1, "AXButton", "Back", 20, 556, 80, 24)
        d.add(1, "AXButton", "Next", 440, 556, 100, 24)
    default:
        if old {
            d.add(1, "AXStaticText", "Control Option Space")
            d.add(1, "AXStaticText", s10ShortcutNote)
            d.add(1, "AXStaticText", "The search model")
            d.add(1, "AXGroup", "Model download", 0, 0, 0, 0, "value=\"43 of 865 MB\"")
        } else {
            d.add(1, "AXStaticText", s10ShortcutLead, 195, 62, 170, 18)
            d.add(1, "AXGroup", s10ShortcutKeys, 176, started ? 260 : 270, 208, 62)
            d.add(1, "AXStaticText", s10ShortcutNote, 135, started ? 502 : 521, 290, 15)
            if started { d.add(1, "AXStaticText", s10Running, 80, 525, 400, 15) }
        }
        d.add(1, "AXButton", "Back", 20, 556, 80, 24)
        d.add(1, "AXButton", "Finish", 440, 556, 100, 24)
    }
    return d.text
}

let s10OldSidebar = s10Sections + ["About"]
let s10FoldersTitle = "Folders Sesame reads"
let s10FoldersNote = "Tick a folder to read it. Use the more button on a row to re-index or remove it."
let s10FileTypesTitle = "File types Sesame reads"
let s10Kinds = ["Photos", "PDFs", "Documents", "Audio", "Video"]
let s10LoginCaption = "The shortcut works only while Sesame is running."
let s10UnreadableTitle = "Files Sesame could not read"
let s10UnreadableRows = ["broken.m4a, damaged", "damaged-report.pdf, damaged", "locked-contract.pdf, password-protected"]

func s10SettingsDump(_ section: String, old: Bool, long: Bool, root: String, confirm: Bool = false, moreRole: String = "AXPopUpButton") -> String {
    var d = S10Dump("Settings", 720, 548, old: old)
    if old {
        d.add(1, "AXGroup", nil, 0, 0, 180, 520)
        for (i, s) in s10OldSidebar.enumerated() { d.add(2, "AXCheckBox/AXToggle", s, 8, 8 + 30 * i, 164, 28, "value=\"\(s == section ? 1 : 0)\"") }
        d.add(1, "AXScrollArea", nil, 180, 0, 540, 520)
        return s10OldSettingsBody(&d, section, confirm: confirm, root: root)
    }
    for (i, s) in s10Sections.enumerated() { d.add(1, "AXCheckBox/AXToggle", s, 8, 46 + 30 * i, 164, 28, "value=\"\(s == section ? 1 : 0)\"") }
    d.add(1, "AXStaticText", section, 197, 13, 200, 20)
    d.add(1, "AXScrollArea", nil, 181, 47, 539, 501)
    switch section {
    case "Folders":
        var names = ["Desktop", "Documents", "api-client"]
        if long { names.append(s10LongFolder) }
        let card = 45 * names.count
        d.add(2, "AXStaticText", s10FoldersTitle, 197, 63, 300, 16)
        d.add(2, "AXGroup", nil, 197, 84, 507, card)
        for (i, f) in names.enumerated() {
            let top = 84 + 45 * i
            let isRepo = f == "api-client"
            let isLong = f == s10LongFolder
            let path = isRepo ? "\(root)/home/Developer/api-client" : (isLong ? "\(root)/fixtures/long-names/\(f)" : "\(root)/home/\(f)")
            let detail = isRepo ? "1 photo, 1 document, about 1 min" : "2 photos, about 1 min"
            d.add(3, "AXCheckBox", f, 211, top + 10, isLong ? 380 : 300, 16, "desc=\"\(f), \(detail)\" help=\"\(path)\" value=\"1\"")
            d.add(3, moreRole, "More actions for \(f)", 666, top + 11, 22, 22, "help=\"\(f)\"")
        }
        let addTop = 84 + card + 12
        d.add(2, "AXGroup", nil, 197, addTop, 507, 40)
        d.add(3, "AXButton", "Add folder…", 211, addTop + 10, 110, 20)
        d.add(2, "AXStaticText", s10FoldersNote, 201, addTop + 48, 480, 14)
    case "File types":
        d.add(2, "AXStaticText", s10FileTypesTitle, 197, 63, 300, 16)
        d.add(2, "AXGroup", nil, 197, 84, 507, 225)
        for (i, k) in s10Kinds.enumerated() { d.add(3, "AXCheckBox/AXSwitch", k, 652, 95 + 45 * i, 38, 22, "value=\"1\"") }
    case "Search":
        d.add(2, "AXStaticText", "Open Sesame with", 197, 63, 200, 16)
        d.add(2, "AXGroup", s10ShortcutKeys, 412, 96, 116, 26)
        d.add(2, "AXButton", "Record new shortcut", 540, 97, 150, 24)
        d.add(2, "AXButton", "Back to default", 201, 142, 100, 16)
        d.add(2, "AXStaticText", "Open files with", 197, 172, 200, 16)
        d.add(2, "AXPopUpButton", "PDF app", 356, 200, 200, 24, "value=\"Preview\"")
        d.add(2, "AXPopUpButton", "Media app", 356, 240, 200, 24, "value=\"QuickTime Player\"")
    default:
        let shift = confirm ? 96 : 0
        d.add(2, "AXCheckBox/AXSwitch", "Launch at login", 636, 76, 54, 24, "value=\"1\"")
        d.add(2, "AXStaticText", s10LoginCaption, 211, 90, 330, 15)
        d.add(2, "AXButton", "Start indexing", 211, 137, 120, 24)
        d.add(2, "AXButton", "Delete index…", 211, 177, 110, 24)
        if confirm {
            d.add(2, "AXButton", "Cancel", 209, 266, 80, 24)
            d.add(2, "AXButton", "Delete index", 600, 266, 90, 24)
        }
        d.add(2, "AXStaticText", s10UnreadableTitle, 197, 225 + shift, 300, 16)
        for (i, row) in s10UnreadableRows.enumerated() { d.add(2, "AXStaticText", row, 197, 249 + shift + 49 * i, 507, 48) }
    }
    return d.text
}

private func s10OldSettingsBody(_ d: inout S10Dump, _ section: String, confirm: Bool, root: String) -> String {
    switch section {
    case "Folders":
        d.add(2, "AXButton", "Add folder…", 200, 70, 110, 24)
        d.add(2, "AXGroup", nil, 200, 110, 500, 190)
        for (i, f) in ["Desktop", "Documents"].enumerated() {
            d.add(3, "AXCheckBox", f, 216, 120 + 40 * i, 300, 20, "desc=\"\(f), 2 photos, about 1 min\" help=\"\(root)/home/\(f)\" value=\"1\"")
            d.add(3, "AXButton", "Re-index", 590, 120 + 40 * i, 50, 20, "help=\"\(f)\"")
            d.add(3, "AXButton", "Remove", 640, 120 + 40 * i, 50, 20, "help=\"\(f)\"")
        }
        d.add(3, "AXCheckBox", "api-client", 216, 200, 300, 20, "desc=\"api-client, 12 code files, 340 KB, about 1 min\" help=\"\(root)/home/Developer/api-client\" value=\"1\"")
        d.add(3, "AXButton", "Re-index", 590, 200, 50, 20, "help=\"api-client\"")
        d.add(3, "AXButton", "Remove", 640, 200, 50, 20, "help=\"api-client\"")
    case "File types":
        d.add(2, "AXCheckBox", "Search my code", 216, 70, 300, 18, "value=\"0\"")
        for (i, k) in s10Kinds.enumerated() { d.add(2, "AXCheckBox", k, 216, 100 + 30 * i, 200, 18, "value=\"1\"") }
    case "Search":
        d.add(2, "AXStaticText", "Open Sesame with")
        d.add(2, "AXStaticText", "Keyboard shortcut", 0, 0, 0, 0, "value=\"Control Option Space\"")
        d.add(2, "AXButton", "Record new shortcut", 216, 80, 160, 24)
        d.add(2, "AXButton", "Back to default")
        d.add(2, "AXStaticText", "Open files with")
        d.add(2, "AXPopUpButton", "PDF app", 356, 200, 200, 24, "value=\"Preview\"")
        d.add(2, "AXPopUpButton", "Media app", 356, 240, 200, 24, "value=\"QuickTime Player\"")
        d.add(2, "AXPopUpButton", "Code editor", 356, 280, 200, 24, "value=\"Visual Studio Code\"")
    default:
        d.add(2, "AXButton", "Start indexing", 216, 70, 120, 24)
        d.add(2, "AXCheckBox", "Launch at login", 216, 120, 150, 18, "value=\"1\"")
        d.add(2, "AXStaticText", s10LoginCaption)
        d.add(2, "AXButton", "Delete index…", 216, 200, 120, 24)
        d.add(2, "AXStaticText", s10UnreadableTitle)
        for row in s10UnreadableRows { d.add(2, "AXStaticText", row) }
        if confirm {
            d.add(2, "AXButton", "Cancel", 216, 300, 80, 24)
            d.add(2, "AXButton", "Delete index", 600, 300, 90, 24)
        }
    }
    return d.text
}

let s10BaselineMenu = """
AXMenu
  AXMenuItem label="Ready" [disabled]
  AXMenuItem [disabled]
  AXMenuItem label="Pause indexing" [disabled]
  AXMenuItem [disabled]
  AXMenuItem label="Photos: 42" [disabled]
  AXMenuItem label="PDFs: 21" [disabled]
  AXMenuItem label="Documents: 7" [disabled]
  AXMenuItem label="Audio: 12" [disabled]
  AXMenuItem label="Video: 12" [disabled]
  AXMenuItem label="Code: 12" [disabled]
  AXMenuItem [disabled]
  AXMenuItem label="Last indexed: annual-report-60p.pdf" [disabled]
  AXMenuItem [disabled]
  AXMenuItem label="Open Sesame"
  AXMenuItem label="Settings…"
  AXMenuItem [disabled]
  AXMenuItem label="Quit Sesame"
note: the status item menu is still open after a posted Esc

"""

struct S10MenuState {
    let item: String
    let header: String
    let actions: [String]
}

let s10MenuStateNames = ["ready", "notstarted", "indexing", "pausedbyyou", "stalled", "busy", "lowpower", "battery", "downloading", "failed"]

let s10MenuStates: [String: S10MenuState] = [
    "ready": S10MenuState(item: "Ready", header: "Ready", actions: []),
    "notstarted": S10MenuState(item: "Indexing has not been started", header: "Ready, Indexing has not been started", actions: []),
    "indexing": S10MenuState(item: "Indexing 62%", header: "Indexing 62%, 4,520 files left \u{00B7} about 12 min left", actions: ["Pause indexing"]),
    "pausedbyyou": S10MenuState(item: "Paused by you", header: "Paused, By you", actions: ["Resume indexing"]),
    "stalled": S10MenuState(item: "Paused: indexing stopped, press Resume to try again", header: "Paused, Indexing stopped, press Resume", actions: ["Resume indexing"]),
    "busy": S10MenuState(item: "Paused: the Mac is busy", header: "Paused, The Mac is busy", actions: []),
    "lowpower": S10MenuState(item: "Paused: Low Power Mode is on", header: "Paused, Low Power Mode is on", actions: []),
    "battery": S10MenuState(item: "Paused: on battery", header: "Paused, On battery", actions: ["Resume anyway, on battery"]),
    "downloading": S10MenuState(item: "Downloading the model, 40%", header: "Downloading the model, 40%", actions: []),
    "failed": S10MenuState(item: "Model download failed", header: "Model download failed", actions: ["Retry model download"]),
]

func s10MenuDump(old: Bool, state: String = "ready") -> String {
    if old { return s10BaselineMenu }
    let s = s10MenuStates[state]!
    var d = S10Dump("Sesame", 800, 0, old: false, window: false)
    var y = 40
    func item(_ label: String?, _ flags: String = "") {
        let h = label == nil ? 8 : 22
        d.add(1, "AXMenuItem", label, 800, y, 260, h, flags: flags)
        y += h
    }
    func separator() { item(nil, "[disabled]") }
    d.add(1, "AXMenuItem", s.item, 800, 0, 260, 40, flags: "[disabled]")
    d.add(2, "AXGroup", s.header, 800, 0, 260, 40)
    if !s.actions.isEmpty {
        separator()
        for a in s.actions { item(a) }
    }
    separator()
    for c in ["Photos: 42", "PDFs: 21", "Documents: 7", "Audio: 12", "Video: 12"] { item(c, "[disabled]") }
    separator()
    item("Open Sesame")
    item("Settings…")
    separator()
    item("Quit Sesame")
    return d.text
}

func s10PanelDump(_ kind: String, old: Bool, box: String = "") -> String {
    var d = S10Dump("Sesame", 960, 560, old: old)
    d.add(1, "AXTextField", "Search", 60, 14, 860, 30, "value=\"\(box)\"", flags: "[focused]")
    switch kind {
    case "empty":
        d.add(1, "AXGroup", "Search hint", 0, 58, 960, 470)
        d.add(2, "AXStaticText", "Describe what you want, or type part of a name or text.", 320, 230, 320, 34)
        d.add(2, "AXStaticText", "a dog on the beach", 370, 280, 220, 22)
        d.add(2, "AXStaticText", "the clause about pets in the lease", 370, 310, 220, 22)
        d.add(2, "AXStaticText", old ? "code: retry a failed call with backoff" : "where they talk about sleep", 370, 340, 220, 22)
    case "results":
        d.add(1, "AXScrollArea", nil, 0, 58, 384, 470)
        d.add(2, "AXList", nil, 0, 58, 384, 470)
        d.add(3, "AXRow", nil, 0, 60, 384, 32)
        d.add(4, "AXStaticText", "beach-dog.jpg", 40, 66, 120, 16)
        d.add(4, "AXStaticText", "photos", 170, 66, 60, 16)
        d.add(1, "AXStaticText", "beach-dog", 404, 330, 300, 20)
        d.add(1, "AXStaticText", "~/fixtures/golden/photos/beach-dog.jpg", 404, 356, 500, 16)
        d.add(1, "AXStaticText", "Photo · 1.2 MB · Jan 2", 404, 378, 300, 16)
    case "nomatches":
        d.add(1, "AXStaticText", "No matches", 92, 240, 200, 24)
        d.add(1, "AXStaticText", "Describe what is in the file, or type part of its exact name or text.", 42, 276, 300, 40)
    case "long":
        d.add(1, "AXScrollArea", nil, 0, 58, 384, 470)
        d.add(2, "AXList", nil, 0, 58, 384, 470)
        d.add(3, "AXRow", nil, 0, 60, 384, 32)
        d.add(4, "AXStaticText", s10LongFile + ".jpg", 40, 66, 200, 16)
        d.add(4, "AXStaticText", "long-names", 250, 66, 100, 16)
        d.add(1, "AXStaticText", s10LongFile + ".jpg ", 404, 330, 500, 20)
        d.add(1, "AXStaticText", "~/fixtures/long-names/\(s10LongFolder)/\(s10LongFile).jpg", 404, 356, 500, 16)
        d.add(1, "AXStaticText", "Photo · 1.2 MB · Jan 2", 404, 378, 300, 16)
    default:
        break
    }
    if !old { d.add(1, "AXStaticText", "↩ Open  ⌘↩ Reveal  ⌘C Copy  esc Close", 20, 536, 260, 14) }
    return d.text
}

func s10World(old: Bool, long: Bool, root: String) -> [String: String] {
    var files: [String: String] = [:]
    for n in 1...4 { files["setup-\(n).txt"] = s10SetupDump(n, old: old, long: long, root: root) }
    for s in s10Sections { files["settings-\(s10Slug(s)).txt"] = s10SettingsDump(s, old: old, long: long, root: root) }
    files["settings-Indexing-confirm.txt"] = s10SettingsDump("Indexing", old: old, long: long, root: root, confirm: true)
    files["menu.txt"] = s10MenuDump(old: old)
    files["panel-empty.txt"] = s10PanelDump("empty", old: old)
    files["panel-a_dog_on_the_beach.txt"] = s10PanelDump("results", old: old, box: "a dog on the beach")
    files["panel-qwv_zzkx_lorp_mnb.txt"] = s10PanelDump("nomatches", old: old, box: "qwv zzkx lorp mnb")
    files["panel-zqlongfile.txt"] = s10PanelDump("long", old: old, box: "zqlongfile")
    return files
}

let s10BaselineNames: [(new: String, old: String)] =
    (1...4).map { ("setup-\($0).txt", "dump-setup-\($0).txt") }
    + s10Sections.map { ("settings-\(s10Slug($0)).txt", "dump-settings-\(s10Slug($0).lowercased().replacingOccurrences(of: "_", with: "-")).txt") }
    + [("panel-empty.txt", "dump-panel-empty.txt"), ("panel-qwv_zzkx_lorp_mnb.txt", "dump-panel-nomatches.txt"), ("menu.txt", "dump-menu.txt")]
