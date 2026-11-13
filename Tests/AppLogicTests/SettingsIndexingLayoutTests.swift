import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let siStart = "Start indexing"
private let siLogin = "Launch at login"
private let siLoginNote = "The shortcut works only while Sesame is running."
private let siLoginFailure = "Could not change Launch at login."
private let siDelete = "Delete index\u{2026}"
private let siDeleteConfirm = "Delete index"
private let siDeleteMessage = "Delete the index? Sesame forgets what it has read and starts again when you press Start indexing. Your files and folders are not touched."
private let siDeleteFailure = "Could not delete the index."
private let siListLabel = "Files Sesame could not read"
private let siEmpty = "Nothing here. Files Sesame could not read are listed here."
private let siLongName = String(repeating: "a-very-long-file-name-", count: 6) + "end.jpg"

@MainActor
private func siSection(_ window: SettingsContainerWindow, _ look: DTLook = .light) throws -> (NSView, SettingsIndexingView) {
    let root = sxLayout(window, .indexing, look)
    return (root, try #require(syIndexingSection(root), "no Indexing section view"))
}

@MainActor
private func siSwitches(_ section: NSView) -> [NSSwitch] {
    prViews(section).compactMap { $0 as? NSSwitch }.filter { plVisible($0) }
}

@MainActor
private func siLoginSwitch(_ section: NSView) -> NSSwitch? {
    siSwitches(section).first { ($0.accessibilityLabel() ?? "") == siLogin }
}

@MainActor
private func siAddUnreadable(_ store: IndexStore, _ path: String, status: String, reason: String?, inode: Int64) throws {
    _ = try store.addFile(path: path, kind: "photo", size: 100, mtimeNs: 1_700_000_000_000_000_000, inode: inode, device: 1, status: status)
    guard let reason else { return }
    let queue = try store.pendingPhotos(limit: 50)
    let row = try #require(queue.first { $0.path == path }, "setup: pendingPhotos does not list \(path)")
    _ = try store.markCouldNotRead(row, reason: reason)
}

extension ModelDownloadTests {
    @Suite("SettingsIndexingLayoutTests", .serialized)
    struct SettingsIndexingLayoutTests {

        @MainActor
        @Test func startIndexingIsAnAccentPushButtonWithNoKeyEquivalentAndDeleteIndexIsABorderlessRedOneBothInCards() async throws {
            let services = SYServices()
            try await sxWithWindow([], make: services.window) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try siSection(window, look)
                    #expect(plVisible(section))
                    let starts = sxButtons(section, titled: siStart)
                    #expect(starts.count == 1, "\(look): \(starts.count) Start indexing buttons")
                    let start = try #require(starts.first)
                    #expect(start.isEnabled, "\(look): Start indexing is disabled")
                    #expect(start.isBordered && start.bezelStyle == .rounded, "\(look): Start indexing is not a rounded push button")
                    #expect(sxColour(start.bezelColor, is: .controlAccentColor), "\(look): Start indexing bezel colour \(String(describing: start.bezelColor))")
                    #expect(start.keyEquivalent.isEmpty, "\(look): Start indexing key equivalent \(start.keyEquivalent.debugDescription)")
                    #expect(start.accessibilityLabel() == siStart)

                    let deletes = sxButtons(section, titled: siDelete)
                    #expect(deletes.count == 1, "\(look): \(deletes.count) Delete index buttons")
                    let delete = try #require(deletes.first)
                    #expect(!delete.isBordered && delete.bezelColor == nil && delete.keyEquivalent.isEmpty, "\(look): Delete index\u{2026} is not a borderless button")
                    let deleteInks = sxInks(delete)
                    #expect(!deleteInks.isEmpty && deleteInks.allSatisfy { sxColour($0, is: .systemRed) }, "\(look): Delete index\u{2026} is inked \(deleteInks)")
                    #expect(delete.accessibilityLabel() == siDelete)
                    #expect(delete.isEnabled)

                    for button in sxVisibleButtons(section) {
                        #expect(button.keyEquivalent.isEmpty, "\(look): \(button.title) has key equivalent \(button.keyEquivalent.debugDescription)")
                    }
                    for card in sxVisibleCards(section) { syExpectHugs(root, card, look) }
                    let sectionBox = plBox(root, section)
                    for button in [start, delete] {
                        let card = try #require(sxCard(of: button), "\(look): \(button.title) is in no card")
                        let cardBox = plBox(root, card)
                        let box = sxAlignBox(root, button)
                        #expect(abs(cardBox.minX - sectionBox.minX) <= 1 && abs(cardBox.maxX - sectionBox.maxX) <= 1, "\(look): the card of \(button.title) spans \(cardBox.minX) to \(cardBox.maxX)")
                        #expect(abs((box.minX - cardBox.minX) - 14) <= 1 && cardBox.maxX - box.maxX >= 13.5, "\(look): \(button.title) spans \(box.minX) to \(box.maxX) in a card from \(cardBox.minX) to \(cardBox.maxX)")
                    }
                }
            }
        }

        @MainActor
        @Test func launchAtLoginIsASystemSwitchAtTheRightOfItsRowWithItsNoteUnderItsNameInOneCardAndAPressChangesTheLoginItem() async throws {
            let services = SYServices()
            try await sxWithWindow([], make: services.window) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try siSection(window, look)
                    let switches = siSwitches(section)
                    #expect(switches.count == 1, "\(look): \(switches.count) NSSwitch in the Indexing section")
                    #expect(sxButtons(section, titled: siLogin).isEmpty, "\(look): an NSButton titled Launch at login")
                    let login = try #require(siLoginSwitch(section), "\(look): no switch labelled Launch at login")
                    #expect(login.accessibilityLabel() == siLogin, "\(look): label \"\(login.accessibilityLabel() ?? "nil")\"")
                    #expect(login.state == .on, "\(look): state \(login.state.rawValue)")
                    #expect(login.isEnabled)

                    let note = try #require(plText(section, siLoginNote), "\(look): the note is not shown: \(plTexts(section).map(\.stringValue))")
                    #expect(sxColour(note.textColor, is: .secondaryLabelColor), "\(look): note colour")
                    #expect(sxFont(note.font, size: 11.5, weight: .regular), "\(look): note font \(String(describing: note.font))")
                    let card = try #require(sxCard(of: login), "\(look): Launch at login is in no card")
                    #expect(sxCard(of: note) === card, "\(look): the note is not in the card of Launch at login")
                    let name = try #require(plText(section, siLogin), "\(look): the name is not shown: \(plTexts(section).map(\.stringValue))")
                    #expect(sxCard(of: name) === card, "\(look): the name is not in the card of Launch at login")
                    let noteBox = sxAlignBox(root, note)
                    let nameBox = sxAlignBox(root, name)
                    let loginBox = plBox(root, login)
                    let cardBox = plBox(root, card)
                    #expect(noteBox.top >= nameBox.bottom - 0.5, "\(look): the note starts at \(noteBox.top), the name ends at \(nameBox.bottom)")
                    #expect(abs(noteBox.minX - nameBox.minX) <= 0.5, "\(look): the note starts at \(noteBox.minX), the name at \(nameBox.minX)")
                    #expect(abs((nameBox.minX - cardBox.minX) - 14) <= 1, "\(look): the name starts \(nameBox.minX - cardBox.minX) in from the card's left edge")
                    #expect(abs((cardBox.maxX - loginBox.maxX) - 14) <= 1, "\(look): the switch ends \(cardBox.maxX - loginBox.maxX) from the card's right edge")
                    #expect(noteBox.maxX <= loginBox.minX - 12 + 0.5, "\(look): the note ends at \(noteBox.maxX), the switch starts at \(loginBox.minX)")
                }

                let (_, section) = try siSection(window)
                let login = try #require(siLoginSwitch(section))
                login.performClick(nil)
                await Task.yield()
                var again = try siSection(window)
                var pressed = try #require(siLoginSwitch(again.1))
                #expect(pressed.state == .off, "state after a press")
                #expect(services.login.status == .notRegistered, "the login item after a press: \(services.login.status)")
                pressed.performClick(nil)
                await Task.yield()
                again = try siSection(window)
                pressed = try #require(siLoginSwitch(again.1))
                #expect(pressed.state == .on, "state after a second press")
                #expect(services.login.status == .enabled, "the login item after a second press: \(services.login.status)")
            }
        }

        @MainActor
        @Test func theDeleteConfirmIsASecondCardWithTheMessageCancelAtTheLeftAndAPlainConfirmAtTheRight() async throws {
            let services = SYServices()
            try await sxWithWindow([], make: services.window) { window, _ in
                var (root, section) = try siSection(window)
                #expect(plText(section, siDeleteMessage) == nil && sxButtons(section, titled: "Cancel").isEmpty && sxButtons(section, titled: siDeleteConfirm).isEmpty, "the confirm is visible before a press")
                let delete = try #require(sxButtons(section, titled: siDelete).first)
                delete.performClick(nil)
                await Task.yield()

                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(syIndexingSection(root))
                    let message = try #require(plText(section, siDeleteMessage), "\(look): the message is not shown: \(plTexts(section).map(\.stringValue))")
                    let confirmCard = try #require(sxCard(of: message), "\(look): the message is in no card")
                    let deleteButton = try #require(sxButtons(section, titled: siDelete).first, "\(look): no Delete index\u{2026}")
                    let deleteCard = try #require(sxCard(of: deleteButton), "\(look): Delete index\u{2026} is in no card")
                    #expect(confirmCard !== deleteCard, "\(look): the confirm shares the card of Delete index\u{2026}")

                    let cancels = sxButtons(section, titled: "Cancel")
                    let confirms = sxButtons(section, titled: siDeleteConfirm)
                    #expect(cancels.count == 1 && confirms.count == 1, "\(look): \(cancels.count) Cancel and \(confirms.count) confirm buttons")
                    let cancel = try #require(cancels.first)
                    let confirm = try #require(confirms.first)
                    #expect(cancel.isDescendant(of: confirmCard) && confirm.isDescendant(of: confirmCard), "\(look): a button is outside the confirm card")
                    for button in [cancel, confirm] {
                        #expect(sxIsPlainPush(button), "\(look): \(button.title) is not a plain push button")
                        #expect(sxInks(button).allSatisfy { !sxColour($0, is: .systemRed) }, "\(look): \(button.title) is red")
                        #expect(button.isEnabled)
                    }
                    #expect(cancel.accessibilityLabel() == "Cancel" && confirm.accessibilityLabel() == siDeleteConfirm)

                    syExpectHugs(root, confirmCard, look)
                    let cardBox = plBox(root, confirmCard)
                    let cancelBox = sxAlignBox(root, cancel)
                    let confirmBox = sxAlignBox(root, confirm)
                    #expect(cancelBox.minX - cardBox.minX >= 12 && cancelBox.minX - cardBox.minX <= 28, "\(look): Cancel starts \(cancelBox.minX - cardBox.minX) pt from the card's left edge")
                    #expect(cardBox.maxX - confirmBox.maxX >= 12 && cardBox.maxX - confirmBox.maxX <= 28, "\(look): the confirm button ends \(cardBox.maxX - confirmBox.maxX) pt from the card's right edge")
                    #expect(cancelBox.maxX < confirmBox.minX && cancelBox.midX < cardBox.midX && confirmBox.midX > cardBox.midX, "\(look): Cancel and the confirm button are not on the two sides")
                    #expect(abs(cancelBox.top - confirmBox.top) <= 2 && abs(cancelBox.bottom - confirmBox.bottom) <= 2, "\(look): the two buttons are not in one row")

                    let messageBox = sxAlignBox(root, message)
                    #expect(abs((messageBox.minX - cardBox.minX) - 14) <= 1 && messageBox.maxX <= cardBox.maxX - 13.5, "\(look): the message spans \(messageBox.minX) to \(messageBox.maxX) in a card from \(cardBox.minX) to \(cardBox.maxX)")
                    #expect(abs((cancelBox.minX - cardBox.minX) - 14) <= 1 && abs((cardBox.maxX - confirmBox.maxX) - 14) <= 1, "\(look): Cancel starts \(cancelBox.minX - cardBox.minX) in and the confirm button ends \(cardBox.maxX - confirmBox.maxX) from the card's edges")
                    #expect(!messageBox.intersects(plBox(root, cancel)) && !messageBox.intersects(plBox(root, confirm)), "\(look): the message overlaps a button")
                    #expect(messageBox.bottom <= plBox(root, cancel).top + 0.5, "\(look): the message is not above the buttons")
                    #expect(sxFont(message.font, size: 13, weight: .regular), "\(look): message font \(String(describing: message.font))")
                    #expect(sxColour(message.textColor, is: .labelColor), "\(look): message colour")
                    #expect(message.frame.height > 0 && messageBox.height <= 60, "\(look): the message is \(messageBox.height) pt tall")
                }

                try #require(sxButtons(section, titled: "Cancel").first).performClick(nil)
                await Task.yield()
                root = sxRelayout(window)
                section = try #require(syIndexingSection(root))
                #expect(plText(section, siDeleteMessage) == nil, "the confirm stayed after Cancel")
            }
        }

        @MainActor
        @Test func theCouldNotReadListSitsInACardWithItsEmptyTextAndNoBezelScrollBox() async throws {
            let services = SYServices()
            try await sxWithWindow([], make: services.window) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try siSection(window, look)
                    #expect(!prViews(section).contains { $0 is NSScrollView }, "\(look): a scroll view inside the Indexing section")
                    #expect(!prViews(section).contains { $0 is NSBox }, "\(look): an NSBox inside the Indexing section")
                    for scroll in sxAncestors(section).compactMap({ $0 as? NSScrollView }) {
                        #expect(scroll.borderType == .noBorder, "\(look): a scroll view around the section has a bezel border")
                    }
                    let empty = try #require(plText(section, siEmpty), "\(look): the empty text is not shown: \(plTexts(section).map(\.stringValue))")
                    #expect(sxColour(empty.textColor, is: .secondaryLabelColor), "\(look): empty text colour")
                    #expect(sxFont(empty.font, size: 13, weight: .regular), "\(look): empty text font \(String(describing: empty.font))")
                    let card = try #require(sxCard(of: empty), "\(look): the empty text is in no card")
                    let cardBox = plBox(root, card)
                    let emptyBox = sxAlignBox(root, empty)
                    #expect(abs((emptyBox.minX - cardBox.minX) - 14) <= 1 && emptyBox.maxX <= cardBox.maxX - 13.5, "\(look): the empty text spans \(emptyBox.minX) to \(emptyBox.maxX) in a card from \(cardBox.minX) to \(cardBox.maxX)")
                    #expect(abs(cardBox.minX - 197) <= 1 && abs(cardBox.maxX - 704) <= 1, "\(look): the list card spans \(cardBox.minX) to \(cardBox.maxX)")

                    let labels = plTexts(section).filter { $0.stringValue == siListLabel }
                    #expect(labels.count == 1, "\(look): \(labels.count) list labels")
                    let label = try #require(labels.first)
                    #expect(sxFont(label.font, size: 13, weight: .semibold), "\(look): list label font \(String(describing: label.font))")
                    #expect(sxCard(of: label) == nil, "\(look): the list label is inside a card")
                    let labelBox = sxAlignBox(root, label)
                    #expect(labelBox.bottom <= cardBox.top + 0.5 && cardBox.top - labelBox.bottom <= 20, "\(look): the list label ends \(cardBox.top - labelBox.bottom) pt above the card")
                }
            }
        }

        @MainActor
        @Test func theCouldNotReadListShowsEachRowInTheCardAndShortensALongNameInTheMiddle() async throws {
            let services = SYServices()
            try await sxWithWindow([], make: services.window) { window, _ in
                let store = try IndexStore()
                defer { store.close() }
                try siAddUnreadable(store, "/photos/locked.jpg", status: "needs_permission", reason: nil, inode: 1)
                try siAddUnreadable(store, "/photos/trip/broken.jpg", status: "pending", reason: "damaged", inode: 2)
                try siAddUnreadable(store, "/photos/" + siLongName, status: "pending", reason: "damaged", inode: 3)
                try siAddUnreadable(store, "/photos/fine.jpg", status: "done", reason: nil, inode: 4)
                let rows = ["locked.jpg", "broken.jpg", siLongName]

                for look in DTLook.allCases {
                    let (root, section) = try siSection(window, look)
                    #expect(!prViews(section).contains { $0 is NSScrollView }, "\(look): a scroll view inside the Indexing section")
                    #expect(!prViews(section).contains { $0 is NSBox }, "\(look): an NSBox inside the Indexing section")
                    #expect(plText(section, siEmpty) == nil, "\(look): the empty text is shown beside rows")
                    #expect(plText(section, "fine.jpg") == nil && !plTexts(section).contains { $0.stringValue.hasPrefix("fine.jpg") }, "\(look): a file that was read is listed")
                    let fields = try rows.map { try #require(plText(section, $0), "\(look): no row \"\($0)\": \(plTexts(section).map(\.stringValue))") }
                    let card = try #require(sxCard(of: fields[0]), "\(look): the first row is in no card")
                    syExpectHugs(root, card, look)
                    let cardBox = plBox(root, card)
                    #expect(abs(cardBox.minX - 197) <= 1 && abs(cardBox.maxX - 704) <= 1, "\(look): the list card spans \(cardBox.minX) to \(cardBox.maxX)")
                    for field in fields {
                        #expect(sxCard(of: field) === card, "\(look): \"\(field.stringValue)\" is in another card")
                        #expect(sxColour(field.textColor, is: .labelColor), "\(look): row name colour")
                        #expect(sxFont(field.font, size: 12.5, weight: .semibold), "\(look): row name font \(String(describing: field.font))")
                        #expect(field.lineBreakMode == .byTruncatingMiddle, "\(look): \"\(field.stringValue)\" line break mode \(field.lineBreakMode.rawValue)")
                        #expect(field.frame.height <= 24, "\(look): \"\(field.stringValue)\" is \(field.frame.height) pt tall: it wraps")
                        let box = sxAlignBox(root, field)
                        #expect(abs((box.minX - cardBox.minX) - 14) <= 1 && box.maxX <= cardBox.maxX - 13.5, "\(look): \"\(field.stringValue)\" spans \(box.minX) to \(box.maxX) in a card from \(cardBox.minX) to \(cardBox.maxX)")
                    }
                    let natural = (siLongName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width
                    #expect(fields[2].frame.width < natural, "\(look): the long name is \(fields[2].frame.width) pt wide for \(natural) pt of text: it was not shortened")
                    let tops = fields.map { plBox(root, $0).top }
                    #expect(Set(tops).count == 3, "\(look): two rows share a line: \(tops)")
                }
            }
        }

        @MainActor
        @Test func theSectionDrawsNoHeadingOfItsOwnAndNoBezelBox() async throws {
            let services = SYServices()
            try await sxWithWindow([], make: services.window) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try siSection(window, look)
                    syExpectPlainSection(root, section, name: "Indexing", look)
                    syExpectNoWarning(section, look)
                }
            }
        }

        @MainActor
        @Test func aRefusedLoginChangeCarriesTheWarningSymbolBesideTheExistingTextAndTheNextStepLine() async throws {
            let services = SYServices()
            try await sxWithWindow([], make: services.window) { window, _ in
                var (root, section) = try siSection(window)
                #expect(plText(section, siLoginFailure) == nil, "a failure before anything went wrong")
                services.login.refuse(true)
                try #require(siLoginSwitch(section)).performClick(nil)
                await Task.yield()

                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(syIndexingSection(root))
                    syExpectWarningLine(root, section, text: siLoginFailure, red: true, look)
                }

                services.login.refuse(false)
                try #require(siLoginSwitch(section)).performClick(nil)
                await Task.yield()
                root = sxRelayout(window)
                section = try #require(syIndexingSection(root))
                #expect(plText(section, siLoginFailure) == nil, "the failure stayed after a change that worked")
                syExpectNoWarning(section, .light)
            }
        }

        @MainActor
        @Test func aFailedDeleteCarriesTheWarningSymbolBesideTheExistingTextAndTheNextStepLine() async throws {
            let services = SYServices(deleteFails: true)
            try await sxWithWindow([], make: services.window) { window, _ in
                var (root, section) = try siSection(window)
                #expect(plText(section, siDeleteFailure) == nil, "a failure before anything went wrong")
                try #require(sxButtons(section, titled: siDelete).first).performClick(nil)
                await Task.yield()
                root = sxRelayout(window)
                section = try #require(syIndexingSection(root))
                try #require(sxButtons(section, titled: siDeleteConfirm).first).performClick(nil)
                await Task.yield()

                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(syIndexingSection(root))
                    syExpectWarningLine(root, section, text: siDeleteFailure, red: true, look)
                }
            }
        }
    }
}
