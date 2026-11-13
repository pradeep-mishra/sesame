import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let lrSep = "---"
private let lrShortPath = "/Users/me/Pictures/a.pdf"
private let lrLongName = String(String(repeating: "Brand_Performance_", count: 17).prefix(296)) + ".pdf"
private let lrLongPath = "/Users/me/Documents/" + lrLongName
private let lrPaths: [String?] = [lrShortPath, lrLongPath, nil]
private let lrFragments = ["last indexed", "/", "Brand_Performance", ".pdf"]
private let lrAllOn: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]
private let lrAudioOff: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": false, "video": true, "code": true]
private let lrDone: [String: Int] = ["photo": 9690, "pdf": 1083, "doc": 1068]
private let lrCountLines = ["Photos: 9,690", "PDFs: 1,083", "Documents: 1,068", "Audio: 0", "Video: 0"]
private let lrTail = [lrSep, "Open Sesame", "Settings…", lrSep, "Quit Sesame"]

private struct LRState {
    let name: String
    let model: ModelState
    let startPressed: Bool
    let walkDone: Bool
    let counts: IndexCounts
    let done: [String: Int]
    let reasons: Set<PauseReason>
    let kindsOn: [String: Bool]
    let lines: [String]
    let exactHead: Bool
    let groups: [Int]
}

private func lrCounts(done: Int = 0, pending: [String: Int] = [:], needs: Int = 0) -> IndexCounts {
    IndexCounts(done: done, pending: pending, partial: [:], needsPermission: needs)
}

private let lrStates: [LRState] = [
    LRState(name: "Ready", model: .whole, startPressed: true, walkDone: true, counts: lrCounts(done: 11841), done: lrDone,
            reasons: [], kindsOn: lrAllOn, lines: ["Ready", lrSep] + lrCountLines + lrTail, exactHead: true, groups: [1, 5, 2, 1]),
    LRState(name: "Ready with files that need permission", model: .whole, startPressed: true, walkDone: true,
            counts: lrCounts(done: 11841, needs: 2), done: lrDone, reasons: [], kindsOn: lrAllOn,
            lines: ["Ready", lrSep, "2 files need permission to be read"] + lrCountLines + lrTail, exactHead: true, groups: [1, 6, 2, 1]),
    LRState(name: "Indexing 62 percent", model: .whole, startPressed: true, walkDone: true,
            counts: lrCounts(done: 7400, pending: ["photo": 4520]), done: lrDone, reasons: [], kindsOn: lrAllOn,
            lines: ["Indexing 62%", lrSep, "Pause indexing", lrSep] + lrCountLines + lrTail, exactHead: true, groups: [1, 1, 5, 2, 1]),
    LRState(name: "Paused by you", model: .whole, startPressed: true, walkDone: true,
            counts: lrCounts(done: 7400, pending: ["photo": 4520]), done: lrDone, reasons: [.you], kindsOn: lrAllOn,
            lines: ["Paused by you", lrSep, "Resume indexing", lrSep] + lrCountLines + lrTail, exactHead: true, groups: [1, 1, 5, 2, 1]),
    LRState(name: "Paused with the battery reason", model: .whole, startPressed: true, walkDone: true,
            counts: lrCounts(done: 7400, pending: ["photo": 4520]), done: lrDone, reasons: [.battery], kindsOn: lrAllOn,
            lines: ["Paused: on battery", lrSep, "Resume anyway, on battery", lrSep] + lrCountLines + lrTail, exactHead: true, groups: [1, 1, 5, 2, 1]),
    LRState(name: "Downloading", model: .downloading, startPressed: false, walkDone: false, counts: lrCounts(), done: [:],
            reasons: [], kindsOn: lrAllOn, lines: ["Downloading the model, ", lrSep, "Open Sesame", "Settings…", lrSep, "Quit Sesame"],
            exactHead: false, groups: [1, 2, 1]),
    LRState(name: "Failed", model: .failed, startPressed: true, walkDone: false, counts: lrCounts(), done: [:],
            reasons: [], kindsOn: lrAllOn,
            lines: ["Model download failed", lrSep, "Retry model download", lrSep, "Open Sesame", "Settings…", lrSep, "Quit Sesame"],
            exactHead: true, groups: [1, 1, 2, 1]),
    LRState(name: "Ready with every count zero", model: .whole, startPressed: true, walkDone: true, counts: lrCounts(done: 11841), done: [:],
            reasons: [], kindsOn: lrAllOn, lines: ["Ready", lrSep, "Open Sesame", "Settings…", lrSep, "Quit Sesame"],
            exactHead: true, groups: [1, 2, 1]),
    LRState(name: "Ready with Audio switched off", model: .whole, startPressed: true, walkDone: true, counts: lrCounts(done: 11841), done: lrDone,
            reasons: [], kindsOn: lrAudioOff,
            lines: ["Ready", lrSep, "Photos: 9,690", "PDFs: 1,083", "Documents: 1,068", "Audio: Off", "Video: 0"] + lrTail,
            exactHead: true, groups: [1, 5, 2, 1]),
]

