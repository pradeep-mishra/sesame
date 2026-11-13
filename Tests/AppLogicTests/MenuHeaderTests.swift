import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

let mhWalk = Date(timeIntervalSince1970: 1_700_000_000)
let mhAllOn: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]
let mhDone: [String: Int] = ["photo": 9690, "pdf": 1083, "doc": 1068]
let mhSep = "---"
let mhPause = "Pause indexing"
let mhResume = "Resume indexing"
let mhAnyway = "Resume anyway, on battery"
let mhRetry = "Retry model download"
let mhOpen = "Open Sesame"
let mhSettings = "Settings\u{2026}"
let mhQuit = "Quit Sesame"
let mhCountLines = ["Photos: 9,690", "PDFs: 1,083", "Documents: 1,068", "Audio: 0", "Video: 0"]
let mhStalledDetail = "Indexing stopped, press Resume"
let mhStalledLine = "Paused: indexing stopped, press Resume to try again"

func mhCounts(done: Int = 0, pending: [String: Int] = [:], needs: Int = 0) -> IndexCounts {
    IndexCounts(done: done, pending: pending, partial: [:], needsPermission: needs)
}

func mhModel(model: ModelState = .whole, startPressed: Bool = true, walkDone: Bool = true, counts: IndexCounts,
             reasons: Set<PauseReason> = [], percent: Int = 0, done: [String: Int] = [:],
             kindsOn: [String: Bool] = mhAllOn) -> MenuModel {
    let inputs = MenuInputs(model: model, startPressed: startPressed, indexDeleted: false, walkDoneAt: walkDone ? mhWalk : nil,
                            counts: counts, pauseReasons: reasons)
    return MenuModel(inputs: inputs, downloadPercent: percent, doneByKind: done,
                     speeds: ["photo": 0.16], kindsOn: kindsOn)
}

let mhPending = mhCounts(done: 7400, pending: ["photo": 4520])

struct MHCase {
    let name: String
    let model: MenuModel
    let statusLine: String
    let title: String
    let detail: String?
    let dot: String
    let label: String
}

let mhCases: [MHCase] = [
    MHCase(name: "Ready before Start", model: mhModel(startPressed: false, walkDone: false, counts: mhCounts()),
           statusLine: "Indexing has not been started", title: "Ready", detail: "Indexing has not been started", dot: "ready",
           label: "Ready, Indexing has not been started"),
    MHCase(name: "Ready after Start", model: mhModel(counts: mhCounts(done: 11841), done: mhDone),
           statusLine: "Ready", title: "Ready", detail: nil, dot: "ready", label: "Ready"),
    MHCase(name: "Indexing 62%", model: mhModel(counts: mhPending, done: mhDone),
           statusLine: "Indexing 62%", title: "Indexing 62%", detail: "4,520 files left \u{00B7} about 12 min left", dot: "active",
           label: "Indexing 62%, 4,520 files left \u{00B7} about 12 min left"),
    MHCase(name: "Indexing with no named file left", model: mhModel(walkDone: false, counts: mhCounts()),
           statusLine: "Indexing 0%", title: "Indexing 0%", detail: nil, dot: "active", label: "Indexing 0%"),
    MHCase(name: "Paused by you", model: mhModel(counts: mhPending, reasons: [.you], done: mhDone),
           statusLine: "Paused by you", title: "Paused", detail: "By you", dot: "neutral", label: "Paused, By you"),
    MHCase(name: "Paused, stalled", model: mhModel(counts: mhPending, reasons: [.stalled], done: mhDone),
           statusLine: mhStalledLine, title: "Paused", detail: mhStalledDetail, dot: "neutral",
           label: "Paused, Indexing stopped, press Resume"),
    MHCase(name: "Paused, the Mac is busy", model: mhModel(counts: mhPending, reasons: [.cpu], done: mhDone),
           statusLine: "Paused: the Mac is busy", title: "Paused", detail: "The Mac is busy", dot: "neutral",
           label: "Paused, The Mac is busy"),
    MHCase(name: "Paused, Low Power Mode", model: mhModel(counts: mhPending, reasons: [.lowPower], done: mhDone),
           statusLine: "Paused: Low Power Mode is on", title: "Paused", detail: "Low Power Mode is on", dot: "neutral",
           label: "Paused, Low Power Mode is on"),
    MHCase(name: "Paused on battery", model: mhModel(counts: mhPending, reasons: [.battery], done: mhDone),
           statusLine: "Paused: on battery", title: "Paused", detail: "On battery", dot: "neutral", label: "Paused, On battery"),
    MHCase(name: "Paused by you and on battery", model: mhModel(counts: mhPending, reasons: [.you, .battery], done: mhDone),
           statusLine: "Paused by you", title: "Paused", detail: "By you", dot: "neutral", label: "Paused, By you"),
    MHCase(name: "Paused, stalled and the Mac is busy", model: mhModel(counts: mhPending, reasons: [.stalled, .cpu], done: mhDone),
           statusLine: mhStalledLine, title: "Paused", detail: mhStalledDetail, dot: "neutral",
           label: "Paused, Indexing stopped, press Resume"),
    MHCase(name: "Paused, the Mac is busy and on battery", model: mhModel(counts: mhPending, reasons: [.cpu, .battery], done: mhDone),
           statusLine: "Paused: the Mac is busy", title: "Paused", detail: "The Mac is busy", dot: "neutral",
           label: "Paused, The Mac is busy"),
    MHCase(name: "Paused, Low Power Mode and on battery", model: mhModel(counts: mhPending, reasons: [.lowPower, .battery], done: mhDone),
           statusLine: "Paused: Low Power Mode is on", title: "Paused", detail: "Low Power Mode is on", dot: "neutral",
           label: "Paused, Low Power Mode is on"),
    MHCase(name: "Downloading 34%", model: mhModel(model: .downloading, startPressed: false, walkDone: false, counts: mhCounts(), percent: 34),
           statusLine: "Downloading the model, 34%", title: "Downloading the model, 34%", detail: nil, dot: "neutral",
           label: "Downloading the model, 34%"),
    MHCase(name: "Downloading 100%", model: mhModel(model: .downloading, startPressed: false, walkDone: false, counts: mhCounts(), percent: 100),
           statusLine: "Downloading the model, 100%", title: "Downloading the model, 100%", detail: nil, dot: "neutral",
           label: "Downloading the model, 100%"),
    MHCase(name: "Failed", model: mhModel(model: .failed, walkDone: false, counts: mhCounts(), percent: 34),
           statusLine: "Model download failed", title: "Model download failed", detail: nil, dot: "failed",
           label: "Model download failed"),
]

