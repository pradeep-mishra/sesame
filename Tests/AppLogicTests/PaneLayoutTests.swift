import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let pgWidth: CGFloat = 576
private let pgHeight: CGFloat = 470
private let pgPassage = String(repeating: "The tenant may keep one cat with written landlord consent. ", count: 24)

private func pgPdf(status: PreviewStatus = .ok, size: Int = 1_234_567) -> PreviewReply {
    PreviewReply(ticket: 1, status: status, png: nil, name: "report.pdf", kind: "pdf", size: size, mtime: 1_700_000_000,
                 page: 7, pageCount: 40, locator: "Page 7 of 40")
}

private func pgPhoto() -> PreviewReply {
    PreviewReply(ticket: 2, status: .ok, png: nil, name: "beach.jpg", kind: "photo", size: 1_234_567, mtime: 1_700_000_000)
}

private func pgDoc() -> PreviewReply {
    PreviewReply(ticket: 3, status: .ok, png: nil, name: "tenancy.docx", kind: "doc", size: 9_001, mtime: 1_700_000_500,
                 text: pgPassage, marks: [4, 10])
}

private func pgAudio() -> PreviewReply {
    PreviewReply(ticket: 4, status: .ok, png: nil, name: "memo.m4a", kind: "audio", size: 7_040_044, mtime: 1_700_000_000,
                 locator: "Opens at 02:10", text: "remember the milk", seconds: 130)
}

@MainActor
private func pgPicture() -> NSImage {
    NSImage(size: NSSize(width: 200, height: 100))
}

@MainActor
private func pgPane(look: DTLook = .light) -> Pane {
    let pane = Pane()
    pane.view.appearance = dtAppearance(look)
    pane.view.frame = NSRect(x: 0, y: 0, width: pgWidth, height: pgHeight)
    pane.view.layoutSubtreeIfNeeded()
    return pane
}

@MainActor
private func pgSettle(_ pane: Pane) {
    pane.view.layoutSubtreeIfNeeded()
}

@MainActor
private func pgBox(_ pane: Pane, _ view: NSView) -> PLBox {
    let rect = pane.view.convert(view.alignmentRect(forFrame: view.frame), from: view.superview)
    let top = pane.view.isFlipped ? rect.minY : pane.view.bounds.height - rect.maxY
    return PLBox(minX: rect.minX, maxX: rect.maxX, top: top, bottom: top + rect.height)
}

@MainActor
private func pgShown(_ view: NSView) -> Bool {
    !view.isHiddenOrHasHiddenAncestor
}

@MainActor
private func pgFields(_ pane: Pane) -> [NSTextField] {
    prViews(pane.view).compactMap { $0 as? NSTextField }.filter { pgShown($0) && !$0.stringValue.isEmpty }
}

@MainActor
private func pgField(_ pane: Pane, _ text: String) -> NSTextField? {
    pgFields(pane).first { $0.stringValue == text }
}

@MainActor
private func pgFieldStarting(_ pane: Pane, _ prefix: String) -> NSTextField? {
    pgFields(pane).first { $0.stringValue.hasPrefix(prefix) }
}

@MainActor
private func pgPictureView(_ pane: Pane) -> NSImageView? {
    prViews(pane.view).compactMap { $0 as? NSImageView }.first { ($0.accessibilityLabel() ?? "").hasPrefix("Preview") }
}

@MainActor
private func pgPassageView(_ pane: Pane) -> NSTextView? {
    prViews(pane.view).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "Passage" }
}

@MainActor
private func pgFrame(around view: NSView, in pane: Pane) -> NSView? {
    var current = view.superview
    while let next = current, next !== pane.view {
        if next.layer?.cornerRadius == 10 { return next }
        current = next.superview
    }
    return nil
}

@MainActor
private func pgPictureFrame(_ pane: Pane) throws -> NSView {
    let picture = try #require(pgPictureView(pane), "no image view labelled Preview...")
    return try #require(pgFrame(around: picture, in: pane), "the picture has no ancestor view with a layer of corner radius 10")
}

