import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let slmMessage = "Could not change Launch at login."

private final class SLMService: LoginService, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginStatus = .notRegistered
    private var refuses = true

    var status: LoginStatus {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func refuse(_ on: Bool) {
        lock.lock()
        refuses = on
        lock.unlock()
    }

    func register() throws {
        lock.lock()
        defer { lock.unlock() }
        if refuses { throw SYRefused() }
        current = .enabled
    }

    func unregister() throws {
        lock.lock()
        defer { lock.unlock() }
        if refuses { throw SYRefused() }
        current = .notRegistered
    }
}

@MainActor
private func slmWindow(_ model: SettingsModel, _ item: LoginItem, glass: Bool) -> SettingsContainerWindow {
    let window = SettingsContainerWindow(
        model: model, shortcut: ShortcutControl(), loginItem: item,
        appChoices: AppChoices(lookup: SYLookup(installed: [])), deleteIndex: SettingsContainerWindow.unwiredDeleteIndex(),
        glass: glass)
    window.isReleasedWhenClosed = false
    window.refresh()
    return window
}

@MainActor
private func slmRun(
    glass: Bool,
    _ body: @MainActor (SettingsModel, SLMService, LoginItem, () -> SettingsContainerWindow) async throws -> Void
) async throws {
    let service = SLMService()
    let item = LoginItem(service: service)
    var model: SettingsModel?
    try await sxWithWindow([], make: { made in
        model = made
        return slmWindow(made, item, glass: glass)
    }) { _, _ in
        let shared = try #require(model, "no model was made")
        try await body(shared, service, item) {
            return slmWindow(shared, item, glass: glass)
        }
    }
}

@MainActor
private func slmShown(_ window: SettingsContainerWindow) -> (onScreen: Bool, inScreen: Bool) {
    let root = sxLayout(window, .indexing)
    let section = syIndexingSection(root)
    return (section.flatMap { plText($0, slmMessage) } != nil, window.settingsScreen.texts.contains(slmMessage))
}

extension ModelDownloadTests.SettingsOpenAndRecordingTests {

    @MainActor
    @Test func clearMessageEmptiesTheLoginItemsMessageAndIsHarmlessWithNone() async throws {
        try await spWithHome { _ in
            let service = SLMService()
            let item = LoginItem(service: service)
            item.clearMessage()
            #expect(item.message == nil)
            item.set(on: true)
            #expect(item.message == slmMessage, "message \(item.message ?? "nil")")
            item.clearMessage()
            #expect(item.message == nil, "clearMessage left \(item.message ?? "nil")")
            item.clearMessage()
            #expect(item.message == nil)
            #expect(item.isOn == false, "clearMessage changed the live status")
        }
    }

    @MainActor
    @Test(arguments: slPaths)
    func anOldFailureShowsOnAReopenedWindowUntilClearStaleMessagesOnOpenRunsThenItIsGoneAndAFailureAfterTheOpenShowsAgain(glass: Bool) async throws {
        try await slmRun(glass: glass) { model, service, item, reopen in
            let first = slmWindow(model, item, glass: glass)
            #expect(slmShown(first) == (false, false), "a failure before anything went wrong")
            item.set(on: true)
            #expect(item.message == slmMessage, "message \(item.message ?? "nil")")
            first.refresh()
            #expect(slmShown(first) == (true, true), "the failure is not shown on the window it happened in")

            let second = reopen()
            #expect(item.message == slmMessage, "building a window cleared the message")
            #expect(slmShown(second) == (true, true), "the failure is not on the second window before the open")

            second.clearStaleMessagesOnOpen()
            #expect(item.message == nil, "the message after the open is \(item.message ?? "nil")")
            second.refresh()
            #expect(slmShown(second) == (false, false), "the failure is still shown after the open")

            second.clearStaleMessagesOnOpen()
            #expect(item.message == nil, "a second call changed the message to \(item.message ?? "nil")")
            #expect(slmShown(second) == (false, false))

            item.set(on: true)
            #expect(item.message == slmMessage, "a failure after the open did not set the message")
            second.refresh()
            #expect(slmShown(second) == (true, true), "a failure after the open is not shown")
            #expect(service.status == .notRegistered)
        }
    }

    @MainActor
    @Test(arguments: slPaths)
    func aFailureFromLaunchIsClearedByTheFirstOpen(glass: Bool) async throws {
        try await slmRun(glass: glass) { model, service, item, reopen in
            item.applyFirstRunDefault()
            #expect(item.message == slmMessage, "the launch-time failure left the message \(item.message ?? "nil")")
            service.refuse(false)

            let window = reopen()
            #expect(slmShown(window) == (true, true), "the launch-time failure is not on the first window before the open")
            window.clearStaleMessagesOnOpen()
            #expect(item.message == nil, "the message after the first open is \(item.message ?? "nil")")
            window.refresh()
            #expect(slmShown(window) == (false, false), "the launch-time failure is still shown after the first open")
        }
    }

    @MainActor
    @Test(arguments: slPaths)
    func clearStaleMessagesOnOpenTouchesNothingElse(glass: Bool) async throws {
        try await slmRun(glass: glass) { model, service, item, reopen in
            service.refuse(false)
            item.set(on: true)
            #expect(item.isOn == true)
            let window = reopen()
            let before = window.settingsScreen.texts
            window.clearStaleMessagesOnOpen()
            #expect(item.isOn == true, "the open changed the live status")
            #expect(item.message == nil)
            #expect(model.errorText == nil)
            window.refresh()
            #expect(window.settingsScreen.texts == before, "the screen's texts changed: \(before) became \(window.settingsScreen.texts)")
        }
    }
}