@MainActor
func mhActions() -> MenuActions {
    MenuActions(pause: {}, resume: {}, resumeAnyway: {}, retryDownload: {}, open: {}, settings: {}, quit: {})
}

@MainActor
func mhMenu(_ model: MenuModel) -> NSMenu {
    MenuBuilder.build(model, actions: mhActions())
}

@MainActor
func mhHeaderView(_ model: MenuModel, _ look: DTLook = .light) -> NSView? {
    guard let view = mhMenu(model).items.first?.view else { return nil }
    mhLook(view, look)
    return view
}

@MainActor
func mhLook(_ view: NSView, _ look: DTLook) {
    view.appearance = dtAppearance(look)
    view.layoutSubtreeIfNeeded()
}

@MainActor
func mhDots(_ view: NSView) -> [NSView] {
    prViews(view).filter { candidate in
        candidate !== view && !(candidate is NSTextField) && plVisible(candidate)
            && abs(candidate.frame.width - 8) <= 0.5 && abs(candidate.frame.height - 8) <= 0.5 && candidate.layer?.cornerRadius == 4
    }
}

@MainActor
func mhLine(_ font: NSFont) -> CGFloat {
    let field = NSTextField(labelWithString: "Ag")
    field.font = font
    return field.intrinsicContentSize.height
}

func mhSystemColour(_ dot: String) -> NSColor {
    switch dot {
    case "ready": return .systemGreen
    case "active": return .controlAccentColor
    case "failed": return .systemRed
    default: return .tertiaryLabelColor
    }
}

func mhSymbolName(_ image: NSImage?) -> String? {
    guard let text = image?.description, let range = text.range(of: "symbol = ") else { return nil }
    return String(text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "." })
}

func mhIsSixteenPoint(_ size: NSSize, symbol: String) -> Bool {
    if abs(size.width - 16) <= 0.5 && abs(size.height - 16) <= 0.5 { return true }
    guard let reference = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))?.size else { return false }
    return abs(size.width - reference.width) <= 1.5 && abs(size.height - reference.height) <= 1.5
}

func mhHasGradient(_ layer: CALayer?) -> Bool {
    guard let layer else { return false }
    if layer is CAGradientLayer { return true }
    return (layer.sublayers ?? []).contains { mhHasGradient($0) }
}

@MainActor
func mhLeft(_ root: NSView, _ field: NSTextField, near x: CGFloat) -> Bool {
    abs(plBox(root, field).minX - x) <= 1 || abs(slAlignBox(root, field).minX - x) <= 1
}

@MainActor
func mhTop(_ root: NSView, _ field: NSTextField, near y: CGFloat) -> Bool {
    abs(plBox(root, field).top - y) <= 1 || abs(slAlignBox(root, field).top - y) <= 1
}

@MainActor
func mhBottomGap(_ root: NSView, _ field: NSTextField, near gap: CGFloat) -> Bool {
    abs((root.bounds.height - plBox(root, field).bottom) - gap) <= 1
        || abs((root.bounds.height - slAlignBox(root, field).bottom) - gap) <= 1
}

@MainActor
func mhEntries(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.filter { !$0.isSeparatorItem }
}

@MainActor
func mhLines(_ menu: NSMenu) -> [String] {
    menu.items.map { $0.isSeparatorItem ? mhSep : $0.title }
}

@MainActor
func mhInfo(_ menu: NSMenu) -> [NSMenuItem] {
    let actions = [mhPause, mhResume, mhAnyway, mhRetry]
    let entries = Array(mhEntries(menu).dropFirst())
    let end = entries.firstIndex { $0.title == mhOpen } ?? entries.count
    return entries[..<end].filter { !actions.contains($0.title) }
}

