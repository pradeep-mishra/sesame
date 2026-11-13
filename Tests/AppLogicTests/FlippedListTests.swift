import AppKit
import Foundation
import Testing
@testable import Sesame

@MainActor
private func flBuild(rows: Int) -> (scroll: NSScrollView, rows: [NSView]) {
    let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: CGFloat(rows) * 20))
    let views: [NSView] = (0..<rows).map { index in
        NSView(frame: NSRect(x: 0, y: CGFloat(index) * 20, width: 300, height: 20))
    }
    for view in views { document.addSubview(view) }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.drawsBackground = false
    scroll.documentView = document
    scroll.layoutSubtreeIfNeeded()
    return (scroll, views)
}

@MainActor
private func flTopInClip(_ scroll: NSScrollView, _ view: NSView) -> CGFloat {
    let clip = scroll.contentView
    let rect = clip.convert(view.bounds, from: view)
    return clip.isFlipped ? rect.minY - clip.bounds.minY : clip.bounds.maxY - rect.maxY
}

@Suite("FlippedListTests")
struct FlippedListTests {

    @MainActor
    @Test func theFlippedViewIsFlipped() {
        #expect(FlippedView().isFlipped)
    }

    @MainActor
    @Test func threeRowsInAHundredPointClipStartAtTheTopWithNoGap() {
        let (scroll, rows) = flBuild(rows: 3)
        #expect(scroll.contentView.bounds.height == 100)
        #expect(abs(flTopInClip(scroll, rows[0]) - 0) <= 0.5)
        #expect(abs(flTopInClip(scroll, rows[1]) - 20) <= 0.5)
        #expect(abs(flTopInClip(scroll, rows[2]) - 40) <= 0.5)
    }

    @MainActor
    @Test func aListTallerThanTheClipOpensAtItsFirstRow() {
        let (scroll, rows) = flBuild(rows: 10)
        #expect(abs(scroll.contentView.bounds.minY - 0) <= 0.5)
        #expect(abs(flTopInClip(scroll, rows[0]) - 0) <= 0.5)
        #expect(abs(flTopInClip(scroll, rows[4]) - 80) <= 0.5)
    }
}
