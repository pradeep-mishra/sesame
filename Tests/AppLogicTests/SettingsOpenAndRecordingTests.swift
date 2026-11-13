import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let oarPdfInstalled = "com.apple.Preview"
private let oarMediaInstalled = "com.apple.QuickTimePlayerX"
private let oarRecord = "Record new shortcut"
private let oarStatus = "Press the new shortcut, or Esc to cancel."
private let oarDefault = "Control Option Space"
private let oarCustom = "Option Command K"
private let oarEscapeCode: UInt16 = 53
private let oarKCode: UInt16 = 40
private let oarACode: UInt16 = 0

@MainActor
private func oarWith(
    glass: Bool,
    _ body: @MainActor (SettingsContainerWindow, ShortcutControl) async throws -> Void
) async throws {
    var made: ShortcutControl?
    try await sxWithWindow([], make: { model in
        let control = ShortcutControl()
        made = control
        return SettingsContainerWindow(
            model: model, shortcut: control, loginItem: LoginItem(service: SYLoginService()),
            appChoices: AppChoices(lookup: SYLookup(installed: [oarPdfInstalled, oarMediaInstalled])),
            deleteIndex: DeleteIndex(closeIndex: {}, sendReset: {}, deleteCaches: {}), glass: glass)
    }) { window, _ in
        try await body(window, try #require(made, "no shortcut control was made"))
    }
}

@MainActor
private func oarSearch(_ window: SettingsContainerWindow) throws -> SettingsSearchView {
    let root = sxLayout(window, .search)
    return try #require(sySearchSection(root), "no Search section view")
}

@MainActor
private func oarRelayout(_ window: SettingsContainerWindow) throws -> SettingsSearchView {
    let root = sxRelayout(window)
    return try #require(sySearchSection(root), "no Search section view")
}

@MainActor
private func oarStartRecording(_ window: SettingsContainerWindow) throws -> SettingsSearchView {
    let section = try oarSearch(window)
    try #require(sxButtons(section, titled: oarRecord).first, "no Record button").performClick(nil)
    #expect(section.shortcutView.isRecording, "a press of Record did not start recording")
    return section
}

@MainActor
private func oarKey(_ window: NSWindow, code: UInt16, flags: NSEvent.ModifierFlags, characters: String) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
}

@MainActor
private func oarMouse(_ window: NSWindow, _ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1)!
}

@MainActor
private func oarClick(_ window: NSWindow, _ down: NSEvent.EventType, at point: NSPoint) {
    window.sendEvent(oarMouse(window, down, at: point))
}

@MainActor
private func oarPointOver(_ view: NSView) -> NSPoint {
    view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
}

@MainActor
private func oarTitleStripPoint(_ window: SettingsContainerWindow) throws -> NSPoint {
    let root = try #require(window.contentView, "no content view")
    let y = root.isFlipped ? root.bounds.minY + 10 : root.bounds.maxY - 10
    return root.convert(NSPoint(x: root.bounds.midX, y: y), to: nil)
}

@MainActor
private func oarResign(_ window: SettingsContainerWindow) throws {
    let delegate = try #require(window.delegate, "the window has no delegate")
    delegate.windowDidResignKey?(Notification(name: NSWindow.didResignKeyNotification, object: window))
}

@MainActor
private func oarExpectKeyNotTaken(_ window: SettingsContainerWindow, _ shortcut: ShortcutControl, _ tag: String) throws {
    window.sendEvent(oarKey(window, code: oarACode, flags: [], characters: "a"))
    #expect(shortcut.message == nil, "\(tag): a plain key press after recording stopped was taken as a shortcut and refused with \"\(shortcut.message ?? "nil")\"")
    let section = try oarRelayout(window)
    #expect(!section.shortcutView.isRecording, "\(tag): recording came back on")
    let row = prViews(section).compactMap { $0 as? KeycapRow }.first { plVisible($0) }
    #expect(row?.accessibilityLabel() == oarDefault, "\(tag): the keys read \"\(row?.accessibilityLabel() ?? "nil")\"")
}

extension ModelDownloadTests {
    @Suite("SettingsOpenAndRecordingTests", .serialized)
    struct SettingsOpenAndRecordingTests {

