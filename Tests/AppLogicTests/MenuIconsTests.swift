import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let miWalk = Date(timeIntervalSince1970: 1_700_000_000)
private let miAllOn: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]
private let miDone: [String: Int] = ["photo": 9690, "pdf": 1083, "doc": 1068]
private let miSep = "---"

private func miCounts(done: Int = 0, pending: [String: Int] = [:], needs: Int = 0) -> IndexCounts {
    IndexCounts(done: done, pending: pending, partial: [:], needsPermission: needs)
}

private func miModel(model: ModelState = .whole, startPressed: Bool = true, walkDone: Bool = true, counts: IndexCounts,
                     reasons: Set<PauseReason> = [], percent: Int = 0, done: [String: Int] = [:]) -> MenuModel {
    let inputs = MenuInputs(model: model, startPressed: startPressed, indexDeleted: false, walkDoneAt: walkDone ? miWalk : nil,
                            counts: counts, pauseReasons: reasons)
    return MenuModel(inputs: inputs, downloadPercent: percent, doneByKind: done,
                     speeds: ["photo": 0.16], kindsOn: miAllOn)
}

private let miIndexing = miModel(counts: miCounts(done: 7400, pending: ["photo": 4520]), done: miDone)
private let miPausedByYou = miModel(counts: miCounts(done: 7400, pending: ["photo": 4520]), reasons: [.you], done: miDone)
private let miPausedOnBattery = miModel(counts: miCounts(done: 7400, pending: ["photo": 4520]), reasons: [.battery], done: miDone)
private let miReady = miModel(counts: miCounts(done: 11841), done: miDone)
private let miNotStarted = miModel(startPressed: false, walkDone: false, counts: miCounts())
private let miFailed = miModel(model: .failed, walkDone: false, counts: miCounts(), percent: 34)
private let miDownloading = miModel(model: .downloading, startPressed: false, walkDone: false, counts: miCounts(), percent: 34)

private let miCountLines = ["Photos: 9,690", "PDFs: 1,083", "Documents: 1,068", "Audio: 0", "Video: 0"]

private let miExpectedLists: [(name: String, model: MenuModel, lines: [String])] = [
    ("Indexing", miIndexing,
     ["Indexing 62%", miSep, "Pause indexing", miSep] + miCountLines
        + [miSep, "Open Sesame", "Settings…", miSep, "Quit Sesame"]),
    ("Paused on battery", miPausedOnBattery,
     ["Paused: on battery", miSep, "Resume anyway, on battery", miSep] + miCountLines
        + [miSep, "Open Sesame", "Settings…", miSep, "Quit Sesame"]),
    ("Not started", miNotStarted,
     ["Indexing has not been started", miSep, "Open Sesame", "Settings…", miSep, "Quit Sesame"]),
    ("Failed", miFailed,
     ["Model download failed", miSep, "Retry model download", miSep, "Open Sesame", "Settings…", miSep, "Quit Sesame"]),
]

private let miAllModels: [(name: String, model: MenuModel)] = [
    ("Indexing", miIndexing), ("Paused by you", miPausedByYou), ("Paused on battery", miPausedOnBattery),
    ("Ready", miReady), ("Not started", miNotStarted), ("Failed", miFailed), ("Downloading", miDownloading),
]

private let miFixedItems: [(title: String, symbol: String)] = [
    ("Open Sesame", "magnifyingglass"),
    ("Settings…", "gearshape"),
    ("Quit Sesame", "power"),
]

private func miActions() -> MenuActions {
    MenuActions(pause: {}, resume: {}, resumeAnyway: {}, retryDownload: {}, open: {}, settings: {}, quit: {})
}

@MainActor
private func miBuild(_ model: MenuModel) -> NSMenu {
    MenuBuilder.build(model, actions: miActions())
}

private func miLines(_ menu: NSMenu) -> [String] {
    menu.items.map { $0.isSeparatorItem ? miSep : $0.title }
}

private func miSymbolName(_ image: NSImage?) -> String? {
    guard let text = image?.description, let range = text.range(of: "symbol = ") else { return nil }
    return String(text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "." })
}

private func miLooksSixteenPoint(_ size: NSSize, symbol: String) -> Bool {
    if abs(size.width - 16) <= 0.5 && abs(size.height - 16) <= 0.5 { return true }
    guard let reference = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))?.size else { return false }
    return abs(size.width - reference.width) <= 1.5 && abs(size.height - reference.height) <= 1.5
}