func mhHostViolations(_ source: String) -> [String] {
    guard let start = source.range(of: "class SystemStatusItemHost") else { return ["there is no class SystemStatusItemHost"] }
    let body = String(source[start.lowerBound...])
    var found: [String] = []
    if let assignment = try? NSRegularExpression(pattern: #"\.(title|attributedTitle)\s*=(?!=)\s*([^\n]*)"#) {
        let whole = NSRange(location: 0, length: (body as NSString).length)
        for match in assignment.matches(in: body, range: whole) {
            let property = (body as NSString).substring(with: match.range(at: 1))
            let value = (body as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if value != "\"\"" { found.append("the host assigns \(value) to \(property)") }
        }
    }
    if !body.contains("imagePosition = .imageOnly") { found.append("the host no longer sets imagePosition = .imageOnly") }
    guard let block = mhBlock(body, from: "var buttonTitle") else {
        found.append("the host has no buttonTitle")
        return found
    }
    if block.range(of: #"\bbutton\b"#, options: .regularExpression) != nil { found.append("buttonTitle touches the button: \(block)") }
    if block.contains(".title") || block.contains("attributedTitle") { found.append("buttonTitle reads or writes a title: \(block)") }
    if !block.contains("\"\"") && !block.contains("String()") { found.append("buttonTitle does not return an empty string: \(block)") }
    return found
}

func mhBlock(_ text: String, from marker: String) -> String? {
    guard let start = text.range(of: marker) else { return nil }
    let tail = text[start.lowerBound...]
    guard let lineEnd = tail.firstIndex(of: "\n") else { return String(tail) }
    guard tail[..<lineEnd].contains("{") else { return String(tail[..<lineEnd]) }
    var depth = 0
    var end = tail.endIndex
    for index in tail.indices {
        if tail[index] == "{" { depth += 1 }
        if tail[index] == "}" {
            depth -= 1
            if depth == 0 {
                end = tail.index(after: index)
                break
            }
        }
    }
    return String(tail[..<end])
}

func mhHostSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("Sources/Sesame/MenuBar/MenuBarController.swift"), encoding: .utf8)
}

let mhGoodHost = """
final class SystemStatusItemHost: StatusItemHost {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init() {
        item.button?.imagePosition = .imageOnly
    }

    var buttonAccessibilityLabel: String {
        get { item.button?.accessibilityLabel() ?? "" }
        set { item.button?.setAccessibilityLabel(newValue) }
    }

    var buttonTitle: String {
        get { "" }
        set { _ = newValue }
    }
}
"""

final class MHFakeHost: StatusItemHost {
    var buttonAccessibilityLabel = ""
    var buttonTitle = ""
    var buttonImage: NSImage?
    var menu: NSMenu?
}

struct MHActionRow {
    let name: String
    let model: MenuModel
    let titles: [String]
}

let mhActionRows: [MHActionRow] = [
    MHActionRow(name: "Indexing", model: mhModel(counts: mhPending, done: mhDone), titles: [mhPause]),
    MHActionRow(name: "Paused by you", model: mhModel(counts: mhPending, reasons: [.you]), titles: [mhResume]),
    MHActionRow(name: "Paused, stalled", model: mhModel(counts: mhPending, reasons: [.stalled]), titles: [mhResume]),
    MHActionRow(name: "Paused on battery alone", model: mhModel(counts: mhPending, reasons: [.battery]), titles: [mhAnyway]),
    MHActionRow(name: "Paused by you and on battery", model: mhModel(counts: mhPending, reasons: [.you, .battery]), titles: [mhResume, mhAnyway]),
    MHActionRow(name: "Paused, stalled and on battery", model: mhModel(counts: mhPending, reasons: [.stalled, .battery]), titles: [mhResume, mhAnyway]),
    MHActionRow(name: "Paused, the Mac is busy", model: mhModel(counts: mhPending, reasons: [.cpu]), titles: []),
    MHActionRow(name: "Paused, Low Power Mode", model: mhModel(counts: mhPending, reasons: [.lowPower]), titles: []),
    MHActionRow(name: "Paused, the Mac is busy and on battery", model: mhModel(counts: mhPending, reasons: [.cpu, .battery]), titles: [mhAnyway]),
    MHActionRow(name: "Failed", model: mhModel(model: .failed, walkDone: false, counts: mhCounts(), percent: 34), titles: [mhRetry]),
    MHActionRow(name: "Failed while paused on battery", model: mhModel(model: .failed, counts: mhPending, reasons: [.battery]), titles: [mhRetry]),
    MHActionRow(name: "Ready after Start", model: mhModel(counts: mhCounts(done: 11841), done: mhDone), titles: []),
    MHActionRow(name: "Ready before Start", model: mhModel(startPressed: false, walkDone: false, counts: mhCounts()), titles: []),
    MHActionRow(name: "Downloading", model: mhModel(model: .downloading, startPressed: false, walkDone: false, counts: mhCounts(), percent: 34), titles: []),
]

struct MHInfoRow {
    let name: String
    let model: MenuModel
    let lines: [String]
}

