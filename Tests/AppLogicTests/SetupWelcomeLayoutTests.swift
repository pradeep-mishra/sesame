import AppKit
import Foundation
import Testing
@testable import Sesame

private let swlTitle = "Welcome to Sesame"
private let swlSubline = "Search your files by what is inside them."
private let swlReady = "Search model ready"
private let swlDamaged = "The model file was damaged, so it was deleted. Downloading it again."
private let swlPromises: [(symbol: String, title: String, detail: String)] = [
    ("doc.text", "Search by meaning", "Type what a photo shows or what a document says."),
    ("lock", "Private by design", "Everything stays on this Mac."),
    ("play.circle", "You choose when", "Nothing is read until you press Start indexing."),
]

func swlSymbolName(_ image: NSImage?) -> String? {
    guard let description = image?.description, let range = description.range(of: "symbol = ") else { return nil }
    let name = String(description[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "." })
    return name == "text.document" ? "doc.text" : name
}

func swlSymbolHeights(_ name: String, _ point: CGFloat) -> ClosedRange<CGFloat> {
    let weights: [NSFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
    let heights = weights.compactMap {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: point, weight: $0))?.size.height
    }
    return ((heights.min() ?? 0) - 0.5)...((heights.max() ?? 0) + 0.5)
}

@MainActor
func swlImages(_ root: NSView, _ name: String) -> [NSImageView] {
    prViews(root).compactMap { $0 as? NSImageView }.filter { plVisible($0) && swlSymbolName($0.image) == name }
}

@MainActor
func swlTexts(_ root: NSView, _ text: String) -> [NSTextField] {
    plTexts(root).filter { $0.stringValue == text }
}

private struct SWLRow {
    let symbol: NSImageView
    let title: NSTextField
    let detail: NSTextField
    var views: [NSView] { [symbol, title, detail] }
}

@MainActor
private func swlRows(_ root: NSView) -> [SWLRow]? {
    var rows: [SWLRow] = []
    for promise in swlPromises {
        let symbols = swlImages(root, promise.symbol)
        let titles = swlTexts(root, promise.title)
        let details = swlTexts(root, promise.detail)
        guard symbols.count == 1, titles.count == 1, details.count == 1 else { return nil }
        rows.append(SWLRow(symbol: symbols[0], title: titles[0], detail: details[0]))
    }
    return rows
}

struct SWLGap {
    let frame: CGFloat
    let aligned: CGFloat

    func near(_ target: CGFloat, _ tolerance: CGFloat = 2) -> Bool {
        abs(frame - target) <= tolerance || abs(aligned - target) <= tolerance
    }
}

@MainActor
func swlGap(_ root: NSView, upper: [NSView], lower: [NSView]) -> SWLGap {
    let frame = (lower.map { plBox(root, $0).top }.min() ?? 0) - (upper.map { plBox(root, $0).bottom }.max() ?? 0)
    let aligned = (lower.map { slAlignBox(root, $0).top }.min() ?? 0) - (upper.map { slAlignBox(root, $0).bottom }.max() ?? 0)
    return SWLGap(frame: frame, aligned: aligned)
}

@MainActor
func swlNav(_ root: NSView) -> [NSView] {
    ["Back", "Next", "Start indexing", "Finish"].compactMap { slButton(root, $0) }
}

@MainActor
func swlUnion(_ root: NSView, _ views: [NSView]) -> PLBox? {
    guard let first = views.first else { return nil }
    return views.dropFirst().reduce(plBox(root, first)) { $0.union(plBox(root, $1)) }
}

@MainActor
func swlInkMid(_ root: NSView, _ view: NSView, _ look: DTLook) -> CGFloat? {
    guard let ink = slInk(view, look) else { return nil }
    return plBox(root, view).minX + (ink.minX + ink.maxX) / 2
}

@MainActor
private func swlLayerColour(_ color: CGColor?, is expected: [CGFloat]) -> Bool {
    guard let actual = dtRGBA(cgColor: color) else { return false }
    return dtSame(actual, expected)
}