@MainActor
private func miItem(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
    menu.items.first { $0.title == title }
}

@MainActor
private func miExpectSymbol(_ item: NSMenuItem?, _ title: String, _ symbol: String, _ context: String) {
    guard let item else {
        Issue.record("\(context): no item \(title.debugDescription)")
        return
    }
    #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "the system has no symbol named \(symbol)")
    guard let image = item.image else {
        Issue.record("\(context): \(title.debugDescription) has no image")
        return
    }
    #expect(image.isTemplate, "\(context): \(title.debugDescription) image is not a template")
    #expect(miSymbolName(image) == symbol, "\(context): \(title.debugDescription) symbol is \(String(describing: miSymbolName(image))), want \(symbol)")
    #expect(miLooksSixteenPoint(image.size, symbol: symbol),"\(context): \(title.debugDescription) image is \(image.size), not a 16 pt symbol")
}

private final class MIFakeHost: StatusItemHost {
    var buttonAccessibilityLabel = ""
    var buttonTitle = ""
    var buttonImage: NSImage?
    var menu: NSMenu?
}

private func miSourceText() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("Sources/Sesame/MenuBar/StatusIcons.swift"), encoding: .utf8)
}

private struct MIInk {
    let opaque: Int
    let total: Int
    let allBlack: Bool
}

private func miInk(_ image: NSImage) -> MIInk? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    var opaque = 0
    var allBlack = true
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.alphaComponent > 0.5 { opaque += 1 }
            if color.alphaComponent > 0.05, color.redComponent > 0.05 || color.greenComponent > 0.05 || color.blueComponent > 0.05 {
                allBlack = false
            }
        }
    }
    return MIInk(opaque: opaque, total: rep.pixelsWide * rep.pixelsHigh, allBlack: allBlack)
}

private let miStates: [(name: String, state: MenuState)] = [
    ("ready", .ready), ("indexing", .indexing), ("paused", .paused), ("downloading", .downloading), ("failed", .failed),
]

@MainActor
@Suite("MenuIconsTests", .serialized)
struct MenuIconsTests {

    @Test func theThreeFixedItemsCarryASixteenPointTemplateSymbolInEveryState() {
        for (name, model) in miAllModels {
            let menu = miBuild(model)
            for (title, symbol) in miFixedItems {
                miExpectSymbol(miItem(menu, title), title, symbol, name)
            }
        }
    }

    @Test func pauseIndexingCarriesThePauseSymbolWhileIndexingAndIsInNoOtherState() {
        miExpectSymbol(miItem(miBuild(miIndexing), "Pause indexing"), "Pause indexing", "pause", "Indexing")
        for (name, model) in [("Ready", miReady), ("Not started", miNotStarted), ("Downloading", miDownloading)] {
            #expect(miItem(miBuild(model), "Pause indexing") == nil, "\(name): a Pause item is in the menu: \(miLines(miBuild(model)))")
        }
    }

    @Test func resumeIndexingCarriesThePlaySymbolWhenPausedByYouAndIsAbsentWhenPausedOnBatteryAlone() {
        miExpectSymbol(miItem(miBuild(miPausedByYou), "Resume indexing"), "Resume indexing", "play", "Paused by you")
        #expect(miItem(miBuild(miPausedOnBattery), "Resume indexing") == nil, "Paused on battery: a Resume item is in the menu: \(miLines(miBuild(miPausedOnBattery)))")
    }

    @Test func theItemsKeepTheirTitlesFlagsKeysAndVoiceOverLabelsWithTheirImages() {
        for (name, model) in miAllModels {
            let menu = miBuild(model)
            for (title, _) in miFixedItems {
                guard let item = miItem(menu, title) else {
                    Issue.record("\(name): no item \(title.debugDescription)")
                    continue
                }
                #expect(item.isEnabled, "\(name): \(title.debugDescription) is disabled")
                #expect(item.accessibilityLabel() == title, "\(name): \(title.debugDescription) label \(String(describing: item.accessibilityLabel()))")
            }
            let settings = miItem(menu, "Settings…")
            #expect(settings?.keyEquivalent == "," && settings?.keyEquivalentModifierMask == .command, "\(name): Settings… key")
            let quit = miItem(menu, "Quit Sesame")
            #expect(quit?.keyEquivalent == "q" && quit?.keyEquivalentModifierMask == .command, "\(name): Quit key")
        }
    }