private func lrSnapshot(_ state: LRState, path: String?) -> PanelSnapshot {
    var snapshot = PanelSnapshot()
    snapshot.model = state.model
    snapshot.startPressed = state.startPressed
    snapshot.walkDone = state.walkDone
    snapshot.counts = state.counts
    snapshot.doneByKind = state.done
    snapshot.lastIndexedPath = path
    return snapshot
}

private func lrSettings(_ kindsOn: [String: Bool]) -> Settings {
    var settings = Settings()
    settings.kindsOn = kindsOn
    settings.speeds = ["photo": 0.16]
    return settings
}

private func lrModel(_ state: LRState, path: String?) -> MenuModel {
    MenuModel.make(snapshot: lrSnapshot(state, path: path), pauseReasons: state.reasons, settings: lrSettings(state.kindsOn))
}

private func lrActions() -> MenuActions {
    MenuActions(pause: {}, resume: {}, resumeAnyway: {}, retryDownload: {}, open: {}, settings: {}, quit: {})
}

@MainActor
private func lrMenu(_ state: LRState, path: String?) -> NSMenu {
    MenuBuilder.build(lrModel(state, path: path), actions: lrActions())
}

private func lrLines(_ menu: NSMenu) -> [String] {
    menu.items.map { $0.isSeparatorItem ? lrSep : $0.title }
}

private func lrGroups(_ menu: NSMenu) -> [Int] {
    var sizes: [Int] = []
    var run = 0
    for item in menu.items {
        if item.isSeparatorItem {
            sizes.append(run)
            run = 0
        } else {
            run += 1
        }
    }
    sizes.append(run)
    return sizes
}

private func lrSymbolName(_ image: NSImage?) -> String? {
    guard let text = image?.description, let range = text.range(of: "symbol = ") else { return nil }
    return String(text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "." })
}

@MainActor
private func lrTexts(_ menu: NSMenu) -> [String] {
    var texts: [String] = []
    for item in menu.items {
        texts += [item.title, item.accessibilityLabel() ?? "", item.attributedTitle?.string ?? "", item.toolTip ?? ""]
    }
    if let header = menu.items.first?.view {
        texts += plTexts(header).map(\.stringValue)
        texts.append(header.accessibilityLabel() ?? "")
    }
    return texts
}

private func lrHeadMatches(_ lines: [String], _ state: LRState, _ want: [String]) -> Bool {
    guard lines.count == want.count, let head = lines.first, let wantHead = want.first else { return false }
    let headOK = state.exactHead ? head == wantHead : head.hasPrefix(wantHead)
    return headOK && Array(lines.dropFirst()) == Array(want.dropFirst())
}

private final class LRFakeHost: StatusItemHost {
    var buttonAccessibilityLabel = ""
    var buttonTitle = ""
    var buttonImage: NSImage?
    var menuAssignments = 0
    var menu: NSMenu? { didSet { menuAssignments += 1 } }
}

@MainActor
@Suite("MenuLastIndexedRemovedTests", .serialized)
struct MenuLastIndexedRemovedTests {