        @MainActor
        @Test(arguments: slPaths)
        func whenTheWindowStopsBeingKeyRecordingStopsTheStatusLineGoesAndTheNextKeyIsNotTakenAsAShortcut(glass: Bool) async throws {
            try await oarWith(glass: glass) { window, shortcut in
                let section = try oarStartRecording(window)
                _ = try oarRelayout(window)
                #expect(plText(section, oarStatus) != nil, "the status line is not shown while recording")

                try oarResign(window)

                #expect(!section.shortcutView.isRecording, "the window stopped being key and recording is still on")
                let again = try oarRelayout(window)
                #expect(plText(again, oarStatus) == nil, "the status line stayed after the window stopped being key")
                try oarExpectKeyNotTaken(window, shortcut, "after the window stopped being key")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func recordingStartedAgainAfterTheWindowStoppedBeingKeyWorksAndTakesTheKey(glass: Bool) async throws {
            try await oarWith(glass: glass) { window, shortcut in
                _ = try oarStartRecording(window)
                try oarResign(window)
                let section = try oarStartRecording(window)
                #expect(section.shortcutView.isRecording)

                window.sendEvent(oarKey(window, code: oarKCode, flags: [.command, .option], characters: "k"))

                let after = try oarRelayout(window)
                #expect(!after.shortcutView.isRecording, "still recording after a key")
                let row = try #require(prViews(after).compactMap { $0 as? KeycapRow }.first { plVisible($0) })
                #expect(row.accessibilityLabel() == oarCustom, "the keys read \"\(row.accessibilityLabel() ?? "nil")\" after cmd+opt+k")
                #expect(shortcut.message == nil, "message \(shortcut.message ?? "nil")")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aResignInEverySectionLeavesNothingRecordingAndNoKeyIsTakenAsAShortcut(glass: Bool) async throws {
            try await oarWith(glass: glass) { window, shortcut in
                for section in [SettingsScreen.Section.folders, .fileTypes, .search, .indexing] {
                    _ = sxLayout(window, section)
                    try oarResign(window)
                    let search = try oarSearch(window)
                    #expect(!search.shortcutView.isRecording, "\(section.title): recording is on after a resign")
                    try oarExpectKeyNotTaken(window, shortcut, "after a resign on \(section.title)")
                }
                for section in [SettingsScreen.Section.folders, .fileTypes, .indexing] {
                    _ = try oarStartRecording(window)
                    _ = sxLayout(window, section)
                    try oarResign(window)
                    let search = try oarSearch(window)
                    #expect(!search.shortcutView.isRecording, "started on Search, moved to \(section.title), resigned: recording is on")
                    try oarExpectKeyNotTaken(window, shortcut, "started on Search, moved to \(section.title), resigned")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aLeftMouseDownOverAnAppPopUpStopsRecordingAndTheNextKeyIsNotTakenAsAShortcut(glass: Bool) async throws {
            try await oarWith(glass: glass) { window, shortcut in
                for label in ["PDF app", "Media app"] {
                    let section = try oarStartRecording(window)
                    let popup = try #require(syPopUp(section, labelled: label), "no \(label) pop-up")
                    let point = oarPointOver(popup)

                    oarClick(window, .leftMouseDown, at: point)

                    #expect(!section.shortcutView.isRecording, "\(label): recording stayed on after a click on the pop-up")
                    try oarExpectKeyNotTaken(window, shortcut, "after a click on \(label)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aRightMouseDownOverAnAppPopUpStopsRecording(glass: Bool) async throws {
            try await oarWith(glass: glass) { window, shortcut in
                let section = try oarStartRecording(window)
                let popup = try #require(syPopUp(section, labelled: "PDF app"), "no PDF app pop-up")
                let point = oarPointOver(popup)

                oarClick(window, .rightMouseDown, at: point)

                #expect(!section.shortcutView.isRecording, "recording stayed on after a right click on the pop-up")
                try oarExpectKeyNotTaken(window, shortcut, "after a right click on the pop-up")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aMouseDownOnTheTitleStripOfAnyKindStopsRecording(glass: Bool) async throws {
            try await oarWith(glass: glass) { window, shortcut in
                for (name, down) in [("left", NSEvent.EventType.leftMouseDown), ("right", .rightMouseDown), ("other", .otherMouseDown)] {
                    let section = try oarStartRecording(window)
                    let point = try oarTitleStripPoint(window)

                    oarClick(window, down, at: point)

                    #expect(!section.shortcutView.isRecording, "recording stayed on after a \(name) mouse-down on the title strip")
                    try oarExpectKeyNotTaken(window, shortcut, "after a \(name) mouse-down on the title strip")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aClickElsewhereDoesNotDisturbAWindowThatIsNotRecordingAndRecordStartsAgainWithItsOwnPress(glass: Bool) async throws {
            try await oarWith(glass: glass) { window, shortcut in
                let section = try oarSearch(window)
                let point = try oarTitleStripPoint(window)
                oarClick(window, .leftMouseDown, at: point)
                #expect(!section.shortcutView.isRecording, "a click started recording")
                #expect(shortcut.message == nil)

                let recording = try oarStartRecording(window)
                oarClick(window, .leftMouseDown, at: point)
                #expect(!recording.shortcutView.isRecording, "recording stayed on after the click")

                try #require(sxButtons(recording, titled: oarRecord).first).performClick(nil)
                #expect(recording.shortcutView.isRecording, "a press of Record after a click did not start recording")
                _ = try oarRelayout(window)
                window.sendEvent(oarKey(window, code: oarKCode, flags: [.command, .option], characters: "k"))
                let after = try oarRelayout(window)
                #expect(!after.shortcutView.isRecording)
                let row = try #require(prViews(after).compactMap { $0 as? KeycapRow }.first { plVisible($0) })
                #expect(row.accessibilityLabel() == oarCustom, "the keys read \"\(row.accessibilityLabel() ?? "nil")\"")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func withNoClickAndNoResignEscapeStillCancelsAndACombinationStillRecords(glass: Bool) async throws {
            try await oarWith(glass: glass) { window, shortcut in
                var section = try oarStartRecording(window)
                window.sendEvent(oarKey(window, code: oarEscapeCode, flags: [], characters: "\u{1B}"))
                section = try oarRelayout(window)
                #expect(!section.shortcutView.isRecording, "still recording after Escape")
                #expect(shortcut.message == nil, "Escape left the message \(shortcut.message ?? "nil")")

                _ = try oarStartRecording(window)
                window.sendEvent(oarKey(window, code: oarKCode, flags: [.command, .option], characters: "k"))
                section = try oarRelayout(window)
                #expect(!section.shortcutView.isRecording, "still recording after a key")
                let row = try #require(prViews(section).compactMap { $0 as? KeycapRow }.first { plVisible($0) })
                #expect(row.accessibilityLabel() == oarCustom, "the keys read \"\(row.accessibilityLabel() ?? "nil")\"")

                _ = try oarStartRecording(window)
                window.sendEvent(oarKey(window, code: oarACode, flags: [], characters: "a"))
                #expect(shortcut.message != nil, "a combination with no modifier was not refused")
            }
        }
    }
}