    @Test func itemOrderAndLabelsEqualTheHandCopiedList() {
        for (name, model, lines) in miExpectedLists {
            #expect(miLines(miBuild(model)) == lines, "\(name): \(miLines(miBuild(model)))")
        }
    }

    @Test func theStatusLineComesFirstAndIsDisabled() {
        let firsts: [(String, MenuModel, String)] = [
            ("Indexing", miIndexing, "Indexing 62%"),
            ("Paused on battery", miPausedOnBattery, "Paused: on battery"),
            ("Not started", miNotStarted, "Indexing has not been started"),
            ("Failed", miFailed, "Model download failed"),
        ]
        for (name, model, text) in firsts {
            let first = miBuild(model).items.first
            #expect(first?.isSeparatorItem == false, "\(name): the menu starts with a separator")
            #expect(first?.title == text, "\(name): first item \(String(describing: first?.title))")
            #expect(first?.isEnabled == false, "\(name): the status line is enabled")
        }
    }

    @Test func onlyTheFirstItemHasACustomViewInAnyStateAndItIsTheHeader() {
        for (name, model) in miAllModels {
            let items = miBuild(model).items
            #expect(items.first?.view != nil, "\(name): the first item has no header view")
            for item in items.dropFirst() {
                #expect(item.view == nil, "\(name): \(item.title.debugDescription) has a custom view")
            }
        }
    }

    @Test func eachStateHasATemplateImageBetweenFourteenAndTwentyFourPoints() {
        for (name, state) in miStates {
            let image = StatusIcons.image(for: state)
            #expect(image.isTemplate, "\(name): not a template image")
            #expect((14...24).contains(image.size.width) && (14...24).contains(image.size.height), "\(name): size \(image.size)")
        }
    }

    @Test func eachStateKeepsItsVoiceOverLabelOnTheButton() {
        let rows: [(String, MenuModel, String)] = [
            ("Ready", miReady, "Sesame: ready"),
            ("Indexing", miIndexing, "Sesame: indexing, 62 percent"),
            ("Paused", miPausedByYou, "Sesame: paused"),
            ("Downloading", miDownloading, "Sesame: downloading the model, 34 percent"),
            ("Failed", miFailed, "Sesame: model download failed"),
        ]
        for (name, model, label) in rows {
            let host = MIFakeHost()
            let controller = MenuBarController(host: host, actions: miActions())
            controller.update(model)
            #expect(host.buttonAccessibilityLabel == label, "\(name): label \(host.buttonAccessibilityLabel.debugDescription)")
            #expect(host.buttonTitle == label, "\(name): title \(host.buttonTitle.debugDescription)")
            #expect(host.buttonImage?.isTemplate == true, "\(name): the button image is not a template")
        }
    }

    @Test func statusIconsSwiftHoldsNoColourLiteralAndDrawsWithTheTemplateInk() throws {
        let text = try miSourceText()
        let literals = [#"NSColor\.black"#, #"NSColor\.white"#, #"\.black\b"#, #"\.white\b"#, #"NSColor\("#]
        for pattern in literals {
            let regex = try NSRegularExpression(pattern: pattern)
            let hits = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            #expect(hits == 0, "StatusIcons.swift holds \(hits) match(es) of \(pattern)")
        }
        #expect(text.contains("Design.templateInk"), "StatusIcons.swift never names Design.templateInk")
        #expect(text.contains("Design.templateInk(alpha:"), "StatusIcons.swift never names the alpha form Design.templateInk(alpha:)")
    }

    @Test func everyStateStillDrawsItsShapesInBlackInk() throws {
        var opaque: [String: Int] = [:]
        for (name, state) in miStates {
            let ink = try #require(miInk(StatusIcons.image(for: state)), "\(name): no pixels")
            #expect(ink.opaque > 0, "\(name): no opaque pixel")
            #expect(ink.opaque * 2 < ink.total, "\(name): \(ink.opaque) of \(ink.total) pixels are opaque")
            #expect(ink.allBlack, "\(name): a pixel is not black ink")
            opaque[name] = ink.opaque
        }
        #expect((opaque["indexing"] ?? 0) > (opaque["ready"] ?? 0), "indexing \(String(describing: opaque["indexing"])), ready \(String(describing: opaque["ready"]))")
    }
}
