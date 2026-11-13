import AppKit
import CryptoKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

final class SLBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

enum SLState {
    case downloading
    case damaged
    case failed
    case whole
}

struct SLEnv {
    let home: URL
    var models: URL { home.appendingPathComponent("Library/Application Support/Sesame/models", isDirectory: true) }

    func fill(_ relative: String, photo: Int = 0, pdf: Int = 0, doc: Int = 0) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        func write(_ name: String) throws {
            try Data(repeating: 7, count: 32).write(to: url.appendingPathComponent(name))
        }
        for n in 0..<photo { try write("photo-\(n).\(n % 2 == 0 ? "jpg" : "png")") }
        for n in 0..<pdf { try write("paper-\(n).pdf") }
        for n in 0..<doc { try write("note-\(n).\(n % 2 == 0 ? "txt" : "md")") }
        return url
    }
}

struct SLRig {
    let window: SetupWindow
    let env: SLEnv
    let folders: SetupFolders
    let picks: SLBox<[URL]>
}

let slPaths: [Bool] = Glass.isAvailable ? [false, true] : [false]

@MainActor
func slIsGlass(_ view: NSView) -> Bool {
    NSStringFromClass(type(of: view)) == "NSGlassEffectView"
}

@MainActor
func slGlassViews(_ window: NSWindow) -> [NSView] {
    guard let content = window.contentView else { return [] }
    return prViews(content.superview ?? content).filter { slIsGlass($0) }
}

let slFailedMessage = "Could not download the model"
let slStepNames: [(step: SetupFlow.Step, label: String, heading: String)] = [
    (.welcome, "Step 1 of 4: Welcome", "Welcome to Sesame"),
    (.folders, "Step 2 of 4: Folders", "Folders to read"),
    (.permissions, "Step 3 of 4: Permissions", "Permissions"),
    (.shortcut, "Step 4 of 4: Shortcut", "Open Sesame from anywhere"),
]
private let slLongName = "Photos-from-the-summer-trip-to-the-coast"

@MainActor
private func slStatus() -> StatusCache {
    let sources = StatusSources(
        settings: { Settings() },
        counts: { IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 0) },
        meta: { _ in nil },
        modelState: { .whole })
    return StatusCache(sources: sources, queue: DispatchQueue(label: "sesame.setuplayout.test.status", qos: .utility))
}

@MainActor
private func slEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
func slWith(
    _ state: SLState,
    glass: Bool? = nil,
    settings: ((SLEnv) throws -> Settings)? = nil,
    counter: (@Sendable ([String]) -> FolderCounts)? = nil,
    onStarted: (@MainActor () -> Void)? = nil,
    _ body: @MainActor (SLRig) async throws -> Void
) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-setuplayout-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let env = SLEnv(home: base.resolvingSymlinksInPath())
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", env.home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: base)
    }
    _ = try SesameFolder.create()
    try fm.createDirectory(at: env.models, withIntermediateDirectories: true)

    let files: [ModelFile]
    if state == .whole {
        var seed: UInt64 = 300_000 &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var bytes = [UInt8](repeating: 0, count: 300_000)
        for index in 0..<bytes.count {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let data = Data(bytes)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try data.write(to: env.models.appendingPathComponent("sl-whole.gguf"))
        files = [ModelFile(name: "sl-whole.gguf", size: 300_000, sha256: hash)]
    } else {
        let first = ModelFile(name: "sl-a.gguf", size: 80_000_000, sha256: String(repeating: "0", count: 64))
        let second = ModelFile(name: "sl-b.gguf", size: 40_000_000, sha256: String(repeating: "0", count: 64))
        let partial = env.models.appendingPathComponent("sl-a.gguf.partial")
        fm.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        try handle.truncate(atOffset: 20_000_000)
        try handle.close()
        files = [first, second]
    }

    _ = try env.fill("Pictures", photo: 100)
    _ = try env.fill("Desktop", doc: 3)
    _ = try env.fill("Documents", pdf: 2)
    let picks = SLBox<[URL]>([])
    let whole = state == .whole
    if let settings { try SettingsFile().write(try settings(env)) }
    let folders: SetupFolders
    if let counter {
        folders = SetupFolders(
            home: env.home,
            counter: counter,
            picker: { picks.value },
            speeds: { ["photo": 3.0] },
            kindsOn: { ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true] },
            modelWhole: { whole })
    } else {
        folders = SetupFolders(
            home: env.home,
            picker: { picks.value },
            speeds: { ["photo": 3.0] },
            kindsOn: { ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true] },
            modelWhole: { whole })
        #expect(await slEventually { folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }, "the rows never became ready")
    }
    let client = HelperClient(helper: env.home.appendingPathComponent("no-such-helper"), textModel: env.home, mmModel: env.home)
    let window = SetupWindow(files: files, folders: folders, helper: client, status: slStatus(), onStarted: onStarted, glass: glass ?? Glass.isAvailable)
    window.isReleasedWhenClosed = false
    window.refresh()
    if state == .failed {
        window.model.downloadFailed(slFailedMessage)
        window.refresh()
    }
    if state == .damaged {
        window.model.modelWasDamaged()
        window.refresh()
    }
    try await body(SLRig(window: window, env: env, folders: folders, picks: picks))
}

