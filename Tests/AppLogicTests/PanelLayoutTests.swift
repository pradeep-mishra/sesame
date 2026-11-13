import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let plHintLine = "↩ Open  ⌘↩ Reveal  ⌘C Copy  esc Close"
private let plPlaceholder = "Search your files"

@MainActor
private func plAncestors(_ view: NSView) -> [NSView] {
    var out: [NSView] = []
    var current = view.superview
    while let next = current {
        out.append(next)
        current = next.superview
    }
    return out
}

@MainActor
private func plFooter(_ root: NSView) throws -> NSView {
    try #require(plFind(root, "PanelFooter"), "no view with accessibility identifier PanelFooter")
}

@MainActor
private func plSearching(_ panel: Panel) async {
    await prType("a dog on the beach", into: panel, pauseMilliseconds: 20)
    panel.sendEvent(prKey("\r", in: panel, keyCode: 36))
    let shown = await spEventually(timeout: 8) { prShownTexts(panel.contentView!).contains("Searching") }
    #expect(shown, "never shown Searching; shown: \(prShownTexts(panel.contentView!))")
}

extension ModelDownloadTests {
    @Suite("PanelLayoutTests", .serialized)
    struct PanelLayoutTests {

        @MainActor
        @Test func thePanelContentIs960By560() async throws {
            try await plWithPanel { panel in
                let root = plLayout(panel)
                #expect(root.frame.size == NSSize(width: 960, height: 560), "content \(root.frame.size)")
                #expect(panel.frame.size == NSSize(width: 960, height: 560), "frame \(panel.frame.size)")
            }
        }

        @MainActor
        @Test func theRootIsAPopoverVisualEffectViewBehindTheWindowAndAlwaysActive() async throws {
            try await plWithPanel { panel in
                let effect = try #require(panel.contentView as? NSVisualEffectView, "root is \(String(describing: panel.contentView))")
                #expect(effect.material == .popover)
                #expect(effect.blendingMode == .behindWindow)
                #expect(effect.state == .active)
            }
        }

        @MainActor
        @Test func theAppNeitherRoundsNorMasksTheWindow() async throws {
            try await plWithPanel { panel in
                let effect = try #require(panel.contentView as? NSVisualEffectView)
                #expect(effect.maskImage == nil)
                #expect((effect.layer?.cornerRadius ?? 0) == 0)
                #expect(effect.layer?.masksToBounds != true)
                #expect(panel.styleMask.contains(.fullSizeContentView))
            }
        }

        @MainActor
        @Test func theSearchFieldIsA22PointTextFieldWithNoFocusRingAndAPlaceholderInPlaceholderColour() async throws {
            try await plWithPanel { panel in
                _ = plLayout(panel)
                let field = panel.queryBox.field
                #expect(type(of: field) == NSTextField.self)
                #expect(field.focusRingType == .none)
                #expect(field.font?.pointSize == 22)
                #expect(abs(dtWeight(field.font ?? .systemFont(ofSize: 22)) - NSFont.Weight.regular.rawValue) < 0.05)
                #expect(field.placeholderAttributedString?.string == plPlaceholder, "placeholder is \(String(describing: field.placeholderAttributedString?.string))")
                for look in DTLook.allCases {
                    let actual = plRGBAOfAttribute(field.placeholderAttributedString, look)
                    #expect(actual != nil && dtSame(actual ?? [], dtRGBA(.placeholderTextColor, look)), "placeholder colour \(look)")
                }
            }
        }

        @MainActor
        @Test func theSearchRowIsFiftyEightPointsTallWithTheFieldCentredInIt() async throws {
            try await plWithPanel { panel in
                let root = plLayout(panel)
                let field = plBox(root, panel.queryBox.field)
                #expect(abs((field.top + field.bottom) / 2 - 29) <= 3, "field spans \(field.top) to \(field.bottom)")
                #expect(plVisibleDividers(root).isEmpty, "\(plVisibleDividers(root).count) dividers are shown on the empty panel")
            }
            try await plWithTypingPanel { panel in
                await plSearching(panel)
                let root = plLayout(panel)
                let dividers = plVisibleDividers(root)
                #expect(dividers.count == 1, "\(dividers.count) dividers")
                if let divider = dividers.first {
                    let top = plBox(root, divider).top
                    #expect(top >= 58 - 0.5 && top <= 60.5, "the split starts at \(top)")
                }
            }
        }

        @MainActor
        @Test func theFooterIsThirtyTwoPointsFullWidthAtTheBottomEdge() async throws {
            try await plWithPanel { panel in
                let root = plLayout(panel)
                let footer = try plFooter(root)
                let box = plBox(root, footer)
                #expect(plVisible(footer))
                #expect(abs(box.height - 32) <= 0.5, "height \(box.height)")
                #expect(abs(box.minX) <= 0.5 && abs(box.width - 960) <= 0.5, "x \(box.minX) width \(box.width)")
                #expect(abs(box.bottom - 560) <= 0.5, "bottom \(box.bottom)")
            }
        }

        @MainActor
        @Test func theFooterHoldsTheHintLineAtElevenPointsSecondaryWithATwentyPointLeftInset() async throws {
            try await plWithPanel { panel in
                let root = plLayout(panel)
                let footer = try plFooter(root)
                let hint = try #require(plText(footer, plHintLine), "footer texts: \(plTexts(footer).map(\.stringValue))")
                #expect(hint.font?.pointSize == 11)
                #expect(abs(dtWeight(hint.font ?? .systemFont(ofSize: 11)) - NSFont.Weight.regular.rawValue) < 0.05)
                for look in DTLook.allCases {
                    #expect(dtSame(dtRGBA(hint.textColor ?? .clear, look), dtRGBA(.secondaryLabelColor, look)), "hint colour \(look)")
                }
                let inset = plBox(root, hint).minX - plBox(root, footer).minX
                #expect(abs(inset - 20) <= 1, "left inset \(inset)")
            }
        }