    @Test func noItemTitleLabelToolTipOrHeaderTextHoldsLastIndexedASlashOrTheFileNameInAnyState() {
        var bad: [String] = []
        for state in lrStates {
            for path in lrPaths {
                let texts = lrTexts(lrMenu(state, path: path))
                for fragment in lrFragments {
                    if let hit = texts.first(where: { $0.localizedCaseInsensitiveContains(fragment) }) {
                        bad.append("\(state.name), path \(path.map { String($0.suffix(12)) } ?? "nil"): \(hit.prefix(60).debugDescription) holds \(fragment.debugDescription)")
                    }
                }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong, first ones: \(Array(bad.prefix(6)))")
    }

    @Test func theItemTitlesAreTheSameForTheShortNameTheThreeHundredCharacterNameAndNoFileAtAll() {
        #expect(lrLongName.count == 300, "the long file name is \(lrLongName.count) characters")
        #expect(lrShortPath.split(separator: "/").last?.count == 5, "the short file name is not 5 characters")
        var bad: [String] = []
        for state in lrStates {
            let short = lrLines(lrMenu(state, path: lrShortPath))
            let long = lrLines(lrMenu(state, path: lrLongPath))
            let none = lrLines(lrMenu(state, path: nil))
            if short != long { bad.append("\(state.name): short \(short), long \(long.map { String($0.prefix(40)) })") }
            if short != none { bad.append("\(state.name): short \(short), no file \(none)") }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong: \(bad)")
    }

    @Test func everyStateReadsTheHandWrittenLinesWhateverFileWasIndexedLast() {
        var bad: [String] = []
        for state in lrStates {
            for path in lrPaths {
                let lines = lrLines(lrMenu(state, path: path))
                if !lrHeadMatches(lines, state, state.lines) {
                    bad.append("\(state.name), \(path.map { String($0.suffix(8)) } ?? "nil"): \(lines.map { String($0.prefix(40)) }), want \(state.lines)")
                }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong: \(bad)")
    }

    @Test func theMenuIsEquallyWideForTheShortAndTheLongNameAndNoWiderThanThreeHundredPoints() {
        var bad: [String] = []
        for state in lrStates {
            let short = lrMenu(state, path: lrShortPath).size.width
            let long = lrMenu(state, path: lrLongPath).size.width
            if abs(short - long) > 0.5 { bad.append("\(state.name): short \(short) wide, long \(long) wide") }
            if long > 300 { bad.append("\(state.name): the long name makes the menu \(long) wide") }
            if short > 300 { bad.append("\(state.name): the short name makes the menu \(short) wide") }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong: \(bad)")
    }

    @Test func theGroupsHaveNoSeparatorFirstOrLastNoneDoubledAndOneBetweenEveryTwoNonEmptyGroups() {
        var bad: [String] = []
        for state in lrStates {
            for path in lrPaths {
                let menu = lrMenu(state, path: path)
                let tag = "\(state.name), \(path.map { String($0.suffix(8)) } ?? "nil")"
                let items = menu.items
                if items.first?.isSeparatorItem != false { bad.append("\(tag): starts with a separator or is empty") }
                if items.last?.isSeparatorItem != false { bad.append("\(tag): ends with a separator") }
                if zip(items, items.dropFirst()).contains(where: { $0.isSeparatorItem && $1.isSeparatorItem }) { bad.append("\(tag): two separators in a row") }
                let groups = lrGroups(menu)
                if groups.contains(0) { bad.append("\(tag): an empty group in \(groups)") }
                if groups != state.groups { bad.append("\(tag): the group sizes are \(groups), want \(state.groups)") }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong: \(bad)")
    }

    @Test func theThreeActionLinesKeepTheirTitlesKeysSymbolsAndLabelsAndComeLast() {
        var bad: [String] = []
        for state in lrStates {
            for path in [lrShortPath, lrLongPath] {
                let menu = lrMenu(state, path: path)
                let entries = menu.items.filter { !$0.isSeparatorItem }
                let tag = "\(state.name), \(String(path.suffix(8)))"
                if entries.suffix(3).map(\.title) != ["Open Sesame", "Settings…", "Quit Sesame"] { bad.append("\(tag): the last three are \(entries.suffix(3).map { String($0.title.prefix(40)) })") }
                for (title, key, symbol) in [("Open Sesame", "", "magnifyingglass"), ("Settings…", ",", "gearshape"), ("Quit Sesame", "q", "power")] {
                    guard let item = menu.items.first(where: { $0.title == title }) else {
                        bad.append("\(tag): no item \(title.debugDescription)")
                        continue
                    }
                    if !item.isEnabled { bad.append("\(tag): \(title) is disabled") }
                    if item.accessibilityLabel() != title { bad.append("\(tag): \(title) has the label \(String(describing: item.accessibilityLabel()))") }
                    if item.keyEquivalent != key { bad.append("\(tag): \(title) has the key \(item.keyEquivalent.debugDescription), want \(key.debugDescription)") }
                    if !key.isEmpty && item.keyEquivalentModifierMask != .command { bad.append("\(tag): \(title) has the modifiers \(item.keyEquivalentModifierMask)") }
                    if lrSymbolName(item.image) != symbol { bad.append("\(tag): \(title) has the symbol \(String(describing: lrSymbolName(item.image))), want \(symbol)") }
                }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong: \(bad)")
    }

    @Test func theFiveCountRowsReadTheHandWrittenNumbersAreDisabledAndLabelledWhateverFileWasIndexedLast() {
        let rows: [(done: [String: Int], lines: [String], labels: [String])] = [
            (["photo": 81, "pdf": 67, "doc": 19, "audio": 0, "video": 7],
             ["Photos: 81", "PDFs: 67", "Documents: 19", "Audio: 0", "Video: 7"], ["Photos", "PDFs", "Documents", "Audio", "Video"]),
            (["photo": 1234, "pdf": 56789, "doc": 1000, "audio": 0, "video": 7],
             ["Photos: 1,234", "PDFs: 56,789", "Documents: 1,000", "Audio: 0", "Video: 7"], ["Photos", "PDFs", "Documents", "Audio", "Video"]),
        ]
        var bad: [String] = []
        for row in rows {
            for path in [lrShortPath, lrLongPath] {
                let state = LRState(name: "Ready with counts", model: .whole, startPressed: true, walkDone: true, counts: lrCounts(done: 11841),
                                    done: row.done, reasons: [], kindsOn: lrAllOn, lines: [], exactHead: true, groups: [])
                let menu = lrMenu(state, path: path)
                let entries = menu.items.filter { !$0.isSeparatorItem }
                let middle = Array(entries.dropFirst().dropLast(3))
                if middle.map(\.title) != row.lines { bad.append("\(String(path.suffix(8))): the rows are \(middle.map(\.title)), want \(row.lines)") }
                for (item, label) in zip(middle, row.labels) {
                    if item.isEnabled { bad.append("\(item.title) is enabled") }
                    let description = item.accessibilityLabel() ?? ""
                    if !description.contains(label) || !description.contains(item.title.split(separator: " ").last.map(String.init) ?? "?") {
                        bad.append("\(item.title.debugDescription) has the accessibility description \(description.debugDescription)")
                    }
                }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong: \(bad)")
    }

    @Test func theModelReadsTheSameStatusHeaderPermissionAndFirstActionAsBeforeWhateverFileWasIndexedLast() {
        let ready = lrStates[0]
        let locked = lrStates[1]
        let indexing = lrStates[2]
        let paused = lrStates[3]
        for path in lrPaths {
            let r = lrModel(ready, path: path)
            #expect(r.statusLine == "Ready" && r.headerTitle == "Ready" && r.headerDetail == nil && r.permissionLine == nil,
                    "Ready: \(r.statusLine), \(r.headerTitle), \(String(describing: r.headerDetail)), \(String(describing: r.permissionLine))")
            let l = lrModel(locked, path: path)
            #expect(l.permissionLine == "2 files need permission to be read", "locked: \(String(describing: l.permissionLine))")
            let i = lrModel(indexing, path: path)
            #expect(i.statusLine == "Indexing 62%" && i.headerTitle == "Indexing 62%", "Indexing: \(i.statusLine), \(i.headerTitle)")
            #expect(i.headerDetail == "4,520 files left · about 12 min left", "Indexing detail: \(String(describing: i.headerDetail))")
            #expect(i.firstActionTitle == "Pause indexing", "Indexing first action: \(i.firstActionTitle)")
            let p = lrModel(paused, path: path)
            #expect(p.statusLine == "Paused by you" && p.headerTitle == "Paused" && p.headerDetail == "By you", "Paused: \(p.statusLine), \(p.headerTitle), \(String(describing: p.headerDetail))")
            #expect(p.firstActionTitle == "Resume indexing", "Paused first action: \(p.firstActionTitle)")
        }
    }

    @Test func theModelHoldsNoStoredFieldForTheLastIndexedFile() {
        let labels = Mirror(reflecting: lrModel(lrStates[0], path: lrLongPath)).children.compactMap(\.label)
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("lastIndexed") }, "the model still stores \(labels)")
        #expect(labels.contains("inputs") && labels.contains("doneByKind"), "the model fields are \(labels)")
    }

    @Test func aNewLastIndexedFileDoesNotRebuildTheMenuOfTheController() {
        let host = LRFakeHost()
        let controller = MenuBarController(host: host, actions: lrActions())
        let state = lrStates[2]
        controller.update(lrModel(state, path: lrShortPath))
        let first = host.menuAssignments
        #expect(first >= 1, "the first update set no menu")
        controller.update(lrModel(state, path: lrLongPath))
        controller.update(lrModel(state, path: nil))
        controller.update(lrModel(state, path: lrShortPath))
        #expect(host.menuAssignments == first, "a different last file replaced the menu: \(host.menuAssignments) assignments, was \(first)")
    }
}