@MainActor
func slLayout(_ rig: SLRig, _ look: DTLook = .light) -> NSView {
    rig.window.refresh()
    let root = rig.window.contentView!
    root.appearance = dtAppearance(look)
    root.layoutSubtreeIfNeeded()
    return root
}

@MainActor
func slWalk(_ rig: SLRig, to step: SetupFlow.Step) async {
    while rig.window.flow.step != step {
        let root = rig.window.contentView!
        guard let advance = [slButton(root, "Next"), slButton(root, "Not now")].compactMap({ $0 }).first(where: { $0.isEnabled }) else { return }
        advance.performClick(nil)
        await Task.yield()
    }
    rig.window.refresh()
}

@MainActor
func slButtons(_ root: NSView) -> [NSButton] {
    prViews(root).compactMap { $0 as? NSButton }.filter { plVisible($0) }
}

@MainActor
func slButton(_ root: NSView, _ title: String) -> NSButton? {
    slButtons(root).first { $0.title == title || $0.accessibilityLabel() == title }
}

@MainActor
private func slFolderChecks(_ root: NSView, _ env: SLEnv) -> [NSButton] {
    slButtons(root)
        .filter { ($0.accessibilityHelp() ?? "").hasPrefix(env.home.path) }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
func slAncestors(_ view: NSView) -> [NSView] {
    var out: [NSView] = []
    var current = view.superview
    while let next = current {
        out.append(next)
        current = next.superview
    }
    return out
}

@MainActor
func slCard(of view: NSView) -> GroupCard? {
    slAncestors(view).first { $0 is GroupCard } as? GroupCard
}

@MainActor
func slAlignBox(_ root: NSView, _ view: NSView) -> PLBox {
    guard let parent = view.superview else { return plBox(root, view) }
    let rect = root.convert(view.alignmentRect(forFrame: view.frame), from: parent)
    let top = root.isFlipped ? rect.minY : root.bounds.height - rect.maxY
    return PLBox(minX: rect.minX, maxX: rect.maxX, top: top, bottom: top + rect.height)
}

func slFont(_ font: NSFont?, size: CGFloat, weight: NSFont.Weight) -> Bool {
    guard let font else { return false }
    return abs(font.pointSize - size) < 0.01 && abs(dtWeight(font) - weight.rawValue) < 0.05
}

@MainActor
func slColour(_ color: NSColor?, is expected: NSColor) -> Bool {
    guard let color else { return false }
    return DTLook.allCases.allSatisfy { dtSame(dtRGBA(color, $0), dtRGBA(expected, $0)) }
}

struct SLStyle {
    let font: NSFont?
    let colour: NSColor?
    let box: PLBox
}

@MainActor
func slStyle(_ root: NSView, _ text: String) -> SLStyle? {
    if let field = plText(root, text) {
        return SLStyle(font: field.font, colour: field.textColor, box: plBox(root, field))
    }
    for view in prViews(root) {
        guard let textView = view as? NSTextView, plVisible(textView),
              let manager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage else { continue }
        let range = (textView.string as NSString).range(of: text)
        guard range.location != NSNotFound else { continue }
        let attributes = storage.attributes(at: range.location, effectiveRange: nil)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        let inRoot = root.convert(rect, from: textView)
        let top = root.isFlipped ? inRoot.minY : root.bounds.height - inRoot.maxY
        return SLStyle(
            font: attributes[.font] as? NSFont,
            colour: attributes[.foregroundColor] as? NSColor,
            box: PLBox(minX: inRoot.minX, maxX: inRoot.maxX, top: top, bottom: top + inRoot.height))
    }
    return nil
}

@MainActor
func slContentBottom(_ root: NSView) -> CGFloat? {
    let nav = ["Back", "Next", "Finish"].compactMap { slButton(root, $0) }
    let parts = prViews(root).filter { view in
        guard plVisible(view), view.frame.width > 0, view.frame.height > 0, !nav.contains(where: { $0 === view }) else { return false }
        if slAncestors(view).contains(where: { $0 is NSScrollView }) { return false }
        if let field = view as? NSTextField { return !field.stringValue.isEmpty }
        return view is NSImageView || view is NSProgressIndicator || view is FigureView || view is NSScrollView
            || view is GroupCard || view is NSButton
    }
    return parts.map { plBox(root, $0).bottom }.max()
}

@MainActor
func slInk(_ view: NSView, _ look: DTLook) -> (minX: CGFloat, maxX: CGFloat)? {
    view.appearance = dtAppearance(look)
    guard view.bounds.width > 0, view.bounds.height > 0,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    var low = Int.max
    var high = -1
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
            low = min(low, x)
            high = max(high, x)
        }
    }
    guard high >= 0 else { return nil }
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    return (CGFloat(low) / scale, CGFloat(high + 1) / scale)
}

@MainActor
func slKeyLoop(_ window: NSWindow) -> [NSView] {
    guard let start = window.initialFirstResponder else { return [] }
    var visited = [start]
    var next = start.nextValidKeyView
    while let current = next, current !== start, visited.count < 500 {
        visited.append(current)
        next = current.nextValidKeyView
    }
    return visited
}