        @MainActor
        @Test func theFooterIsNotInsideTheSearchHintOrPreviewGroupAndHoldsNoStateWords() async throws {
            try await plWithPanel { panel in
                let root = plLayout(panel)
                let footer = try plFooter(root)
                for ancestor in plAncestors(footer) {
                    #expect(ancestor.accessibilityLabel() != "Search hint", "inside the Search hint group")
                    #expect(ancestor.accessibilityLabel() != "Preview", "inside the Preview group")
                    #expect(ancestor.accessibilityIdentifier() != "EmptyHint")
                }
                let texts = plTexts(footer).map(\.stringValue)
                #expect(!texts.contains { $0.contains("Searching") || $0.contains("No matches") }, "footer texts: \(texts)")
                #expect(plText(footer, plHintLine) != nil)
            }
        }

        @MainActor
        @Test func theStatusAndPermissionNotesSitAtTheRightOfTheFooterWhileTheListSaysSearching() async throws {
            var conditions = PLConditions()
            conditions.counts = IndexCounts(done: 3, pending: [:], partial: [:], needsPermission: 2)
            try await plWithTypingPanel(conditions) { panel in
                await prType("a dog on the beach", into: panel, pauseMilliseconds: 20)
                panel.sendEvent(prKey("\r", in: panel, keyCode: 36))
                let root = plLayout(panel)
                let shown = await spEventually(timeout: 8) { prShownTexts(root).contains("Still ranking") }
                #expect(shown, "never shown Still ranking; shown: \(prShownTexts(root))")
                let laid = plLayout(panel)
                let footer = try plFooter(laid)
                let status = try #require(plText(footer, "Still ranking"), "footer texts: \(plTexts(footer).map(\.stringValue))")
                let permission = try #require(plText(footer, "2 files need permission to be read"), "footer texts: \(plTexts(footer).map(\.stringValue))")
                #expect(status.accessibilityIdentifier() == "StatusNote")
                #expect(permission.accessibilityIdentifier() == "PermissionNote")
                let hint = plBox(laid, try #require(plText(footer, plHintLine)))
                let frame = plBox(laid, footer)
                for note in [status, permission] {
                    let box = plBox(laid, note)
                    #expect(box.minX >= hint.maxX + 8, "\(note.stringValue) starts at \(box.minX), the hint ends at \(hint.maxX)")
                    #expect(box.midX >= 480, "\(note.stringValue) midX \(box.midX)")
                    #expect(box.maxX <= 941, "\(note.stringValue) ends at \(box.maxX)")
                    #expect(box.top >= frame.top - 0.5 && box.bottom <= frame.bottom + 0.5, "\(note.stringValue) is outside the footer")
                }
                #expect(!plBox(laid, status).intersects(plBox(laid, permission)))
                let outside = prShownTexts(laid).filter { $0 == "Searching" }
                #expect(outside.count == 1, "the list does not say Searching: \(prShownTexts(laid))")
                #expect(!plTexts(footer).contains { $0.stringValue.contains("Searching") })
            }
        }

        @MainActor
        @Test func theFooterStaysFreeOfTheStateWordsWhenThereAreNoMatches() async throws {
            try await prWithPanel(answering: true) { panel in
                await prType("zzqx", into: panel, pauseMilliseconds: 20)
                let shown = await spEventually(timeout: 30) { prShownTexts(panel.contentView!).contains("No matches") }
                #expect(shown, "never shown No matches; shown: \(prShownTexts(panel.contentView!))")
                let root = plLayout(panel)
                let footer = try plFooter(root)
                let texts = plTexts(footer).map(\.stringValue)
                #expect(!texts.contains { $0.contains("Searching") || $0.contains("No matches") }, "footer texts: \(texts)")
                #expect(texts.contains(plHintLine), "footer texts: \(texts)")
            }
        }

        @MainActor
        @Test func theSplitIsFortyPercentWithAOnePixelDividerAndThePaneAfterIt() async throws {
            try await plWithTypingPanel { panel in
                await plSearching(panel)
                let root = plLayout(panel)
                let dividers = plVisibleDividers(root)
                #expect(dividers.count == 1, "\(dividers.count) dividers")
                let divider = try #require(dividers.first)
                let box = plBox(root, divider)
                #expect(box.minX >= 383 && box.minX <= 385, "divider at \(box.minX)")
                #expect(box.width >= 0.5 && box.width <= 1.01, "divider width \(box.width)")
                let table = try #require(plList(root))
                let scroll = try #require(plAncestors(table).first { $0 is NSScrollView })
                let list = plBox(root, scroll)
                #expect(list.minX >= 0 && list.minX <= 1, "list starts at \(list.minX)")
                #expect(abs(list.width - 384) <= 1, "list width \(list.width)")
                let pane = try #require(prViews(root).first { $0.accessibilityLabel() == "Preview" })
                #expect(plBox(root, pane).minX >= box.maxX - 0.5, "pane starts at \(plBox(root, pane).minX)")
            }
        }

        @MainActor
        @Test func theKeyLoopGoesFromTheSearchBoxToTheListAndBack() async throws {
            try await plWithPanel { panel in
                _ = plLayout(panel)
                let field = panel.queryBox.field
                let list = try #require(field.nextKeyView)
                #expect(list.accessibilityLabel() == "Results")
                #expect(list.nextKeyView === field)
            }
        }
    }
}