@MainActor
private func swlHasGradient(_ layer: CALayer?) -> Bool {
    guard let layer else { return false }
    if layer is CAGradientLayer { return true }
    if layer.delegate is NSProgressIndicator { return false }
    return (layer.sublayers ?? []).contains { swlHasGradient($0) }
}

@MainActor
func swlPaletteViolations(_ root: NSView, _ look: DTLook, allowError: Bool, glass: Bool) -> [String] {
    var found: [String] = []
    let plain: [NSColor] = [.labelColor, .secondaryLabelColor, .tertiaryLabelColor]
    let errorTexts = [slFailedMessage, "Try again in a moment."]
    var accentLayers = 0
    var tertiaryLayers = 0
    for view in prViews(root) where plVisible(view) {
        if slIsGlass(view) {
            if !glass { found.append("an NSGlassEffectView on the flat path") }
            continue
        }
        if slAncestors(view).contains(where: { slIsGlass($0) }) { continue }
        if view is NSVisualEffectView { found.append("an NSVisualEffectView") }
        if swlHasGradient(view.layer) { found.append("a gradient layer under \(type(of: view))") }
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            let isError = allowError && errorTexts.contains(field.stringValue) && slColour(field.textColor, is: .systemRed)
            if !isError && !plain.contains(where: { slColour(field.textColor, is: $0) }) {
                found.append("text \"\(field.stringValue)\" has an off-palette colour")
            }
        }
        if let image = view as? NSImageView, let tint = image.contentTintColor {
            let isWarning = allowError && image.accessibilityLabel() == "Warning" && slColour(tint, is: .systemRed)
            if !isWarning && !plain.contains(where: { slColour(tint, is: $0) }) {
                found.append("image \(swlSymbolName(image.image) ?? "?") has an off-palette tint")
            }
        }
        if let button = view as? NSButton, let bezel = button.bezelColor {
            let primary = button.title == "Next" || button.title == "Start indexing" || button.title == "Finish"
            if !(primary && slColour(bezel, is: .controlAccentColor)) { found.append("button \"\(button.title)\" has a bezel colour") }
        }
        if let color = view.layer?.backgroundColor, (color.alpha > 0.001) {
            let insideDots = slAncestors(view).contains { $0 is StepDots } || view is StepDots
            if insideDots {
                if swlLayerColour(color, is: dtRGBA(.controlAccentColor, look)) { accentLayers += 1 }
                else if swlLayerColour(color, is: dtRGBA(.tertiaryLabelColor, look)) { tertiaryLayers += 1 }
                else { found.append("a dot layer has an off-palette fill") }
            } else {
                var fill = dtRGBA(.labelColor, look)
                fill[3] = 0.05
                let allowed = swlLayerColour(color, is: fill) || swlLayerColour(color, is: dtRGBA(.separatorColor, look))
                if !allowed { found.append("a \(type(of: view)) layer has an off-palette fill") }
            }
        }
    }
    if accentLayers != 1 { found.append("\(accentLayers) accent dots, wanted 1") }
    if tertiaryLayers != 3 { found.append("\(tertiaryLayers) tertiary dots, wanted 3") }
    return found
}

extension ModelDownloadTests {
    @Suite("SetupWelcomeLayoutTests", .serialized)
    struct SetupWelcomeLayoutTests {