let mhInfoRows: [MHInfoRow] = [
    MHInfoRow(name: "Indexing with counts", model: mhModel(counts: mhPending, done: mhDone),
              lines: mhCountLines),
    MHInfoRow(name: "Ready with two locked files and counts",
              model: mhModel(counts: mhCounts(done: 11841, needs: 2), done: mhDone),
              lines: ["2 files need permission to be read"] + mhCountLines),
    MHInfoRow(name: "Ready with one locked file and nothing done", model: mhModel(counts: mhCounts(done: 11841, needs: 1)),
              lines: ["1 file needs permission to be read"]),
    MHInfoRow(name: "Ready with nothing done", model: mhModel(counts: mhCounts(done: 11841)), lines: []),
    MHInfoRow(name: "Indexing with nothing done", model: mhModel(counts: mhPending), lines: []),
    MHInfoRow(name: "Ready before Start", model: mhModel(startPressed: false, walkDone: false, counts: mhCounts()), lines: []),
    MHInfoRow(name: "Failed with nothing done", model: mhModel(model: .failed, walkDone: false, counts: mhCounts(), percent: 34), lines: []),
    MHInfoRow(name: "Downloading with nothing done",
              model: mhModel(model: .downloading, startPressed: false, walkDone: false, counts: mhCounts(), percent: 34), lines: []),
    MHInfoRow(name: "Ready with nothing done and Photos switched off",
              model: mhModel(counts: mhCounts(done: 11841), kindsOn: ["photo": false, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]),
              lines: []),
    MHInfoRow(name: "Ready with something done and Audio switched off",
              model: mhModel(counts: mhCounts(done: 13), done: ["photo": 3, "pdf": 2, "doc": 1, "audio": 1, "video": 1, "code": 5],
                             kindsOn: ["photo": true, "pdf": true, "doc": true, "audio": false, "video": true, "code": true]),
              lines: ["Photos: 3", "PDFs: 2", "Documents: 1", "Audio: Off", "Video: 1"]),
]

struct MHShape {
    let name: String
    let model: MenuModel
    let lines: [String]
}

let mhShapes: [MHShape] = [
    MHShape(name: "Ready, nothing done", model: mhModel(counts: mhCounts(done: 11841)),
            lines: ["Ready", mhSep, mhOpen, mhSettings, mhSep, mhQuit]),
    MHShape(name: "Indexing, nothing done", model: mhModel(counts: mhPending),
            lines: ["Indexing 62%", mhSep, mhPause, mhSep, mhOpen, mhSettings, mhSep, mhQuit]),
    MHShape(name: "Indexing with counts", model: mhModel(counts: mhPending, done: mhDone),
            lines: ["Indexing 62%", mhSep, mhPause, mhSep] + mhCountLines + [mhSep, mhOpen, mhSettings, mhSep, mhQuit]),
    MHShape(name: "Failed", model: mhModel(model: .failed, walkDone: false, counts: mhCounts(), percent: 34),
            lines: ["Model download failed", mhSep, mhRetry, mhSep, mhOpen, mhSettings, mhSep, mhQuit]),
    MHShape(name: "Ready with locked files and counts", model: mhModel(counts: mhCounts(done: 11841, needs: 2), done: mhDone),
            lines: ["Ready", mhSep, "2 files need permission to be read"] + mhCountLines
                + [mhSep, mhOpen, mhSettings, mhSep, mhQuit]),
    MHShape(name: "Paused by you with counts", model: mhModel(counts: mhPending, reasons: [.you], done: mhDone),
            lines: ["Paused by you", mhSep, mhResume, mhSep] + mhCountLines + [mhSep, mhOpen, mhSettings, mhSep, mhQuit]),
    MHShape(name: "Paused on battery alone, nothing done", model: mhModel(counts: mhPending, reasons: [.battery]),
            lines: ["Paused: on battery", mhSep, mhAnyway, mhSep, mhOpen, mhSettings, mhSep, mhQuit]),
    MHShape(name: "Paused, the Mac is busy, nothing done", model: mhModel(counts: mhPending, reasons: [.cpu]),
            lines: ["Paused: the Mac is busy", mhSep, mhOpen, mhSettings, mhSep, mhQuit]),
    MHShape(name: "Downloading, nothing done", model: mhModel(model: .downloading, startPressed: false, walkDone: false, counts: mhCounts(), percent: 34),
            lines: ["Downloading the model, 34%", mhSep, mhOpen, mhSettings, mhSep, mhQuit]),
]

@MainActor
@Suite("MenuHeaderTests", .serialized)
struct MenuHeaderTests {

    @Test func itemZeroIsTheDisabledHeaderTitledWithTheStatusLineAndIsTheOnlyItemWithAViewInEveryState() {
        for c in mhCases {
            let menu = mhMenu(c.model)
            guard let first = menu.items.first else {
                Issue.record("\(c.name): the menu is empty")
                continue
            }
            #expect(!first.isSeparatorItem, "\(c.name): the menu starts with a separator")
            #expect(!first.isEnabled, "\(c.name): the header is enabled")
            #expect(first.title == c.statusLine, "\(c.name): the header title is \(first.title.debugDescription), want \(c.statusLine.debugDescription)")
            #expect(first.view != nil, "\(c.name): the header has no view")
            let withViews = menu.items.filter { $0.view != nil }
            #expect(withViews.count == 1 && withViews.first === first, "\(c.name): items with a view: \(withViews.map(\.title))")
        }
    }