@Suite("PaneLayoutTests", .serialized)
struct PaneLayoutTests {

    @MainActor
    @Test func thePictureSitsInAFrameOfRadiusTenWithAHairlineAndAControlBackgroundBackingAspectFit() throws {
        for look in DTLook.allCases {
            let pane = pgPane(look: look)
            pane.show(pgPdf(), path: "/docs/report.pdf", image: pgPicture())
            pgSettle(pane)
            let picture = try #require(pgPictureView(pane), "no image view labelled Preview...")
            let frame = try #require(pgFrame(around: picture, in: pane), "the picture has no ancestor view with a layer of corner radius 10")
            #expect(frame.layer?.cornerRadius == 10)
            let width = frame.layer?.borderWidth ?? 0
            #expect(width > 0 && width <= 1, "border width \(width)")
            let border = dtRGBA(cgColor: frame.layer?.borderColor)
            #expect(border != nil && dtSame(border ?? [], dtRGBA(.separatorColor, look)), "border colour \(look): \(String(describing: border))")
            let backing = dtRGBA(cgColor: frame.layer?.backgroundColor)
            #expect(backing != nil && dtSame(backing ?? [], dtRGBA(.controlBackgroundColor, look)), "backing \(look): \(String(describing: backing))")
            #expect(picture.imageScaling == .scaleProportionallyUpOrDown)
            let outer = pgBox(pane, frame)
            let inner = pgBox(pane, picture)
            #expect(inner.minX >= outer.minX - 0.5 && inner.maxX <= outer.maxX + 0.5 && inner.top >= outer.top - 0.5 && inner.bottom <= outer.bottom + 0.5,
                    "the picture \(inner) is not inside its frame \(outer)")
            #expect(pgShown(frame))
            #expect(!(frame is NSImageView))
        }
    }

    @MainActor
    @Test func theFrameIsInsetTwentyOnTheLeftTopAndRightAndTallEnoughToShowAPicture() throws {
        for reply in [pgPdf(), pgPhoto()] {
            let pane = pgPane()
            pane.show(reply, path: "/docs/" + reply.name, image: pgPicture())
            pgSettle(pane)
            let frame = try pgPictureFrame(pane)
            let box = pgBox(pane, frame)
            #expect(abs(box.minX - 20) <= 1, "\(reply.kind): left \(box.minX)")
            #expect(abs(box.maxX - (pgWidth - 20)) <= 1, "\(reply.kind): right \(box.maxX)")
            #expect(abs(box.top - 20) <= 1, "\(reply.kind): top \(box.top)")
            #expect(box.height >= 150, "\(reply.kind): height \(box.height)")
        }
    }

    @MainActor
    @Test func theTextFollowsTheFrameTwelveBelowItAndEightBetweenLinesAllOnOneLeftEdgeOfTwenty() throws {
        let pane = pgPane()
        pane.show(pgPdf(status: .changed), path: "/docs/report.pdf", image: pgPicture())
        pgSettle(pane)
        let frame = pgBox(pane, try pgPictureFrame(pane))
        let texts = ["report.pdf", "/docs/report.pdf", "Page 7 of 40", "Opens in Preview", "changed since indexed"]
        var fields = [try #require(pgField(pane, "report.pdf"), "name not shown; shown \(pgFields(pane).map(\.stringValue))"),
                      try #require(pgField(pane, "/docs/report.pdf"))]
        fields.append(try #require(pgFieldStarting(pane, "pdf · "), "no kind · size · date line; shown \(pgFields(pane).map(\.stringValue))"))
        fields.append(contentsOf: [try #require(pgField(pane, texts[2])), try #require(pgField(pane, texts[3])), try #require(pgField(pane, texts[4]))])
        let boxes = fields.map { pgBox(pane, $0) }
        #expect(abs(boxes[0].top - (frame.bottom + 12)) <= 1, "name top \(boxes[0].top), frame bottom \(frame.bottom)")
        for index in 1..<boxes.count {
            #expect(abs(boxes[index].top - (boxes[index - 1].bottom + 8)) <= 1, "\(fields[index].stringValue): top \(boxes[index].top), the line above ends \(boxes[index - 1].bottom)")
        }
        for (field, box) in zip(fields, boxes) {
            #expect(abs(box.minX - 20) <= 1, "\(field.stringValue): left \(box.minX)")
        }
    }

    @MainActor
    @Test func theNameIsFifteenSemiboldAndTheOtherLinesAreTwelveInSecondaryColourExceptTheLocator() throws {
        for look in DTLook.allCases {
            let pane = pgPane(look: look)
            pane.show(pgPdf(status: .changed), path: "/docs/report.pdf", image: pgPicture())
            pgSettle(pane)
            let name = try #require(pgField(pane, "report.pdf"))
            #expect(name.font?.pointSize == 15)
            #expect(abs(dtWeight(name.font ?? .systemFont(ofSize: 15)) - NSFont.Weight.semibold.rawValue) < 0.05)
            #expect(dtSame(dtRGBA(name.textColor ?? .clear, look), dtRGBA(.labelColor, look)), "name colour \(look)")
            let quiet = [try #require(pgField(pane, "/docs/report.pdf")), try #require(pgFieldStarting(pane, "pdf · ")),
                         try #require(pgField(pane, "Opens in Preview")), try #require(pgField(pane, "changed since indexed"))]
            for field in quiet {
                #expect(field.font?.pointSize == 12, "\(field.stringValue) size")
                #expect(abs(dtWeight(field.font ?? .systemFont(ofSize: 12)) - NSFont.Weight.regular.rawValue) < 0.05, "\(field.stringValue) weight")
                #expect(dtSame(dtRGBA(field.textColor ?? .clear, look), dtRGBA(.secondaryLabelColor, look)), "\(field.stringValue) colour \(look)")
            }
            let locator = try #require(pgField(pane, "Page 7 of 40"))
            #expect([12, 13].contains(locator.font?.pointSize ?? 0), "locator size \(String(describing: locator.font?.pointSize))")
            #expect(dtSame(dtRGBA(locator.textColor ?? .clear, look), dtRGBA(.labelColor, look)), "locator colour \(look)")
            let fifteens = pgFields(pane).filter { $0.font?.pointSize == 15 }.map(\.stringValue)
            #expect(fifteens == ["report.pdf"], "15 pt texts: \(fifteens)")
        }
    }

    @MainActor
    @Test func theLongPathShortensInTheMiddleAndStaysInsideTheTwentyPointInset() throws {
        let pane = pgPane()
        let path = "/Users/someone/" + (0..<14).map { "a-rather-long-folder-name-\($0)" }.joined(separator: "/") + "/report.pdf"
        pane.show(pgPdf(), path: path, image: pgPicture())
        pgSettle(pane)
        let field = try #require(pgField(pane, path), "the path is not shown in full as the field's value")
        #expect(field.lineBreakMode == .byTruncatingMiddle)
        let box = pgBox(pane, field)
        #expect(box.minX >= 19 && box.maxX <= pgWidth - 20 + 1, "path spans \(box.minX) to \(box.maxX)")
    }

    @MainActor
    @Test func aFileOf1234567BytesShowsOnePointTwoMBOnOneKindSizeDateLineAndNoByteCount() throws {
        let pane = pgPane()
        pane.show(pgPhoto(), path: "/photos/beach.jpg", image: pgPicture())
        pgSettle(pane)
        let line = try #require(pgFieldStarting(pane, "photo · "), "no kind · size · date line; shown \(pgFields(pane).map(\.stringValue))")
        #expect(line.stringValue.hasPrefix("photo · 1.2 MB · "), "line is \(line.stringValue)")
        #expect(line.stringValue.contains("2023"), "line is \(line.stringValue)")
        #expect(line.stringValue.components(separatedBy: " · ").count == 3, "line is \(line.stringValue)")
        #expect(pgBox(pane, line).height < 24, "the line is \(pgBox(pane, line).height) tall")
        for field in pgFields(pane) {
            #expect(!field.stringValue.contains("bytes)"), "\(field.stringValue)")
            #expect(!field.stringValue.contains("bytes"), "\(field.stringValue)")
            #expect(!field.stringValue.contains("1,234,567"), "\(field.stringValue)")
        }
        for label in prViews(pane.view).compactMap({ $0.accessibilityLabel() }) {
            #expect(!label.contains("bytes"), "label \(label)")
        }
    }

    @MainActor
    @Test func aDocumentPassageSitsInTheSameFrameAsThePictureAndInsideIt() throws {
        let pane = pgPane()
        pane.show(pgDoc(), path: "/docs/tenancy.docx", image: nil)
        pgSettle(pane)
        let passage = try #require(pgPassageView(pane), "no text view labelled Passage")
        let picture = try #require(pgPictureView(pane), "no picture view")
        let frame = try #require(pgFrame(around: passage, in: pane), "the passage has no ancestor view with a layer of corner radius 10")
        let pictureFrame = try #require(pgFrame(around: picture, in: pane))
        #expect(frame === pictureFrame, "the passage and the picture sit in two different frames")
        #expect(pgShown(frame) && pgShown(passage))
        #expect(frame.layer?.cornerRadius == 10)
        for look in DTLook.allCases {
            pane.view.appearance = dtAppearance(look)
            pgSettle(pane)
            let backing = dtRGBA(cgColor: frame.layer?.backgroundColor)
            #expect(backing != nil && dtSame(backing ?? [], dtRGBA(.controlBackgroundColor, look)), "backing \(look)")
            let border = dtRGBA(cgColor: frame.layer?.borderColor)
            #expect(border != nil && dtSame(border ?? [], dtRGBA(.separatorColor, look)), "border \(look)")
        }
        let outer = pgBox(pane, frame)
        let inner = pgBox(pane, passage)
        #expect(inner.minX >= outer.minX - 0.5 && inner.maxX <= outer.maxX + 0.5 && inner.top >= outer.top - 0.5 && inner.bottom <= outer.bottom + 0.5,
                "the passage \(inner) is not inside the frame \(outer)")
        #expect(abs(outer.minX - 20) <= 1 && abs(outer.maxX - (pgWidth - 20)) <= 1 && abs(outer.top - 20) <= 1, "frame \(outer)")
        let name = pgBox(pane, try #require(pgField(pane, "tenancy.docx")))
        #expect(abs(name.top - (outer.bottom + 12)) <= 1, "name top \(name.top), frame bottom \(outer.bottom)")
    }

    @MainActor
    @Test func thePassageViewIsAsWideAsItsClipViewInsideTheFrame() throws {
        let pane = pgPane()
        pane.show(pgDoc(), path: "/docs/tenancy.docx", image: nil)
        pgSettle(pane)
        let passage = try #require(pgPassageView(pane))
        let scroll = try #require(passage.enclosingScrollView, "the passage is not inside a scroll view")
        let clip = scroll.contentView.bounds.width
        #expect(abs(passage.frame.width - clip) <= 1, "passage \(passage.frame.width), clip \(clip)")
        let frame = try #require(pgFrame(around: passage, in: pane))
        #expect(pgBox(pane, scroll).width <= pgBox(pane, frame).width + 0.5)
    }

    @MainActor
    @Test func theLabelsAndWordsTheKitAndTheSealedTestsReadAreUnchanged() throws {
        let pane = pgPane()
        #expect(pgPictureView(pane)?.accessibilityLabel() == "Preview picture")
        pane.showPending(path: "/docs/report.pdf")
        pgSettle(pane)
        #expect(pgPictureView(pane)?.accessibilityLabel() == "Preview picture")
        #expect(pgField(pane, "report.pdf") != nil && pgField(pane, "/docs/report.pdf") != nil)

        pane.show(pgPdf(), path: "/docs/report.pdf", image: pgPicture())
        pgSettle(pane)
        #expect(pgPictureView(pane)?.accessibilityLabel() == "Preview of report.pdf")
        #expect(pgField(pane, "Page 7 of 40") != nil)
        #expect(pgFields(pane).filter { $0.stringValue.hasPrefix("Opens in ") }.map(\.stringValue) == ["Opens in Preview"])

        pane.show(pgDoc(), path: "/docs/tenancy.docx", image: nil)
        pgSettle(pane)
        #expect(pgPassageView(pane)?.accessibilityLabel() == "Passage")
        #expect(pgPassageView(pane)?.accessibilityRole() == .textArea)
        #expect(pgFields(pane).filter { $0.stringValue.hasPrefix("Opens in ") }.count == 1)

        pane.show(pgAudio(), path: "/audio/memo.m4a", image: pgPicture())
        pgSettle(pane)
        #expect(pgField(pane, "Opens at 02:10") != nil, "shown \(pgFields(pane).map(\.stringValue))")
        #expect(pgFields(pane).filter { $0.stringValue.hasPrefix("Opens in ") }.count == 1)

        pane.show(pgPdf(status: .changed), path: "/docs/report.pdf", image: pgPicture())
        pgSettle(pane)
        #expect(pgField(pane, "changed since indexed") != nil)

        let gone = PreviewReply(ticket: 9, status: .gone, png: nil, name: "report.pdf", kind: "pdf", size: nil, mtime: nil)
        pane.show(gone, path: "/docs/report.pdf", image: nil)
        pgSettle(pane)
        #expect(pgField(pane, "That file is no longer there") != nil)
        pane.notice = "That file is no longer there"
        pgSettle(pane)
        #expect(pgFields(pane).filter { $0.stringValue == "That file is no longer there" }.count == 1)
    }

    @MainActor
    @Test func theFrameIsDrawnOnlyWhileAPictureOrAPassageIsShownAndIsHiddenOtherwise() throws {
        func drawn(_ pane: Pane) -> Int {
            pgSettle(pane)
            return prViews(pane.view).filter { pgShown($0) && $0.layer?.cornerRadius == 10 }.count
        }
        let gone = PreviewReply(ticket: 9, status: .gone, png: nil, name: "report.pdf", kind: "pdf", size: nil, mtime: nil)
        for look in DTLook.allCases {
            let pane = pgPane(look: look)
            #expect(drawn(pane) == 0, "\(look): an empty new pane draws a frame")
            pane.show(pgPdf(), path: "/docs/report.pdf", image: pgPicture())
            #expect(drawn(pane) == 1, "\(look): a shown picture has no visible frame")
            pane.clear()
            #expect(drawn(pane) == 0, "\(look): a cleared pane still draws its frame")
            pane.show(pgDoc(), path: "/docs/tenancy.docx", image: nil)
            #expect(drawn(pane) == 1, "\(look): a shown passage has no visible frame")
            pane.clear()
            #expect(drawn(pane) == 0, "\(look): a cleared pane still draws its frame after a passage")
            pane.showPending(path: "/docs/report.pdf")
            #expect(drawn(pane) == 0, "\(look): a pending preview with no picture draws a frame")
            pane.show(pgPhoto(), path: "/photos/beach.jpg", image: pgPicture())
            #expect(drawn(pane) == 1, "\(look): a shown photo has no visible frame")
            pane.show(gone, path: "/docs/report.pdf", image: nil)
            #expect(drawn(pane) == 0, "\(look): a file that is gone draws an empty frame")
            #expect(pgField(pane, "That file is no longer there") != nil, "\(look): the gone notice is not shown")
        }
    }

    @MainActor
    @Test func aClearedPaneStillHoldsNoPictureAndNoTextInsideItsFrame() throws {
        let pane = pgPane()
        pane.show(pgPdf(), path: "/docs/report.pdf", image: pgPicture())
        pane.clear()
        pgSettle(pane)
        #expect(prImages(pane.view).isEmpty, "an image view still holds a picture")
        #expect(pgFields(pane).isEmpty, "texts left: \(pgFields(pane).map(\.stringValue))")
        #expect(pgPictureView(pane)?.accessibilityLabel() == "Preview picture")
    }
}