@MainActor
private func slReturn(_ window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
}

extension ModelDownloadTests {
    @Suite("SetupLayoutTests", .serialized)
    struct SetupLayoutTests {

        @MainActor
        @Test(arguments: slPaths) func theWindowIs560By600WithTheTitleSetUpSesame(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                let size = rig.window.contentRect(forFrameRect: rig.window.frame).size
                #expect(size.width == 560 && size.height == 600, "content size \(size)")
                let root = slLayout(rig)
                #expect(root.bounds.size.width == 560 && root.bounds.size.height == 600, "content view \(root.bounds.size)")
                #expect(rig.window.title == "Set up Sesame")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func noStepDrawsAStepCaptionAndEachStepStillShowsItsTitle(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    for entry in slStepNames {
                        await slWalk(rig, to: entry.step)
                        for look in DTLook.allCases {
                            let root = slLayout(rig, look)
                            let captions = plTexts(root).filter { $0.stringValue.hasPrefix("Step ") }
                            #expect(captions.isEmpty, "\(state) / \(entry.label) \(look): a text field holds \(captions.map(\.stringValue))")
                            let views = prViews(root).compactMap { $0 as? NSTextView }.filter { plVisible($0) && $0.string.hasPrefix("Step ") }
                            #expect(views.isEmpty, "\(state) / \(entry.label) \(look): a text view starts with Step")
                            #expect(slStyle(root, entry.heading) != nil, "\(state) / \(entry.label): no title \"\(entry.heading)\"")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theFooterIsOneRowBackAtTheLeftAndNextOrFinishAtTheRightTwentyFromTheBottom(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for entry in slStepNames {
                    await slWalk(rig, to: entry.step)
                    let root = slLayout(rig)
                    let primaryTitle = entry.step == .shortcut ? "Finish" : entry.step == .folders ? "Start indexing" : "Next"
                    let otherTitle = entry.step == .shortcut ? "Next" : "Finish"
                    let primary = slButton(root, primaryTitle)
                    #expect(primary != nil, "\(entry.label): no visible \(primaryTitle)")
                    #expect(slButton(root, otherTitle) == nil, "\(entry.label): \(otherTitle) is visible")
                    if entry.step == .folders { #expect(slButton(root, "Next") == nil, "\(entry.label): Next is visible beside Start indexing") }
                    if entry.step != .folders { #expect(slButton(root, "Start indexing") == nil, "\(entry.label): Start indexing is visible") }
                    let back = slButton(root, "Back")
                    if entry.step != .welcome { #expect(back != nil, "\(entry.label): no visible Back") }
                    if entry.step == .welcome { #expect(back == nil, "\(entry.label): Back is visible on the first step") }
                    guard let primary else { continue }
                    #expect(primary.keyEquivalent == "\r", "\(entry.label): \(primaryTitle) key equivalent \(primary.keyEquivalent.debugDescription)")
                    let primaryFrame = plBox(root, primary)
                    let primaryAlign = slAlignBox(root, primary)
                    let groups = prViews(root).compactMap { $0 as? StepDots }.filter { plVisible($0) }
                    #expect(groups.count == 1, "\(entry.label): \(groups.count) step dots groups")
                    if let dots = groups.first {
                        #expect(dots.accessibilityTitle() == entry.label, "\(entry.label): dots title \(String(describing: dots.accessibilityTitle()))")
                        let circles = prViews(dots).filter { $0.layer?.cornerRadius == 4 }
                        #expect(circles.count == 4, "\(entry.label): \(circles.count) dots")
                        if let first = circles.first {
                            let span = circles.dropFirst().reduce(plBox(root, first)) { $0.union(plBox(root, $1)) }
                            #expect(abs(span.midX - 280) <= 8, "\(entry.label): dots centre \(span.midX), window centre 280")
                            let dotsMid = (span.top + span.bottom) / 2
                            let nextMid = (primaryFrame.top + primaryFrame.bottom) / 2
                            let nextAlignMid = (primaryAlign.top + primaryAlign.bottom) / 2
                            #expect(abs(dotsMid - nextMid) <= 2 || abs(dotsMid - nextAlignMid) <= 2, "\(entry.label): dots row \(dotsMid), \(primaryTitle) row \(nextMid) / \(nextAlignMid)")
                            #expect(span.maxX <= primaryFrame.minX, "\(entry.label): the dots reach \(span.maxX), \(primaryTitle) starts at \(primaryFrame.minX)")
                            if let back { #expect(plBox(root, back).maxX <= span.minX, "\(entry.label): Back ends at \(plBox(root, back).maxX), the dots start at \(span.minX)") }
                        }
                    }
                    #expect(abs(primaryFrame.maxX - 540) <= 3 || abs(primaryAlign.maxX - 540) <= 3, "\(entry.label): right edge \(primaryFrame.maxX) / \(primaryAlign.maxX)")
                    #expect(abs((600 - primaryFrame.bottom) - 20) <= 2 || abs((600 - primaryAlign.bottom) - 20) <= 2,
                            "\(entry.label): bottom gap \(600 - primaryFrame.bottom) / \(600 - primaryAlign.bottom)")
                    guard let back else { continue }
                    #expect(back.keyEquivalent.isEmpty, "\(entry.label): Back key equivalent \(back.keyEquivalent.debugDescription)")
                    let backFrame = plBox(root, back)
                    let backAlign = slAlignBox(root, back)
                    #expect(abs(backFrame.minX - 20) <= 3 || abs(backAlign.minX - 20) <= 3, "\(entry.label): Back left edge \(backFrame.minX) / \(backAlign.minX)")
                    #expect(abs((600 - backFrame.bottom) - 20) <= 2 || abs((600 - backAlign.bottom) - 20) <= 2,
                            "\(entry.label): Back bottom gap \(600 - backFrame.bottom) / \(600 - backAlign.bottom)")
                    #expect(abs((backFrame.top + backFrame.bottom) / 2 - (primaryFrame.top + primaryFrame.bottom) / 2) <= 1, "\(entry.label): Back and \(primaryTitle) are not in one row")
                    #expect(backFrame.maxX < primaryFrame.minX, "\(entry.label): Back is not left of \(primaryTitle)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func onTheWelcomeAndShortcutStepsNoMoreThan24PointsAreBlankBetweenTheContentAndTheFooter(glass: Bool) async throws {
            for started in [false, true] {
              let seeded: ((SLEnv) throws -> Settings)? = started ? { _ in
                  var held = Settings()
                  held.startPressed = true
                  return held
              } : nil
              try await slWith(.whole, glass: glass, settings: seeded) { rig in
                for entry in slStepNames where entry.step == .welcome || entry.step == .shortcut {
                    if started && entry.step == .welcome { continue }
                    await slWalk(rig, to: entry.step)
                    let root = slLayout(rig)
                    let nav = ["Back", "Next", "Finish"].compactMap { slButton(root, $0) }
                    #expect(!nav.isEmpty, "\(entry.label): no footer button")
                    for button in nav {
                        let frame = plBox(root, button)
                        let align = slAlignBox(root, button)
                        #expect(abs((600 - frame.bottom) - 20) <= 2 || abs((600 - align.bottom) - 20) <= 2,
                                "\(entry.label): \(button.title) is \(600 - frame.bottom) pt from the bottom, not pinned at 20")
                    }
                    let footerTop = nav.map { plBox(root, $0).top }.min() ?? 0
                    let contentBottom = slContentBottom(root)
                    #expect(contentBottom != nil, "\(entry.label): no content")
                    guard let contentBottom else { continue }
                    #expect(contentBottom <= footerTop + 0.5, "\(entry.label): content ends at \(contentBottom), below the footer top \(footerTop)")
                    #expect(footerTop - contentBottom <= 24.5, "\(entry.label): \(footerTop - contentBottom) pt blank above the footer")
                    let ready = plText(root, "Search model ready")
                    if entry.step == .welcome {
                        #expect(ready != nil, "\(entry.label): no status line")
                        if let ready { #expect(abs(plBox(root, ready).bottom - contentBottom) <= 3, "\(entry.label): the lowest content ends at \(contentBottom), the status line at \(plBox(root, ready).bottom)") }
                    } else {
                        #expect(ready == nil, "\(entry.label): the status line is shown")
                        let note = plText(root, "You can change the shortcut later in Settings.")
                        let running = plText(root, "Indexing is running. Watch it from the magnifier in the menu bar.")
                        #expect(note != nil, "\(entry.label): no note")
                        #expect((running != nil) == started, "started \(started): the running line is shown \(running != nil)")
                        if let lowest = started ? running : note {
                            #expect(abs(plBox(root, lowest).bottom - contentBottom) <= 3, "started \(started) \(entry.label): the lowest content ends at \(contentBottom), the lowest of the note and the running line at \(plBox(root, lowest).bottom)")
                            #expect(footerTop - plBox(root, lowest).bottom >= 15.5, "started \(started) \(entry.label): the lowest of the note and the running line ends \(footerTop - plBox(root, lowest).bottom) pt above the footer, wanted 16 to 24")
                        }
                    }
                    #expect(slStyle(root, "The search model") == nil, "\(entry.label): the model card heading is shown for a whole model")
                }
              }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theFoldersListSitsFlippedInOneGroupCardAndScrollsOnlyInsideIt(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                let long = try rig.env.fill(slLongName, photo: 3)
                #expect(slLongName.count == 40)
                await slWalk(rig, to: .folders)
                rig.picks.value = [long]
                var root = slLayout(rig)
                let add = try #require(slButton(root, "Add folder\u{2026}"), "no Add folder button")
                add.performClick(nil)
                #expect(await slEventually { rig.folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } })
                root = slLayout(rig)

                let checks = slFolderChecks(root, rig.env)
                #expect(checks.count == 6, "\(checks.count) folder rows: \(checks.map { $0.title })")
                guard let first = checks.first else { return }
                let card = try #require(slCard(of: first), "the first row is in no GroupCard")
                for check in checks { #expect(slCard(of: check) === card, "\(check.title) is in another card") }
                let cardBox = plBox(root, card)
                #expect(abs(cardBox.minX - 20) <= 1 && abs(cardBox.maxX - 540) <= 1, "card spans \(cardBox.minX) to \(cardBox.maxX)")

                let order = rig.window.setupScreen.rows.map(\.name)
                #expect(checks.map { $0.title } == order, "drawn order \(checks.map { $0.title }), rows \(order)")
                let tops = checks.map { plBox(root, $0).top }
                #expect(zip(tops, tops.dropFirst()).allSatisfy { $0 < $1 }, "tops not increasing: \(tops)")
                let gap = tops[0] - cardBox.top
                #expect(gap >= 0 && gap <= 16, "the first row starts \(gap) pt below the top of the card")
                for scroll in slAncestors(first).compactMap({ $0 as? NSScrollView }) {
                    #expect(scroll.documentView?.isFlipped == true, "a scroll view holds the rows in a document view that is not flipped")
                }

                let scrolls = prViews(root).compactMap { $0 as? NSScrollView }.filter { plVisible($0) }
                for scroll in scrolls {
                    #expect(slAncestors(scroll).contains { $0 === card }, "a visible scroll view is outside the card")
                    #expect(scroll.borderType == .noBorder, "the scroll view has a bezel border")
                }
                #expect(!slAncestors(card).contains { $0 is NSScrollView }, "the card sits inside a scroll view")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func eachFolderRowIsACheckboxButtonWideEnoughForItsTitleBesideASecondaryCount(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                let long = try rig.env.fill(slLongName, photo: 3)
                await slWalk(rig, to: .folders)
                rig.picks.value = [long]
                var root = slLayout(rig)
                slButton(root, "Add folder\u{2026}")?.performClick(nil)
                #expect(await slEventually { rig.folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } })
                for look in DTLook.allCases {
                    root = slLayout(rig, look)
                    #expect(!prViews(root).contains { $0 is NSSwitch }, "an NSSwitch is in the window")
                    let reference = NSButton()
                    reference.setButtonType(.switch)
                    let checks = slFolderChecks(root, rig.env)
                    #expect(checks.count == 6, "\(checks.count) folder rows")
                    for check in checks {
                        #expect(check is SetupButton, "\(check.title) is not a SetupButton")
                        let cell = check.cell as? NSButtonCell
                        let want = reference.cell as? NSButtonCell
                        #expect(cell?.showsStateBy == want?.showsStateBy && cell?.highlightsBy == want?.highlightsBy
                                && cell?.isBordered == want?.isBordered && cell?.bezelStyle == want?.bezelStyle,
                                "\(check.title) is not a switch-type button")
                        let box = plBox(root, check)
                        let titleWidth = (check.title as NSString).size(withAttributes: [.font: check.font ?? NSFont.systemFont(ofSize: 13)]).width
                        #expect(check.frame.width >= titleWidth + 14, "\(check.title): \(check.frame.width) pt wide for \(titleWidth) pt of title")
                        #expect(check.frame.width + 0.5 >= check.fittingSize.width, "\(check.title): \(check.frame.width) pt wide, fits \(check.fittingSize.width)")
                        if let card = slCard(of: check) { #expect(box.maxX <= plBox(root, card).maxX, "\(check.title) leaves the card") }
                    }
                    let long = try #require(checks.first { $0.title == slLongName }, "no row named \(slLongName)")
                    #expect(long.frame.width >= (slLongName as NSString).size(withAttributes: [.font: long.font ?? NSFont.systemFont(ofSize: 13)]).width + 14)

                    let pictures = try #require(checks.first { $0.title == "Pictures" }, "no Pictures row")
                    #expect(plText(root, "100 photos, about 5 min") == nil, "the old detail text is still on screen")
                    let picturesBox = plBox(root, pictures)
                    let counts = plTexts(root).filter { field in
                        let box = plBox(root, field)
                        return abs((box.top + box.bottom) / 2 - (picturesBox.top + picturesBox.bottom) / 2) <= 6 && box.minX >= picturesBox.maxX - 0.5
                    }
                    #expect(counts.map(\.stringValue) == ["100"], "texts right of Pictures on its row: \(counts.map(\.stringValue))")
                    let count = try #require(counts.first, "no count text for Pictures")
                    let countBox = plBox(root, count)
                    #expect(countBox.minX >= picturesBox.maxX - 0.5, "the count starts at \(countBox.minX), the checkbox ends at \(picturesBox.maxX)")
                    #expect(abs((countBox.top + countBox.bottom) / 2 - (picturesBox.top + picturesBox.bottom) / 2) <= 4, "the count is not on the row")
                    #expect(slFont(count.font, size: 12, weight: .regular), "count font \(String(describing: count.font))")
                    #expect(slColour(count.textColor, is: .secondaryLabelColor), "count colour \(look)")
                    #expect(!count.isAccessibilityElement(), "the count is an accessibility element")
                    if let card = slCard(of: pictures) {
                        let ink = slInk(count, look)
                        #expect(ink != nil && (ink?.maxX ?? 0) >= count.bounds.width - 4, "the count is not drawn against its right edge: \(String(describing: ink)) of \(count.bounds.width)")
                        #expect(countBox.maxX <= plBox(root, card).maxX, "the count leaves the card")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theFoldersStepKeepsItsTotalAndReadNoteNoOtherStepShowsThemAndNoStepShowsThePerPhotoSpeedNote(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                let lines = ["About 5 min in total", "Photos, PDFs, documents, audio and video are read."]
                for entry in slStepNames {
                    await slWalk(rig, to: entry.step)
                    let root = slLayout(rig)
                    for line in lines {
                        #expect((plText(root, line) != nil) == (entry.step == .folders), "\(entry.label): \"\(line)\" visible \(plText(root, line) != nil)")
                    }
                    #expect(plText(root, "Photos: about 3 s each") == nil, "\(entry.label): the per-photo speed note is on screen")
                    #expect(!prShownTexts(root).contains { $0.hasPrefix("Photos: about") }, "\(entry.label): a text starts with \"Photos: about\"")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func addFolderAndNotNowAreBothBorderlessSetupButtonsWithNoBezelColourOrKeyEquivalentAndAddFolderIsAboveNotNow(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let add = try #require(slButton(root, "Add folder\u{2026}"), "no Add folder button")
                    let notNow = try #require(slButton(root, "Not now"), "no Not now button")
                    #expect(add is SetupButton && notNow is SetupButton)
                    #expect(!add.isBordered, "Add folder is bordered")
                    #expect(!notNow.isBordered, "Not now is bordered")
                    #expect(add.bezelStyle.rawValue != 16 && notNow.bezelStyle.rawValue != 16, "a glass bezel on Add folder or Not now")
                    #expect(add.keyEquivalent.isEmpty && notNow.keyEquivalent.isEmpty, "key equivalents \(add.keyEquivalent.debugDescription) \(notNow.keyEquivalent.debugDescription)")
                    #expect(add.bezelColor == nil, "Add folder carries a bezel colour")
                    #expect(notNow.bezelColor == nil, "Not now carries a bezel colour \(String(describing: notNow.bezelColor)) \(look)")
                    let addBox = plBox(root, add)
                    let notNowBox = plBox(root, notNow)
                    #expect(addBox.bottom <= notNowBox.top + 0.5, "Add folder ends at \(addBox.bottom), Not now starts at \(notNowBox.top)")
                    #expect(!addBox.intersects(notNowBox), "the two buttons overlap")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theModelCardHoldsTheHeadingTheDeterminateBarAndTheFigureAtOneRightEdgeOnEveryStep(glass: Bool) async throws {
            try await slWith(.downloading, glass: glass) { rig in
                for entry in slStepNames {
                    await slWalk(rig, to: entry.step)
                    let root = slLayout(rig)
                    let heading = try #require(slStyle(root, "The search model"), "\(entry.label): no model heading")
                    #expect(slFont(heading.font, size: 13, weight: .semibold), "\(entry.label): heading font \(String(describing: heading.font))")
                    #expect(plText(root, "Search model ready") == nil, "\(entry.label): the ready line is shown beside the model card")
                    let bars = prViews(root).compactMap { $0 as? NSProgressIndicator }.filter { plVisible($0) }
                    #expect(bars.count == 1, "\(entry.label): \(bars.count) progress bars")
                    let figures = prViews(root).compactMap { $0 as? FigureView }.filter { plVisible($0) }
                    #expect(figures.count == 1, "\(entry.label): \(figures.count) figure views")
                    guard let bar = bars.first, let figure = figures.first else { continue }
                    #expect(!bar.isIndeterminate && bar.style == .bar && bar.controlSize == .small, "\(entry.label): bar is not a small determinate bar")
                    #expect(!bar.isAccessibilityElement(), "\(entry.label): the bar is an accessibility element")
                    let fraction = (bar.doubleValue - bar.minValue) / (bar.maxValue - bar.minValue)
                    #expect(abs(fraction - 20.0 / 120.0) <= 0.01, "\(entry.label): bar at \(fraction)")
                    #expect(figure.isAccessibilityElement() && figure.accessibilityTitle() == "Model download" && figure.accessibilityRole() == .group)
                    #expect(figure.accessibilityValue() as? String == "20 of 120 MB", "\(entry.label): figure value \(String(describing: figure.accessibilityValue()))")
                    let card = try #require(slCard(of: bar), "\(entry.label): the bar is in no GroupCard")
                    #expect(slCard(of: figure) === card, "\(entry.label): the figure is in another card")
                    #expect(plTexts(card).contains { $0.stringValue == "The search model" }, "\(entry.label): the heading is not in the card")
                    #expect(abs(plBox(root, figure).maxX - plBox(root, bar).maxX) <= 1, "\(entry.label): figure right edge \(plBox(root, figure).maxX), bar right edge \(plBox(root, bar).maxX)")
                    #expect(slButton(root, "Retry") == nil, "\(entry.label): Retry is shown without a failure")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theFigureTextIsDrawnAgainstTheRightEdge(glass: Bool) async throws {
            try await slWith(.downloading, glass: glass) { rig in
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let figure = try #require(prViews(root).compactMap { $0 as? FigureView }.first { plVisible($0) }, "no figure view")
                    let width = figure.bounds.width
                    #expect(width > 0, "the figure view has no width")
                    let ink = slInk(figure, look)
                    #expect(ink != nil, "nothing is drawn in the figure view")
                    guard let ink else { continue }
                    #expect(ink.maxX >= width - 4, "\(look): the text ends at \(ink.maxX) of \(width)")
                    #expect(ink.minX > 0, "\(look): the text starts at \(ink.minX)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aWholeModelShowsTheReadyLineAndNoBarFigureOrRetry(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for entry in slStepNames {
                    await slWalk(rig, to: entry.step)
                    let root = slLayout(rig)
                    #expect(slStyle(root, "The search model") == nil, "\(entry.label): the model card heading is shown for a whole model")
                    if entry.step == .welcome {
                        #expect(plText(root, "Search model ready") != nil, "\(entry.label): no ready line")
                    } else {
                        #expect(plText(root, "Search model ready") == nil, "\(entry.label): the ready line is shown")
                    }
                    #expect(plText(root, "The model is ready.") == nil, "\(entry.label): the old ready line is shown")
                    #expect(!prViews(root).contains { ($0 is NSProgressIndicator || $0 is FigureView) && plVisible($0) }, "\(entry.label): a bar or figure is shown")
                    #expect(slButton(root, "Retry") == nil, "\(entry.label): Retry is shown")
                    #expect(plAccessibilityImages(root).filter { plVisible($0) }.isEmpty, "\(entry.label): an accessibility image is shown")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aFailedDownloadShowsRetryAndTheFailureLineWithTheWarningSymbolAndItsNextStep(glass: Bool) async throws {
            try await slWith(.failed, glass: glass) { rig in
                for entry in slStepNames {
                    await slWalk(rig, to: entry.step)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let retry = slButton(root, "Retry")
                        #expect(retry != nil && retry?.isEnabled == true, "\(entry.label): no enabled Retry")
                        let failure = try #require(plText(root, slFailedMessage), "\(entry.label): no failure text")
                        #expect(slColour(failure.textColor, is: .systemRed), "\(entry.label): failure colour \(look)")
                        #expect(plText(root, "Try again in a moment.") != nil, "\(entry.label): no next-step line")
                        let images = plAccessibilityImages(root).filter { plVisible($0) }
                        #expect(images.count == 1, "\(entry.label): \(images.count) accessibility images")
                        guard let warning = images.first as? NSImageView else { continue }
                        #expect(warning.accessibilityLabel() == "Warning")
                        #expect(warning.image?.description.contains("symbol = exclamationmark.triangle") == true, "symbol \(warning.image?.description ?? "nil")")
                        #expect(slColour(warning.contentTintColor, is: .systemRed), "\(entry.label): symbol tint \(look)")
                        let symbolBox = plBox(root, warning)
                        let textBox = plBox(root, failure)
                        let gapX = max(0, max(symbolBox.minX, textBox.minX) - min(symbolBox.maxX, textBox.maxX))
                        let gapY = max(0, max(symbolBox.top, textBox.top) - min(symbolBox.bottom, textBox.bottom))
                        #expect(gapX <= 12 && gapY <= 12, "\(entry.label): the symbol is \(gapX) across and \(gapY) down from the failure text")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aDownloadThatHasNotFailedShowsNeitherTheWarningNorTheNextStepLine(glass: Bool) async throws {
            try await slWith(.downloading, glass: glass) { rig in
                let root = slLayout(rig)
                #expect(plAccessibilityImages(root).filter { plVisible($0) }.isEmpty, "an accessibility image is shown while downloading")
                #expect(plText(root, "Try again in a moment.") == nil)
                #expect(plText(root, slFailedMessage) == nil)
            }
        }

        @MainActor
        @Test(arguments: slPaths) func thePermissionsStepIsACardOfFourRowsEachAFolderNameAndOneSecondaryLineWithNoBullets(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .permissions)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    #expect(!prShownTexts(root).contains { $0.contains("\u{2022}") }, "a bullet character is shown: \(prShownTexts(root))")
                    let names = ["Desktop", "Documents", "Downloads", "Removable volumes"]
                    let lines = ["Files on your Desktop", "Files in your Documents folder", "Files in your Downloads folder", "USB drives and external disks"]
                    let first = try #require(plText(root, "Desktop"), "no Desktop name")
                    let card = try #require(slCard(of: first), "Desktop is in no GroupCard")
                    #expect(plTexts(card).first { $0.stringValue == "The search model" } == nil, "the permissions card is the model card")
                    let cardBox = plBox(root, card)
                    #expect(abs(cardBox.minX - 20) <= 1 && abs(cardBox.maxX - 540) <= 1, "card spans \(cardBox.minX) to \(cardBox.maxX)")
                    let nameFields = names.compactMap { name in plTexts(card).first { $0.stringValue == name } }
                    let lineFields = lines.compactMap { line in plTexts(card).first { $0.stringValue == line } }
                    #expect(nameFields.count == 4 && lineFields.count == 4, "\(nameFields.count) names and \(lineFields.count) lines in the card: \(plTexts(card).map(\.stringValue))")
                    #expect(plTexts(card).count == 8, "\(plTexts(card).count) texts in the card: \(plTexts(card).map(\.stringValue))")
                    for (index, name) in names.enumerated() where index < nameFields.count && index < lineFields.count {
                        let nameField = nameFields[index]
                        let lineField = lineFields[index]
                        #expect(slFont(nameField.font, size: 13, weight: .semibold), "\(name) name font \(String(describing: nameField.font))")
                        #expect(slFont(lineField.font, size: 12, weight: .regular), "\(name) line font \(String(describing: lineField.font))")
                        #expect(slColour(lineField.textColor, is: .secondaryLabelColor), "\(name) line colour \(look)")
                        #expect(plBox(root, nameField).bottom <= plBox(root, lineField).top + 0.5, "\(name): the line is not under the name")
                        #expect(!plBox(root, nameField).intersects(plBox(root, lineField)), "\(name): the two texts overlap")
                        if index > 0 { #expect(plBox(root, nameFields[index - 1]).top < plBox(root, nameField).top, "\(name): the rows are not in order") }
                    }
                    let never = slStyle(root, "Sesame never asks for Full Disk Access, camera or microphone.")
                    #expect(never != nil, "the never-asked line is missing")
                    if let never {
                        #expect(slFont(never.font, size: 12, weight: .regular), "never-asked font \(String(describing: never.font))")
                        #expect(slColour(never.colour, is: .secondaryLabelColor))
                        #expect(never.box.top >= cardBox.bottom - 1, "the never-asked line is above the card")
                    }
                    #expect(slStyle(root, "macOS asks once, the first time Sesame reads each of these:") != nil, "the intro is missing")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theShortcutStepHasNoFigureTypeShortcutTextAndNoCardWithAWholeModelAndStillShowsTheNote(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .shortcut)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let figures = plTexts(root).filter { slFont($0.font, size: 22, weight: .semibold) }
                    #expect(figures.isEmpty, "\(look): figure-type texts \(figures.map(\.stringValue))")
                    #expect(plText(root, "Control Option Space") == nil, "\(look): the shortcut is still a text")
                    #expect(!prViews(root).contains { $0 is GroupCard && plVisible($0) }, "\(look): a card is shown")
                    #expect(slStyle(root, "You can change the shortcut later in Settings.") != nil, "\(look): the note is missing")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func everyButtonOnEveryStepStaysASetupButtonAndTheKeyLoopReachesEachEnabledOne(glass: Bool) async throws {
            for state in [SLState.downloading, SLState.failed, SLState.whole] {
                try await slWith(state, glass: glass) { rig in
                    for entry in slStepNames {
                        await slWalk(rig, to: entry.step)
                        let root = slLayout(rig)
                        let buttons = slButtons(root)
                        #expect(!buttons.isEmpty, "\(state) / \(entry.label): no buttons")
                        let loop = slKeyLoop(rig.window)
                        #expect(!loop.isEmpty, "\(state) / \(entry.label): no initialFirstResponder")
                        if entry.step == .welcome {
                            let next = slButton(root, "Next")
                            if state != .failed {
                                #expect(next != nil && loop.first === next, "\(state) / \(entry.label): the key loop starts at \(String(describing: loop.first)), not at Next")
                            }
                            #expect(!loop.contains { $0 is NSTextView }, "\(state) / \(entry.label): a text view is a key loop stop")
                        }
                        for button in buttons {
                            #expect(button is SetupButton, "\(state) / \(entry.label): \"\(button.title)\" is not a SetupButton")
                            if button.isEnabled {
                                #expect(loop.contains { $0 === button }, "\(state) / \(entry.label): \"\(button.title)\" is not in the key loop")
                            }
                        }
                        if entry.step == .folders {
                            let others = buttons.filter { !($0.accessibilityHelp() ?? "").hasPrefix(rig.env.home.path) }.map(\.title).sorted()
                            let wanted: [String]
                            switch state {
                            case .whole: wanted = ["Add folder\u{2026}", "Back", "Not now", "Start indexing"]
                            case .failed: wanted = ["Add folder\u{2026}", "Back", "Next", "Retry"]
                            default: wanted = ["Add folder\u{2026}", "Back", "Next"]
                            }
                            #expect(others == wanted, "\(state) / \(entry.label): the buttons besides the rows are \(others), wanted \(wanted)")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func returnOnWelcomePressesNextWithNoTextViewToFocusAndReturnOnShortcutPressesFinish(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                let root = slLayout(rig)
                #expect(!prViews(root).contains { $0 is NSTextView && plVisible($0) }, "a text view is shown on Welcome")
                let next = slButton(root, "Next")
                #expect(next != nil && rig.window.initialFirstResponder === next, "initialFirstResponder is \(String(describing: rig.window.initialFirstResponder)), not Next")
                let handledOnWelcome = rig.window.performKeyEquivalent(with: slReturn(rig.window))
                #expect(handledOnWelcome, "Return was not handled on Welcome")
                let step = rig.window.flow.step.title
                #expect(step == "Folders", "Return left the window on \(step)")

                await slWalk(rig, to: .shortcut)
                _ = slLayout(rig)
                let closed = SLBox<Bool>(false)
                let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: rig.window, queue: .main) { _ in
                    closed.value = true
                }
                defer { NotificationCenter.default.removeObserver(token) }
                let handledOnShortcut = rig.window.performKeyEquivalent(with: slReturn(rig.window))
                #expect(handledOnShortcut, "Return was not handled on Shortcut")
                let didClose = await slEventually(3) { closed.value }
                #expect(didClose, "Return did not finish setup")
            }
        }
    }
}