    @Test func theViewIsTwoHundredEightyWideWithOneEightPointCircleDotFourteenFromTheLeftCentredOnTheTitleLine() {
        for c in mhCases {
            guard let view = mhHeaderView(c.model) else {
                Issue.record("\(c.name): no header view")
                continue
            }
            #expect(abs(view.frame.width - 280) <= 1, "\(c.name): the view is \(view.frame.width) wide, want 280")
            let dots = mhDots(view)
            guard dots.count == 1, let dot = dots.first else {
                Issue.record("\(c.name): \(dots.count) 8 x 8 circle dots")
                continue
            }
            let box = plBox(view, dot)
            #expect(abs(box.minX - 14) <= 0.5, "\(c.name): the dot is \(box.minX) from the left, want 14")
            guard let title = plText(view, c.title) else {
                Issue.record("\(c.name): no title text \(c.title.debugDescription) in \(plTexts(view).map(\.stringValue))")
                continue
            }
            let line = plBox(view, title)
            #expect(abs((box.top + box.bottom) / 2 - (line.top + line.bottom) / 2) <= 1, "\(c.name): the dot centre \((box.top + box.bottom) / 2), the title line centre \((line.top + line.bottom) / 2)")
            #expect(!dot.isAccessibilityElement(), "\(c.name): the dot is an accessibility element")
        }
    }

    @Test func theTitleIsThirteenSemiboldLabelColourThirtyFromTheLeftAndTheDetailIsElevenPointFiveRegularSecondaryTwoUnderIt() {
        for c in mhCases {
            guard let view = mhHeaderView(c.model) else {
                Issue.record("\(c.name): no header view")
                continue
            }
            guard let title = plText(view, c.title) else {
                Issue.record("\(c.name): no title text \(c.title.debugDescription) in \(plTexts(view).map(\.stringValue))")
                continue
            }
            #expect(slFont(title.font, size: 13, weight: .semibold), "\(c.name): title font \(String(describing: title.font))")
            #expect(slColour(title.textColor, is: .labelColor), "\(c.name): title colour")
            #expect(mhLeft(view, title, near: 30), "\(c.name): the title starts at \(plBox(view, title).minX), want 30")
            guard let detailText = c.detail else { continue }
            guard let detail = plText(view, detailText) else {
                Issue.record("\(c.name): no detail text \(detailText.debugDescription) in \(plTexts(view).map(\.stringValue))")
                continue
            }
            #expect(slFont(detail.font, size: 11.5, weight: .regular), "\(c.name): detail font \(String(describing: detail.font))")
            #expect(slColour(detail.textColor, is: .secondaryLabelColor), "\(c.name): detail colour")
            #expect(abs(plBox(view, detail).minX - plBox(view, title).minX) <= 0.5, "\(c.name): the detail starts at \(plBox(view, detail).minX), the title at \(plBox(view, title).minX)")
            #expect(mhLeft(view, detail, near: 30), "\(c.name): the detail starts at \(plBox(view, detail).minX), want 30")
            let gap = swlGap(view, upper: [title], lower: [detail])
            #expect(gap.near(2, 1), "\(c.name): the detail is \(gap.frame) / \(gap.aligned) under the title, want 2")
        }
    }

    @Test func theHeightIsEightPlusTheTitleLinePlusTwoAndTheDetailLineWhenThereIsOnePlusSixAndAMissingDetailShowsNoText() {
        let titleLine = mhLine(NSFont.systemFont(ofSize: 13, weight: .semibold))
        let detailLine = mhLine(NSFont.systemFont(ofSize: 11.5, weight: .regular))
        for c in mhCases {
            guard let view = mhHeaderView(c.model) else {
                Issue.record("\(c.name): no header view")
                continue
            }
            let want = 8 + titleLine + (c.detail == nil ? 0 : 2 + detailLine) + 6
            #expect(abs(view.frame.height - want) <= 1, "\(c.name): the view is \(view.frame.height) high, want \(want)")
            let texts = plTexts(view).map(\.stringValue)
            let wantTexts = [c.title] + (c.detail.map { [$0] } ?? [])
            #expect(texts.count == wantTexts.count && Set(texts) == Set(wantTexts), "\(c.name): the visible texts are \(texts), want \(wantTexts)")
            guard let title = plText(view, c.title) else { continue }
            #expect(mhTop(view, title, near: 8), "\(c.name): the title is \(plBox(view, title).top) from the top, want 8")
            let last = c.detail.flatMap { plText(view, $0) } ?? title
            #expect(mhBottomGap(view, last, near: 6), "\(c.name): the last line ends \(view.bounds.height - plBox(view, last).bottom) above the bottom, want 6")
        }
    }

