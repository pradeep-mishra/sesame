import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

struct PLBox {
    var minX: CGFloat
    var maxX: CGFloat
    var top: CGFloat
    var bottom: CGFloat

    var width: CGFloat { maxX - minX }
    var height: CGFloat { bottom - top }
    var midX: CGFloat { (minX + maxX) / 2 }

    func union(_ other: PLBox) -> PLBox {
        PLBox(minX: min(minX, other.minX), maxX: max(maxX, other.maxX), top: min(top, other.top), bottom: max(bottom, other.bottom))
    }

    func intersects(_ other: PLBox) -> Bool {
        minX < other.maxX && other.minX < maxX && top < other.bottom && other.top < bottom
    }
}

struct PLConditions {
    var model: ModelState = .whole
    var startPressed = true
    var indexDeleted = false
    var walkDone = true
    var counts = IndexCounts(done: 3, pending: [:], partial: [:])
    var vectorSource: (expected: String, stored: String)?

    func sources() -> StatusSources {
        var settings = Settings()
        settings.startPressed = startPressed
        settings.indexDeleted = indexDeleted
        let frozen = settings
        let model = model
        let counts = counts
        let walkDone = walkDone
        let stored = vectorSource?.stored
        return StatusSources(
            settings: { frozen },
            counts: { counts },
            meta: { key in
                if key == "walk_done_at" { return walkDone ? "1700000000" : nil }
                return key == "vector_source" ? stored : nil
            },
            modelState: { model })
    }

    func cache() -> StatusCache {
        StatusCache(sources: sources(), queue: DispatchQueue(label: "sesame.panelshell.test"), vectorSource: vectorSource?.expected)
    }

    func snapshot() -> PanelSnapshot {
        PanelSnapshot(sources: sources(), vectorSource: vectorSource?.expected)
    }
}

private let plSilentHelper = """
#!/bin/sh
while IFS= read -r line; do :; done
"""

@MainActor
func plWithPanel(_ conditions: PLConditions = PLConditions(), _ body: @MainActor (Panel) async throws -> Void) async throws {
    _ = NSApplication.shared
    try await spWithHome { _ in
        let panel = Panel()
        let cache = conditions.cache()
        panel.attach(status: cache)
        cache.refresh()
        let expected = conditions.snapshot()
        _ = await spEventually { cache.snapshot() == expected }
        await spWait(0.15)
        try await body(panel)
    }
}

@MainActor
func plWithTypingPanel(_ conditions: PLConditions = PLConditions(), _ body: @MainActor (Panel) async throws -> Void) async throws {
    _ = NSApplication.shared
    try await spWithHome { home in
        var settings = Settings()
        settings.startPressed = true
        settings.folders = [Settings.Folder(path: "/photos", code: false, reading: true)]
        try SettingsFile().write(settings)
        let panel = Panel()
        let cache = conditions.cache()
        panel.attach(status: cache)
        let helperFile = home.appendingPathComponent("silent-helper")
        try plSilentHelper.write(to: helperFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperFile.path)
        panel.attach(helper: HelperClient(helper: helperFile, textModel: home, mmModel: home))
        cache.refresh()
        let expected = conditions.snapshot()
        _ = await spEventually { cache.snapshot() == expected }
        await spWait(0.15)
        _ = panel.makeFirstResponder(panel.queryBox.field)
        try await body(panel)
    }
}

@MainActor
func plLayout(_ panel: Panel, look: DTLook = .light) -> NSView {
    let root = panel.contentView!
    root.appearance = dtAppearance(look)
    root.layoutSubtreeIfNeeded()
    return root
}

@MainActor
func plBox(_ root: NSView, _ view: NSView) -> PLBox {
    let rect = root.convert(view.bounds, from: view)
    let top = root.isFlipped ? rect.minY : root.bounds.height - rect.maxY
    return PLBox(minX: rect.minX, maxX: rect.maxX, top: top, bottom: top + rect.height)
}

@MainActor
func plFind(_ root: NSView, _ identifier: String) -> NSView? {
    prViews(root).first { $0.accessibilityIdentifier() == identifier }
}

@MainActor
func plVisible(_ view: NSView) -> Bool {
    !view.isHiddenOrHasHiddenAncestor
}

@MainActor
func plTexts(_ view: NSView) -> [NSTextField] {
    prViews(view).compactMap { $0 as? NSTextField }.filter { $0 !== view && plVisible($0) && !$0.stringValue.isEmpty }
}

@MainActor
func plText(_ view: NSView, _ text: String) -> NSTextField? {
    plTexts(view).first { $0.stringValue == text }
}

@MainActor
func plBlock(_ root: NSView, in view: NSView) -> PLBox? {
    let parts: [NSView] = plTexts(view) + prViews(view).compactMap { $0 as? NSImageView }.filter { plVisible($0) }
    let boxes = parts.map { plBox(root, $0) }
    guard let first = boxes.first else { return nil }
    return boxes.dropFirst().reduce(first) { $0.union($1) }
}

@MainActor
func plDividers(_ root: NSView) -> [NSView] {
    prViews(root).filter { $0.frame.width >= 0.5 && $0.frame.width <= 1.01 && $0.frame.height >= 400 }
}

@MainActor
func plVisibleDividers(_ root: NSView) -> [NSView] {
    plDividers(root).filter { plVisible($0) }
}

@MainActor
func plList(_ root: NSView) -> NSView? {
    prViews(root).first { $0.accessibilityLabel() == "Results" }
}

@MainActor
func plAccessibilityImages(_ view: NSView) -> [NSView] {
    prViews(view).filter { $0 !== view && $0.isAccessibilityElement() && $0.accessibilityRole() == .image }
}

@MainActor
func plRGBAOfAttribute(_ text: NSAttributedString?, _ look: DTLook) -> [CGFloat]? {
    guard let text, text.length > 0, let color = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor else { return nil }
    return dtRGBA(color, look)
}