        @MainActor
        @Test(arguments: slPaths) func theGlyphIsAFiftySixPointMagnifyingGlassInLabelColourCentredAndNotAnAccessibilityElement(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let glyphs = swlImages(root, "magnifyingglass")
                    #expect(glyphs.count == 1, "\(look): \(glyphs.count) magnifying glasses")
                    guard let glyph = glyphs.first else { continue }
                    let height = glyph.image?.size.height ?? 0
                    let want = swlSymbolHeights("magnifyingglass", 56)
                    #expect(want.contains(height), "\(look): the symbol is \(height) pt high, a 56 pt symbol is \(want)")
                    #expect(slColour(glyph.contentTintColor, is: .labelColor), "\(look): glyph tint")
                    #expect(!glyph.isAccessibilityElement(), "\(look): the glyph is an accessibility element")
                    let box = plBox(root, glyph)
                    #expect(abs(box.midX - 280) <= 8, "\(look): glyph centre \(box.midX), window centre 280")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theTitleIsTwentyFourBoldInLabelColourCentredSixteenUnderTheGlyph(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let titles = swlTexts(root, swlTitle)
                    #expect(titles.count == 1, "\(look): \(titles.count) titles")
                    guard let title = titles.first, let glyph = swlImages(root, "magnifyingglass").first else { continue }
                    #expect(slFont(title.font, size: 24, weight: .bold), "\(look): title font \(String(describing: title.font))")
                    #expect(slColour(title.textColor, is: .labelColor), "\(look): title colour")
                    let mid = swlInkMid(root, title, look)
                    #expect(mid != nil && abs((mid ?? 0) - 280) <= 8, "\(look): title text centre \(String(describing: mid)), window centre 280")
                    let gap = swlGap(root, upper: [glyph], lower: [title])
                    #expect(gap.near(16), "\(look): \(gap.frame) / \(gap.aligned) pt from the glyph to the title, wanted 16")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theSublineIsBodyInSecondaryColourCentredEightUnderTheTitle(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let sublines = swlTexts(root, swlSubline)
                    #expect(sublines.count == 1, "\(look): \(sublines.count) sublines")
                    guard let subline = sublines.first, let title = swlTexts(root, swlTitle).first else { continue }
                    #expect(slFont(subline.font, size: 13, weight: .regular), "\(look): subline font \(String(describing: subline.font))")
                    #expect(slColour(subline.textColor, is: .secondaryLabelColor), "\(look): subline colour")
                    let mid = swlInkMid(root, subline, look)
                    #expect(mid != nil && abs((mid ?? 0) - 280) <= 8, "\(look): subline text centre \(String(describing: mid)), window centre 280")
                    let gap = swlGap(root, upper: [title], lower: [subline])
                    #expect(gap.near(8), "\(look): \(gap.frame) / \(gap.aligned) pt from the title to the subline, wanted 8")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func eachPromiseRowIsASeventeenPointLabelColourSymbolAThirteenSemiboldLineAndATwelvePointSecondaryDetail(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let rows = try #require(swlRows(root), "\(look): the three promise rows are not each one symbol, one title and one detail")
                    for (row, promise) in zip(rows, swlPromises) {
                        let height = row.symbol.image?.size.height ?? 0
                        let want = swlSymbolHeights(promise.symbol, 17)
                        #expect(want.contains(height), "\(look) \(promise.symbol): \(height) pt high, a 17 pt symbol is \(want)")
                        #expect(slColour(row.symbol.contentTintColor, is: .labelColor), "\(look) \(promise.symbol): tint")
                        #expect(!row.symbol.isAccessibilityElement(), "\(look) \(promise.symbol): the symbol is an accessibility element")
                        #expect(slFont(row.title.font, size: 13, weight: .semibold), "\(look) \(promise.title): font \(String(describing: row.title.font))")
                        #expect(slColour(row.title.textColor, is: .labelColor), "\(look) \(promise.title): colour")
                        #expect(slFont(row.detail.font, size: 12, weight: .regular), "\(look) \(promise.detail): font \(String(describing: row.detail.font))")
                        #expect(slColour(row.detail.textColor, is: .secondaryLabelColor), "\(look) \(promise.detail): colour")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func thePromiseRowsSitTwentyFourUnderTheSublineTwelveApartInOneLeftAlignedColumnOfAtMost360PointsCentred(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let rows = try #require(swlRows(root), "\(look): the three promise rows are not each one symbol, one title and one detail")
                    let subline = try #require(swlTexts(root, swlSubline).first, "\(look): no subline")
                    let first = swlGap(root, upper: [subline], lower: rows[0].views)
                    #expect(first.near(24), "\(look): \(first.frame) / \(first.aligned) pt from the subline to the first row, wanted 24")
                    for index in 1..<rows.count {
                        let gap = swlGap(root, upper: rows[index - 1].views, lower: rows[index].views)
                        #expect(gap.near(12), "\(look): \(gap.frame) / \(gap.aligned) pt between rows \(index) and \(index + 1), wanted 12")
                    }
                    let all = rows.flatMap(\.views)
                    let column = try #require(swlUnion(root, all), "no column")
                    #expect(column.width <= 360.5, "\(look): the rows are \(column.width) pt wide")
                    #expect(abs(column.midX - 280) <= 8, "\(look): the rows' centre \(column.midX), window centre 280")
                    let symbolX = rows.map { plBox(root, $0.symbol).minX }
                    let titleX = rows.map { plBox(root, $0.title).minX }
                    let detailX = rows.map { plBox(root, $0.detail).minX }
                    #expect((symbolX.max() ?? 0) - (symbolX.min() ?? 0) <= 0.5, "\(look): symbols start at \(symbolX)")
                    #expect((titleX.max() ?? 0) - (titleX.min() ?? 0) <= 0.5, "\(look): titles start at \(titleX)")
                    #expect(zip(titleX, detailX).allSatisfy { abs($0 - $1) <= 0.5 }, "\(look): titles start at \(titleX), details at \(detailX)")
                    for row in rows {
                        #expect(plBox(root, row.title).minX >= plBox(root, row.symbol).maxX - 0.5, "\(look): \(row.title.stringValue) overlaps its symbol")
                        #expect(plBox(root, row.detail).top >= plBox(root, row.title).bottom - 1, "\(look): \(row.detail.stringValue) is not under its title")
                        #expect(row.title.alignment != .center && row.title.alignment != .right, "\(look): \(row.title.stringValue) is not left-aligned")
                        #expect(row.detail.alignment != .center && row.detail.alignment != .right, "\(look): \(row.detail.stringValue) is not left-aligned")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theStatusLineIsASecondaryColourCheckAndTheReadyTextCentredSixteenAboveTheFooter(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let checks = swlImages(root, "checkmark.circle.fill")
                    let readies = swlTexts(root, swlReady)
                    #expect(checks.count == 1 && readies.count == 1, "\(look): \(checks.count) checks, \(readies.count) ready lines")
                    guard let check = checks.first, let ready = readies.first else { continue }
                    let height = check.image?.size.height ?? 0
                    let want = swlSymbolHeights("checkmark.circle.fill", 14)
                    #expect(want.contains(height), "\(look): the check is \(height) pt high, a 14 pt symbol is \(want)")
                    #expect(slColour(check.contentTintColor, is: .secondaryLabelColor), "\(look): check tint")
                    #expect(!check.isAccessibilityElement(), "\(look): the check is an accessibility element")
                    #expect(slFont(ready.font, size: 12, weight: .regular), "\(look): ready font \(String(describing: ready.font))")
                    #expect(slColour(ready.textColor, is: .secondaryLabelColor), "\(look): ready colour")
                    let checkBox = plBox(root, check)
                    let readyBox = plBox(root, ready)
                    let across = readyBox.minX - checkBox.maxX
                    #expect(across >= -0.5 && across <= 12, "\(look): the text starts \(across) pt after the check")
                    #expect(abs((checkBox.top + checkBox.bottom) / 2 - (readyBox.top + readyBox.bottom) / 2) <= 3, "\(look): the check and the text are not on one line")
                    let line = checkBox.union(readyBox)
                    #expect(abs(line.midX - 280) <= 8, "\(look): status line centre \(line.midX), window centre 280")
                    let gap = swlGap(root, upper: [check, ready], lower: swlNav(root))
                    #expect(gap.near(16), "\(look): \(gap.frame) / \(gap.aligned) pt from the status line to the footer, wanted 16")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theTopEdgesRunGlyphTitleSublineRowsStatusLineFooter(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                let root = slLayout(rig)
                let glyph = try #require(swlImages(root, "magnifyingglass").first, "no glyph")
                let title = try #require(swlTexts(root, swlTitle).first, "no title")
                let subline = try #require(swlTexts(root, swlSubline).first, "no subline")
                let rows = try #require(swlRows(root), "no rows")
                let ready = try #require(swlTexts(root, swlReady).first, "no status line")
                let next = try #require(slButton(root, "Next"), "no Next")
                var tops = [plBox(root, glyph).top, plBox(root, title).top, plBox(root, subline).top]
                tops += rows.map { row in row.views.map { plBox(root, $0).top }.min() ?? 0 }
                tops += [plBox(root, ready).top, plBox(root, next).top]
                #expect(zip(tops, tops.dropFirst()).allSatisfy { $0 < $1 }, "top edges are not in order: \(tops)")
                #expect((tops.first ?? -1) >= 0,"the glyph starts above the window: \(tops)")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aWholeModelShowsNoModelCardBarFigureOrRetryOnWelcome(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    #expect(slStyle(root, "The search model") == nil, "\(look): the model card heading is shown")
                    #expect(!prViews(root).contains { ($0 is NSProgressIndicator || $0 is FigureView) && plVisible($0) }, "\(look): a bar or figure is shown")
                    #expect(slButton(root, "Retry") == nil, "\(look): Retry is shown")
                    #expect(plText(root, "The model is ready.") == nil, "\(look): the old ready line is shown")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theWelcomeTreeHasNoTextViewAndNoScrollerInAnyModelState(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading, SLState.damaged, SLState.failed] {
                try await slWith(state, glass: glass) { rig in
                    let root = slLayout(rig)
                    #expect(!prViews(root).contains { $0 is NSTextView && plVisible($0) }, "\(state): a text view is shown on Welcome")
                    #expect(!prViews(root).contains { $0 is NSScroller && plVisible($0) }, "\(state): a scroller is shown on Welcome")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theWelcomePaletteIsLabelSecondaryTertiarySeparatorGroupFillAndAccentOnlyOnTheCurrentDotAndNext(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading, SLState.damaged, SLState.failed] {
                try await slWith(state, glass: glass) { rig in
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let found = swlPaletteViolations(root, look, allowError: state == .failed, glass: glass)
                        #expect(found.isEmpty, "\(state) \(look): \(found)")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func noOtherStepShowsTheGlyphThePromisesOrTheWelcomeLines(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    for entry in slStepNames where entry.step != .welcome {
                        await slWalk(rig, to: entry.step)
                        let root = slLayout(rig)
                        #expect(swlImages(root, "magnifyingglass").isEmpty, "\(state) / \(entry.label): the glyph is shown")
                        for promise in swlPromises {
                            #expect(swlImages(root, promise.symbol).isEmpty, "\(state) / \(entry.label): \(promise.symbol) is shown")
                            #expect(swlTexts(root, promise.title).isEmpty && swlTexts(root, promise.detail).isEmpty, "\(state) / \(entry.label): \(promise.title) is shown")
                        }
                        #expect(swlTexts(root, swlTitle).isEmpty && swlTexts(root, swlSubline).isEmpty, "\(state) / \(entry.label): a Welcome line is shown")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aModelThatIsNotWholeHidesTheStatusLineAndShowsTheModelCardOnWelcome(glass: Bool) async throws {
            for state in [SLState.downloading, SLState.damaged, SLState.failed] {
                try await slWith(state, glass: glass) { rig in
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        #expect(plText(root, swlReady) == nil, "\(tag): the ready line is shown")
                        #expect(swlImages(root, "checkmark.circle.fill").isEmpty, "\(tag): the status check is shown")
                        let heading = slStyle(root, "The search model")
                        #expect(heading != nil && slFont(heading?.font, size: 13, weight: .semibold), "\(tag): heading \(String(describing: heading?.font))")
                        let bars = prViews(root).compactMap { $0 as? NSProgressIndicator }.filter { plVisible($0) }
                        let figures = prViews(root).compactMap { $0 as? FigureView }.filter { plVisible($0) }
                        #expect(bars.count == 1 && figures.count == 1, "\(tag): \(bars.count) bars, \(figures.count) figures")
                        if let bar = bars.first, let figure = figures.first {
                            #expect(!bar.isIndeterminate && bar.style == .bar && bar.controlSize == .small, "\(tag): the bar is not a small determinate bar")
                            #expect(figure.isAccessibilityElement() && figure.accessibilityTitle() == "Model download", "\(tag): figure title \(String(describing: figure.accessibilityTitle()))")
                            #expect(abs(plBox(root, figure).maxX - plBox(root, bar).maxX) <= 1, "\(tag): figure right edge \(plBox(root, figure).maxX), bar right edge \(plBox(root, bar).maxX)")
                            if let text = plText(root, "The search model"), let card = slCard(of: text) {
                                #expect(slCard(of: bar) === card && slCard(of: figure) === card, "\(tag): the bar or figure is outside the heading's card")
                            } else {
                                Issue.record("\(tag): the heading is in no GroupCard")
                            }
                        }
                        switch state {
                        case .damaged:
                            #expect(plText(root, swlDamaged) != nil, "\(tag): no damaged message")
                            #expect(slButton(root, "Retry") == nil, "\(tag): Retry is shown")
                        case .failed:
                            let retry = slButton(root, "Retry")
                            #expect(retry != nil && retry?.isEnabled == true, "\(tag): no enabled Retry")
                            let failure = plText(root, slFailedMessage)
                            #expect(failure != nil && slColour(failure?.textColor, is: .systemRed), "\(tag): failure line \(String(describing: failure?.stringValue))")
                            #expect(plText(root, "Try again in a moment.") != nil, "\(tag): no next-step line")
                            let images = plAccessibilityImages(root).filter { plVisible($0) }
                            #expect(images.count == 1 && images.first?.accessibilityLabel() == "Warning", "\(tag): \(images.count) accessibility images")
                        default:
                            #expect(slButton(root, "Retry") == nil, "\(tag): Retry is shown")
                            #expect(plAccessibilityImages(root).filter { plVisible($0) }.isEmpty, "\(tag): an accessibility image is shown")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func withAModelThatIsNotWholeTheRowsStillFitTheCardEndsSixteenAboveTheFooterAndNothingOverlaps(glass: Bool) async throws {
            for state in [SLState.downloading, SLState.damaged, SLState.failed] {
                try await slWith(state, glass: glass) { rig in
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let glyph = try #require(swlImages(root, "magnifyingglass").first, "\(tag): no glyph")
                        let title = try #require(swlTexts(root, swlTitle).first, "\(tag): no title")
                        let subline = try #require(swlTexts(root, swlSubline).first, "\(tag): no subline")
                        let rows = try #require(swlRows(root), "\(tag): no rows")
                        let heading = try #require(plText(root, "The search model"), "\(tag): no model heading")
                        let card = try #require(slCard(of: heading), "\(tag): the heading is in no GroupCard")
                        var blocks: [(String, PLBox)] = [
                            ("glyph", plBox(root, glyph)), ("title", plBox(root, title)), ("subline", plBox(root, subline)),
                        ]
                        for (index, row) in rows.enumerated() {
                            if let box = swlUnion(root, row.views) { blocks.append(("row \(index + 1)", box)) }
                        }
                        blocks.append(("card", plBox(root, card)))
                        for (upper, lower) in zip(blocks, blocks.dropFirst()) {
                            #expect(upper.1.bottom <= lower.1.top + 0.5, "\(tag): \(upper.0) ends at \(upper.1.bottom), \(lower.0) starts at \(lower.1.top)")
                        }
                        for block in blocks {
                            #expect(block.1.minX >= 0 && block.1.maxX <= 560 && block.1.top >= 0, "\(tag): \(block.0) leaves the window")
                        }
                        var lowest = plBox(root, card).bottom
                        if let retry = slButton(root, "Retry") { lowest = max(lowest, slAlignBox(root, retry).bottom) }
                        let nav = swlNav(root)
                        let footerAligned = nav.map { slAlignBox(root, $0).top }.min() ?? 0
                        #expect(footerAligned - lowest >= 15.5, "\(tag): the lowest content ends \(footerAligned - lowest) pt above the footer, wanted at least 16")
                        let bottom = slContentBottom(root) ?? 0
                        let footerFrame = nav.map { plBox(root, $0).top }.min() ?? 0
                        #expect(bottom <= footerFrame + 0.5, "\(tag): content ends at \(bottom), the footer starts at \(footerFrame)")
                    }
                }
            }
        }
    }
}