    @Test func noTextIsTruncatedForTheLongestTitleAndTheLongestDetailOfEveryStateAndTheLargestCounts() {
        let huge = mhModel(counts: mhCounts(done: 100, pending: ["photo": 1_234_567]), done: mhDone)
        let cases = mhCases.map { (name: $0.name, model: $0.model, texts: [$0.title] + ($0.detail.map { [$0] } ?? [])) }
            + [(name: "Indexing with 1,234,567 files left", model: huge, texts: [huge.statusLine] + (huge.detailLine.map { [$0] } ?? []))]
        for c in cases {
            guard let view = mhHeaderView(c.model) else {
                Issue.record("\(c.name): no header view")
                continue
            }
            for text in c.texts {
                guard let field = plText(view, text) else {
                    Issue.record("\(c.name): no text \(text.debugDescription) in \(plTexts(view).map(\.stringValue))")
                    continue
                }
                let font = field.font ?? NSFont.systemFont(ofSize: 13)
                let width = (text as NSString).size(withAttributes: [.font: font]).width
                #expect(field.frame.width >= ceil(width) - 0.5, "\(c.name): \(text.debugDescription) needs \(width) but its field is \(field.frame.width) wide")
                #expect(field.frame.maxX <= view.frame.width + 0.5, "\(c.name): \(text.debugDescription) ends at \(field.frame.maxX), past the \(view.frame.width) wide view")
                #expect(field.frame.height >= mhLine(font) - 1, "\(c.name): \(text.debugDescription) is only \(field.frame.height) high")
                #expect(field.stringValue == text, "\(c.name): the field shows \(field.stringValue.debugDescription)")
            }
        }
    }

    @Test func theHeaderDrawsNoGradientNoEffectViewAndNoGlass() {
        for c in mhCases {
            guard let view = mhHeaderView(c.model) else {
                Issue.record("\(c.name): no header view")
                continue
            }
            #expect(!mhHasGradient(view.layer), "\(c.name): a gradient layer in the header")
            for inner in prViews(view) {
                #expect(!mhHasGradient(inner.layer), "\(c.name): a gradient layer under \(type(of: inner))")
                #expect(!(inner is NSVisualEffectView), "\(c.name): an NSVisualEffectView in the header")
                #expect(!slIsGlass(inner), "\(c.name): a glass view in the header")
            }
        }
    }

    @Test func theDotColourIsTheHandCopiedSystemColourInBothLooksAndRepaintsWhenTheAppearanceChangesWithoutRebuildingTheMenu() {
        for c in mhCases {
            guard let view = mhHeaderView(c.model) else {
                Issue.record("\(c.name): no header view")
                continue
            }
            guard let dot = mhDots(view).first else {
                Issue.record("\(c.name): no dot")
                continue
            }
            for look in [DTLook.light, .dark, .light, .dark] {
                mhLook(view, look)
                let want = dtRGBA(mhSystemColour(c.dot), look)
                let actual = dtRGBA(cgColor: dot.layer?.backgroundColor)
                #expect(actual != nil && dtSame(actual ?? [], want), "\(c.name) \(look): the dot is \(String(describing: actual)), want the \(c.dot) colour \(want)")
            }
        }
    }

    @Test func theViewIsOneGroupElementLabelledTitleCommaDetailWithNoChildrenAndTheItemCarriesTheSameLabel() {
        for c in mhCases {
            let menu = mhMenu(c.model)
            guard let item = menu.items.first, let view = item.view else {
                Issue.record("\(c.name): no header view")
                continue
            }
            #expect(view.isAccessibilityElement(), "\(c.name): the header view is not an accessibility element")
            #expect(view.accessibilityRole() == .group, "\(c.name): role \(String(describing: view.accessibilityRole()))")
            #expect(view.accessibilityLabel() == c.label, "\(c.name): label \(String(describing: view.accessibilityLabel())), want \(c.label.debugDescription)")
            #expect((view.accessibilityChildren() ?? []).isEmpty, "\(c.name): the group has accessibility children")
            for inner in prViews(view) where inner !== view {
                #expect(!inner.isAccessibilityElement(), "\(c.name): a \(type(of: inner)) inside the header is an accessibility element")
            }
            #expect(item.accessibilityLabel() == c.label, "\(c.name): the item label is \(String(describing: item.accessibilityLabel())), want \(c.label.debugDescription)")
        }
    }

    @Test func actionItemsAppearOnlyWhenTheyCanBeUsedAndNoneIsGreyedOrHidden() {
        let actionTitles = [mhPause, mhResume, mhAnyway, mhRetry]
        for row in mhActionRows {
            let menu = mhMenu(row.model)
            let found = menu.items.filter { actionTitles.contains($0.title) }
            #expect(found.map(\.title) == row.titles, "\(row.name): the action items are \(found.map(\.title)), want \(row.titles)")
            for item in found {
                #expect(item.isEnabled, "\(row.name): \(item.title.debugDescription) is disabled")
                #expect(!item.isHidden, "\(row.name): \(item.title.debugDescription) is hidden")
                #expect(item.attributedTitle == nil, "\(row.name): \(item.title.debugDescription) has an attributed title")
            }
            for title in [mhOpen, mhSettings, mhQuit] {
                let item = menu.items.first { $0.title == title }
                #expect(item != nil && item?.isEnabled == true, "\(row.name): \(title.debugDescription) is missing or disabled")
            }
            for (title, symbol) in [(mhPause, "pause"), (mhResume, "play")] where row.titles.contains(title) {
                #expect(mhSymbolName(menu.items.first { $0.title == title }?.image) == symbol, "\(row.name): \(title.debugDescription) symbol")
            }
        }
    }

    @Test func theInfoLinesAreOneGroupOfPlainDisabledItemsOnlyWhereTheyHaveContentAndNothingIndexedYetIsGone() {
        for row in mhInfoRows {
            let menu = mhMenu(row.model)
            let info = mhInfo(menu)
            #expect(info.map(\.title) == row.lines, "\(row.name): the info lines are \(info.map(\.title)), want \(row.lines)")
            for item in info {
                #expect(!item.isEnabled, "\(row.name): \(item.title.debugDescription) is enabled")
                #expect(item.view == nil, "\(row.name): \(item.title.debugDescription) has a view")
            }
            let titles = menu.items.map(\.title)
            #expect(!titles.contains("Nothing indexed yet"), "\(row.name): \"Nothing indexed yet\" is in \(titles)")
            #expect(!menu.items.contains { !$0.isSeparatorItem && $0.title.isEmpty }, "\(row.name): an item has an empty title")
        }
    }

    @Test func theItemKindsOfFiveNamedCasesAndFourMoreEqualTheHandWrittenSequences() {
        for shape in mhShapes {
            let lines = mhLines(mhMenu(shape.model))
            #expect(lines == shape.lines, "\(shape.name): \(lines), want \(shape.lines)")
        }
    }

    @Test func noMenuStartsOrEndsWithASeparatorOrHoldsTwoInARowOrAnEmptyItemOrAnAbsentCountLineWithNothingDone() {
        let modelStates: [ModelState] = [.whole, .downloading, .failed]
        let countSets: [IndexCounts] = [mhCounts(), mhPending, mhCounts(done: 11841), mhCounts(done: 11841, needs: 2), mhCounts(done: 5, pending: ["pdf": 3], needs: 1)]
        let reasonSets: [Set<PauseReason>] = [[], [.you], [.stalled], [.cpu], [.lowPower], [.battery], [.you, .battery], [.cpu, .battery]]
        let doneSets: [[String: Int]] = [[:], mhDone, ["photo": 1, "audio": 2]]
        let starts: [(Bool, Bool)] = [(true, true), (false, false), (true, false)]
        let kindWords = ["Photos:", "PDFs:", "Documents:", "Audio:", "Video:"]
        let actionTitles = [mhPause, mhResume, mhAnyway, mhRetry]
        var checked = 0
        var bad: [String] = []
        for modelState in modelStates {
            for counts in countSets {
                for reasons in reasonSets {
                    for done in doneSets {
                        for (pressed, walk) in starts {
                            let model = mhModel(model: modelState, startPressed: pressed, walkDone: walk, counts: counts, reasons: reasons, percent: 40, done: done)
                            let menu = mhMenu(model)
                            checked += 1
                            let tag = "\(modelState) \(counts.done)/\(counts.needsPermission) \(reasons.count) reasons \(done.count) done \(pressed)/\(walk)"
                            let items = menu.items
                            if items.first?.isSeparatorItem != false { bad.append("\(tag): starts with a separator or is empty") }
                            if items.last?.isSeparatorItem != false { bad.append("\(tag): ends with a separator") }
                            if zip(items, items.dropFirst()).contains(where: { $0.isSeparatorItem && $1.isSeparatorItem }) { bad.append("\(tag): two separators in a row") }
                            let entries = items.filter { !$0.isSeparatorItem }
                            if entries.contains(where: { $0.title.isEmpty }) { bad.append("\(tag): an empty item") }
                            if entries.suffix(3).map(\.title) != [mhOpen, mhSettings, mhQuit] { bad.append("\(tag): the last three are \(entries.suffix(3).map(\.title))") }
                            if entries.dropFirst().contains(where: { $0.view != nil }) { bad.append("\(tag): a view past the header") }
                            if entries.first?.view == nil { bad.append("\(tag): no header view") }
                            if entries.contains(where: { actionTitles.contains($0.title) && !$0.isEnabled }) { bad.append("\(tag): a disabled action") }
                            if done.values.allSatisfy({ $0 == 0 }) && entries.contains(where: { item in kindWords.contains { item.title.hasPrefix($0) } }) {
                                bad.append("\(tag): a count line with nothing done: \(entries.map(\.title))")
                            }
                            if entries.contains(where: { $0.title == "Nothing indexed yet" }) { bad.append("\(tag): Nothing indexed yet") }
                        }
                    }
                }
            }
        }
        #expect(checked == 3 * 5 * 8 * 3 * 3, "the sweep covered \(checked) menus")
        #expect(bad.isEmpty, "\(bad.count) wrong, first ones: \(Array(bad.prefix(8)))")
    }

    @Test func openSesameHasTheMagnifierAndNoKeyOrViewAndNoShortcutTextIsInAnyItemOrTheHeaderWhileSettingsAndQuitKeepTheirKeysAndSymbols() {
        let banned = ["\u{2303}", "\u{2325}", "Control Option Space", "Control", "Option"]
        for c in mhCases {
            let menu = mhMenu(c.model)
            guard let open = menu.items.first(where: { $0.title == mhOpen }) else {
                Issue.record("\(c.name): no \(mhOpen)")
                continue
            }
            #expect(mhSymbolName(open.image) == "magnifyingglass", "\(c.name): symbol \(String(describing: mhSymbolName(open.image)))")
            #expect(open.image?.isTemplate == true, "\(c.name): the Open Sesame image is not a template")
            #expect(open.image.map { mhIsSixteenPoint($0.size, symbol: "magnifyingglass") } == true, "\(c.name): the Open Sesame image is not a 16 pt symbol")
            #expect(open.keyEquivalent.isEmpty, "\(c.name): Open Sesame has the key equivalent \(open.keyEquivalent.debugDescription)")
            #expect(open.view == nil, "\(c.name): Open Sesame has a view")
            var texts: [String] = []
            for item in menu.items {
                texts += [item.title, item.attributedTitle?.string ?? "", item.toolTip ?? ""]
            }
            guard let header = menu.items.first?.view else {
                Issue.record("\(c.name): no header view to scan for shortcut text")
                continue
            }
            texts += plTexts(header).map(\.stringValue)
            for word in banned {
                #expect(!texts.contains { $0.contains(word) }, "\(c.name): shortcut text \(word.debugDescription) in \(texts)")
            }
            let settings = menu.items.first { $0.title == mhSettings }
            #expect(settings?.keyEquivalent == "," && settings?.keyEquivalentModifierMask == .command, "\(c.name): Settings key")
            #expect(mhSymbolName(settings?.image) == "gearshape", "\(c.name): Settings symbol")
            let quit = menu.items.first { $0.title == mhQuit }
            #expect(quit?.keyEquivalent == "q" && quit?.keyEquivalentModifierMask == .command, "\(c.name): Quit key")
            #expect(mhSymbolName(quit?.image) == "power", "\(c.name): Quit symbol")
        }
    }

    @Test func theControllerStillSetsTheAccessibilityLabelAndTheTitleOfTheButtonOnTheFakeHostAndKeepsATemplateImage() {
        let rows: [(MenuModel, String)] = [
            (mhCases[1].model, "Sesame: ready"),
            (mhCases[2].model, "Sesame: indexing, 62 percent"),
            (mhCases[4].model, "Sesame: paused"),
            (mhCases[13].model, "Sesame: downloading the model, 34 percent"),
            (mhCases[15].model, "Sesame: model download failed"),
        ]
        for (model, label) in rows {
            let host = MHFakeHost()
            let controller = MenuBarController(host: host, actions: mhActions())
            controller.update(model)
            #expect(host.buttonAccessibilityLabel == label, "label \(host.buttonAccessibilityLabel.debugDescription), want \(label.debugDescription)")
            #expect(host.buttonTitle == label, "title \(host.buttonTitle.debugDescription), want \(label.debugDescription)")
            #expect(host.buttonImage?.isTemplate == true, "\(label): the button image is not a template")
            #expect(host.menu?.items.first?.view != nil, "\(label): the menu the controller set has no header view")
        }
    }

    @Test func theRealStatusItemHostNeverSetsAButtonTitleAndItsButtonTitleSetterIgnoresTheButton() throws {
        let violations = mhHostViolations(try mhHostSource())
        #expect(violations.isEmpty, "MenuBarController.swift: \(violations)")
    }

    @Test func theTextScanFailsWhenATitleAssignmentIsPlantedInACopyOfTheRealHostAndPassesAHandWrittenGoodHost() throws {
        let source = try mhHostSource()
        let plants = [
            ".imageOnly\n        item.button?.title = newValue",
            ".imageOnly\n        item.button?.attributedTitle = NSAttributedString(string: newValue)",
        ]
        for plant in plants {
            let planted = source.replacingOccurrences(of: ".imageOnly", with: plant)
            #expect(planted != source, "the real host holds no .imageOnly to plant after")
            #expect(!mhHostViolations(planted).isEmpty, "the scan missed the planted line \(plant.debugDescription)")
        }
        #expect(mhHostViolations(mhGoodHost).isEmpty, "the scan rejects the good host: \(mhHostViolations(mhGoodHost))")
        let bad: [(String, String)] = [
            ("a setter that writes the title", mhGoodHost.replacingOccurrences(of: "set { _ = newValue }", with: "set { item.button?.title = newValue }")),
            ("a getter that reads the title", mhGoodHost.replacingOccurrences(of: "get { \"\" }", with: "get { item.button?.title ?? \"\" }")),
            ("a setter that touches the button", mhGoodHost.replacingOccurrences(of: "set { _ = newValue }", with: "set { item.button?.toolTip = newValue }")),
            ("a getter that returns a word", mhGoodHost.replacingOccurrences(of: "get { \"\" }", with: "get { \"Sesame\" }")),
            ("no imageOnly", mhGoodHost.replacingOccurrences(of: ".imageOnly", with: ".imageLeading")),
        ]
        for (name, text) in bad {
            #expect(text != mhGoodHost, "\(name): the fixture was not changed")
            #expect(!mhHostViolations(text).isEmpty, "the scan missed \(name)")
        }
    }
}
