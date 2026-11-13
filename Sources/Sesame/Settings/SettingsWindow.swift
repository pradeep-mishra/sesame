import AppKit
import Carbon.HIToolbox
import SesameEngine

/// What the minimal Settings window of slice 1 is: its title, the labels of the controls it holds, and the chord that
/// opens it. Slice 1 has no menu bar, so the panel's key handling opens it.
enum SettingsWindow {
    static let title = "Settings"
    /// Only the shortcut control.
    static let controlLabels = [ShortcutControl.accessibilityLabel]

    /// Command+comma, as `HotKey.combination` writes it or as a person writes it.
    static func isOpenCommand(_ combination: String) -> Bool {
        combination == "cmd+," || combination == "cmd+comma"
    }
}

/// A button that Tab always reaches. AppKit lets Tab stop on a button only when Full Keyboard Access is on.
@MainActor
private final class TabbableButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}

/// The Settings window: the shortcut as it reads now, Record new shortcut, Back to default and the status message.
/// Plain AppKit controls, so the kit finds each button by its title.
@MainActor
final class ShortcutSettingsWindow: NSWindow, NSWindowDelegate {
    static let size = NSSize(width: 440, height: 190)
    private static let contentWidth = size.width - 48

    private let control: ShortcutControl
    private var isRecording = false
    /// Called when the window has closed.
    var onClose: (@MainActor () -> Void)?

    private let shortcutField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let recordButton = TabbableButton(title: ShortcutControl.recordTitle, target: nil, action: nil)
    private let defaultButton = TabbableButton(title: ShortcutControl.backToDefaultTitle, target: nil, action: nil)

    /// True while a Settings window is on screen.
    static var isShowing: Bool {
        NSApp.windows.contains { ($0 is ShortcutSettingsWindow || $0 is SettingsContainerWindow) && $0.isVisible }
    }

    init(control: ShortcutControl) {
        self.control = control
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = SettingsWindow.title
        isReleasedWhenClosed = false
        delegate = self
        contentView = makeContent()
        setContentSize(Self.size)
        recordButton.nextKeyView = defaultButton
        defaultButton.nextKeyView = recordButton
        initialFirstResponder = recordButton
        render()
    }

    /// An accessory app that activates stays behind (see `Panel.show`), so the policy is regular while it is up.
    /// `message` is shown in the status line on opening (the launch failure); the window otherwise opens with none.
    func show(message: String? = nil) {
        isRecording = false
        control.clearMessage()
        if let message { control.report(message) }
        render()
        if !isVisible { center() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(recordButton)
    }

    func windowWillClose(_ notification: Notification) {
        isRecording = false
        onClose?()
    }

    // MARK: the views

    private func makeContent() -> NSView {
        let heading = NSTextField(labelWithString: "Open Sesame with")
        heading.font = .boldSystemFont(ofSize: 13)

        shortcutField.font = .systemFont(ofSize: 22, weight: .semibold)
        shortcutField.setAccessibilityLabel(ShortcutControl.accessibilityLabel)

        recordButton.target = self
        recordButton.action = #selector(recordPressed)
        defaultButton.target = self
        defaultButton.action = #selector(defaultPressed)
        for button in [recordButton, defaultButton] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [recordButton, defaultButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        statusField.preferredMaxLayoutWidth = Self.contentWidth

        let stack = NSStackView(views: [heading, shortcutField, buttons, statusField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        return content
    }

    /// Sets each view only when its value changed.
    private func render() {
        setText(shortcutField, control.displayText)
        if isRecording {
            statusField.textColor = .secondaryLabelColor
            setText(statusField, "Press the new shortcut, or Esc to cancel.")
        } else {
            statusField.textColor = .systemRed
            setText(statusField, control.message ?? "")
        }
        let hidden = statusField.stringValue.isEmpty
        if statusField.isHidden != hidden { statusField.isHidden = hidden }
    }

    private func setText(_ field: NSTextField, _ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }

    // MARK: the buttons and the recorder

    @objc private func recordPressed() {
        control.clearMessage()
        isRecording = true
        render()
    }

    @objc private func defaultPressed() {
        isRecording = false
        control.backToDefault()
        render()
    }

    /// While recording, the next key press is the new shortcut: nothing else sees it, so Command+W and the like are
    /// recorded, not acted on. Esc alone cancels.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, isRecording {
            record(event)
            return
        }
        super.sendEvent(event)
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        isRecording = false
        if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty {
            render()
            return
        }
        if let combination = HotKey.combination(keyCode: Int(event.keyCode), modifiers: modifiers) {
            control.record(combination)
        } else {
            control.refuseUnnamedKey()
        }
        render()
    }
}

// MARK: the container

/// Everything the Settings container shows for one section, as one value (design section 3, mockup F3): built from the
/// model and the window state, holding no view. The window draws it; a test reads it.
struct SettingsScreen {
    enum Section: String, CaseIterable, Equatable {
        case folders, fileTypes, search, indexing

        var title: String {
            switch self {
            case .folders: return "Folders"
            case .fileTypes: return "File types"
            case .search: return "Search"
            case .indexing: return "Indexing"
            }
        }
    }

    /// A control a person can reach, with its accessibility label. `isOn` is nil unless it is a switch or a tick.
    struct Control: Equatable {
        let label: String
        let isEnabled: Bool
        let isOn: Bool?

        init(label: String, isEnabled: Bool, isOn: Bool? = nil) {
            self.label = label
            self.isEnabled = isEnabled
            self.isOn = isOn
        }
    }

    struct FolderRow: Equatable {
        let path: String
        let name: String
        /// The counts, then the estimate or "Waiting for Start indexing".
        let detail: String
        let tick: Control
        let more: Control
        let reindex: Control
        let remove: Control
    }

    /// The inline question that opens when Remove is pressed.
    struct Confirm: Equatable {
        let path: String
        let message: String
        let confirmTitle: String
        let cancelTitle: String
    }

    struct Kind: Equatable {
        let key: String
        let title: String
        let control: Control
    }

    /// One "open with" pop-up of Search: the apps it offers, the one chosen and the note when that one is not installed.
    struct AppPick: Equatable {
        let kind: String
        let options: [String]
        let selected: String
        let note: String?
        let control: Control
    }

    static let kindList = [
        (key: "photo", title: "Photos"), (key: "pdf", title: "PDFs"), (key: "doc", title: "Documents"),
        (key: "audio", title: "Audio"), (key: "video", title: "Video"),
    ]
    static let foldersHeading = "Folders"
    static let fileTypesHeading = "File types"
    static let foldersSectionTitle = "Folders Sesame reads"
    static let fileTypesSectionTitle = "File types Sesame reads"
    static let foldersNote = "Tick a folder to read it. Use the more button on a row to re-index or remove it."
    static func moreLabel(_ name: String) -> String { "More actions for \(name)" }
    static let noFoldersText = "No folders. Add a folder to read it."
    static let waitingText = "Waiting for Start indexing"
    static let notReadText = "not read"
    static let reindexLabel = "Re-index"
    static let removeLabel = "Remove"
    static let removeConfirmTitle = "Remove folder"
    static let cancelTitle = "Cancel"
    static let searchHeading = "Search"
    static let shortcutHeading = "Open Sesame with"
    static let shortcutRowName = "Shortcut"
    static let appsHeading = "Open files with"
    static let appLabels: [(kind: String, label: String)] = [
        (kind: "pdf", label: "PDF app"), (kind: "media", label: "Media app"),
    ]
    static let indexingHeading = "Indexing"
    static let loginTitle = "Launch at login"
    static let deleteTitle = "Delete index\u{2026}"
    static let deleteConfirmTitle = "Delete index"
    static let deleteConfirmMessage = "Delete the index? Sesame forgets what it has read and starts again when you press Start indexing. Your files and folders are not touched."
    static let unreadableHeading = "Files Sesame could not read"
    static let settingsSetAsideText = "Your settings file could not be read, so it was set aside and defaults are in use."
    static let dismissTitle = "Dismiss"

    let sections = Section.allCases
    let section: Section
    let texts: [String]
    let controls: [Control]
    let folderRows: [FolderRow]
    let confirm: Confirm?
    let kinds: [Kind]
    let errorText: String?
    let setAsideNotice: String?
    /// Search: the shortcut in words, the control's message, the one notice, the two app pop-ups.
    let shortcutText: String?
    let shortcutMessage: String?
    let notice: String?
    let appPicks: [AppPick]
    /// Indexing: Start indexing, Launch at login (and what a failed change said), Delete index…, the could-not-read list.
    let startControl: Control?
    let loginControl: Control?
    let loginMessage: String?
    let deleteControl: Control?
    let unreadable: CouldNotReadList?

    /// A section's own parts are built only for the services it was given: a window gives all of them, a test of
    /// Folders or File types none. `problem` is a failure the window itself met (a choice that could not be saved).
    @MainActor
    init(
        model: SettingsModel, section: Section = .folders, confirmingRemoval: String? = nil, confirmingDelete: Bool = false,
        shortcut: ShortcutControl? = nil, notice: String? = nil, appChoices: AppChoices = AppChoices(),
        loginItem: LoginItem? = nil, unreadable: [UnreadableFile] = [], problem: String? = nil
    ) {
        self.section = section
        errorText = problem ?? model.errorText
        let shownNotice = section == .search ? notice : nil
        self.notice = shownNotice
        let settings = (try? SettingsFile().read()) ?? Settings()
        var texts: [String] = []
        var controls: [Control] = []

        var folderRows: [FolderRow] = []
        var confirm: Confirm?
        var kinds: [Kind] = []
        var shortcutText: String?
        var shortcutMessage: String?
        var appPicks: [AppPick] = []
        var startControl: Control?
        var loginControl: Control?
        var loginMessage: String?
        var deleteControl: Control?
        var unreadableList: CouldNotReadList?

        switch section {
        case .folders:
            for row in model.rows {
                let reading = settings.folders.first(where: { $0.path == row.path })?.reading == true
                let waiting = row.ticked && !reading
                let detail = Self.detail(
                    counting: row.state == .counting, ticked: row.ticked, counts: row.counts,
                    estimate: row.estimateText, waiting: waiting)
                folderRows.append(FolderRow(
                    path: row.path, name: row.name, detail: detail,
                    tick: Control(label: "\(row.name), \(detail)", isEnabled: true, isOn: row.ticked),
                    more: Control(label: Self.moreLabel(row.name), isEnabled: true),
                    reindex: Control(label: Self.reindexLabel, isEnabled: true),
                    remove: Control(label: Self.removeLabel, isEnabled: true)))
            }
            if let row = folderRows.first(where: { $0.path == confirmingRemoval }) {
                confirm = Confirm(
                    path: row.path,
                    message: "Remove \(row.name) from search? Its files leave the index. The files themselves are not touched.",
                    confirmTitle: Self.removeConfirmTitle, cancelTitle: Self.cancelTitle)
            }
            texts += [Self.foldersHeading, Self.foldersSectionTitle]
            texts += folderRows.isEmpty ? [Self.noFoldersText] : folderRows.map { "\($0.name): \($0.detail)" }
            texts.append(Self.foldersNote)
            for row in folderRows { controls += [row.tick, row.more, row.reindex, row.remove] }
            controls.append(Control(label: SetupModel.addFolderTitle, isEnabled: true))
            if let confirm {
                texts.append(confirm.message)
                controls += [Control(label: confirm.cancelTitle, isEnabled: true), Control(label: confirm.confirmTitle, isEnabled: true)]
            }
        case .fileTypes:
            for (key, title) in Self.kindList {
                kinds.append(Kind(key: key, title: title,
                                  control: Control(label: title, isEnabled: true, isOn: settings.kindsOn[key] ?? true)))
            }
            texts += [Self.fileTypesHeading, Self.fileTypesSectionTitle]
            controls += kinds.map(\.control)
        case .search:
            texts.append(Self.searchHeading)
            if let shortcut {
                shortcutText = shortcut.displayText
                shortcutMessage = shortcut.message
                texts += [Self.shortcutHeading, Self.shortcutRowName, shortcut.displayText] + [shortcut.message, shownNotice].compactMap { $0 }
                controls += [Control(label: ShortcutControl.recordTitle, isEnabled: true),
                             Control(label: ShortcutControl.backToDefaultTitle, isEnabled: true)]
            }
            texts.append(Self.appsHeading)
            for (kind, label) in Self.appLabels {
                let options = AppChoices.options(for: kind)
                let stored = kind == "pdf" ? settings.openWith.pdf : settings.openWith.media
                // A name the file does not hold (or that is not offered) shows the first app, which is the default.
                let chosen = options.first { $0.name == stored } ?? options.first
                let pick = AppPick(
                    kind: kind, options: options.map(\.name), selected: chosen?.name ?? "",
                    note: chosen.flatMap { appChoices.note(for: $0) }, control: Control(label: label, isEnabled: !options.isEmpty))
                appPicks.append(pick)
                texts.append(label)
                if let note = pick.note { texts.append(note) }
                controls.append(pick.control)
            }
        case .indexing:
            texts.append(Self.indexingHeading)
            // Available while Start was never pressed, or a tick waits for it (a folder added or ticked again later).
            let start = Control(
                label: SetupModel.startTitle,
                isEnabled: model.modelIsWhole && (!settings.startPressed || settings.hasPendingTicks))
            startControl = start
            controls.append(start)
            if let loginItem {
                let login = Control(label: Self.loginTitle, isEnabled: true, isOn: loginItem.isOn)
                loginControl = login
                loginMessage = loginItem.message
                controls.append(login)
                texts += [LoginItem.note] + [loginItem.message].compactMap { $0 }
            }
            let delete = Control(label: Self.deleteTitle, isEnabled: true)
            deleteControl = delete
            controls.append(delete)
            if confirmingDelete {
                confirm = Confirm(
                    path: "", message: Self.deleteConfirmMessage, confirmTitle: Self.deleteConfirmTitle,
                    cancelTitle: Self.cancelTitle)
                texts.append(Self.deleteConfirmMessage)
                controls += [Control(label: Self.cancelTitle, isEnabled: true), Control(label: Self.deleteConfirmTitle, isEnabled: true)]
            }
            let list = CouldNotReadList(files: unreadable)
            unreadableList = list
            texts += [Self.unreadableHeading] + (list.emptyText.map { [$0] } ?? list.rows)
        }
        if let errorText { texts.append(errorText) }
        setAsideNotice = model.setAsideNotice
        if let setAsideNotice {
            texts.append(setAsideNotice)
            controls.insert(Control(label: Self.dismissTitle, isEnabled: true), at: 0)
        }
        self.texts = texts
        self.controls = controls
        self.folderRows = folderRows
        self.confirm = confirm
        self.kinds = kinds
        self.shortcutText = shortcutText
        self.shortcutMessage = shortcutMessage
        self.appPicks = appPicks
        self.startControl = startControl
        self.loginControl = loginControl
        self.loginMessage = loginMessage
        self.deleteControl = deleteControl
        self.unreadable = unreadableList
    }

    /// "40 photos, about 2 min"; a folder that is ticked but waits for Start says so in place of the estimate.
    private static func detail(counting: Bool, ticked: Bool, counts: [String: Int], estimate: String, waiting: Bool) -> String {
        if counting { return "counting\u{2026}" }
        guard ticked else { return notReadText }
        let tail = waiting ? waitingText : estimate
        return [SetupScreen.countsText(counts), tail].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private extension SettingsScreen.Section {
    var symbol: String {
        switch self {
        case .folders: return "folder"
        case .fileTypes: return "doc.on.doc"
        case .search: return "magnifyingglass"
        case .indexing: return "arrow.triangle.2.circlepath"
        }
    }
}

/// The Settings window: a sidebar of four sections and the selected section beside it. It draws a `SettingsScreen`;
/// every action goes to the `SettingsModel` and the window then draws again. Plain AppKit controls, so the kit finds each
/// by its title or label.
@MainActor
final class SettingsContainerWindow: NSWindow, NSWindowDelegate {
    static let size = NSSize(width: 720, height: 520)
    private static let contentSize = NSSize(width: 720, height: 548)

    let model: SettingsModel
    /// The value the window draws now (`screen` is NSWindow's own).
    private(set) var settingsScreen: SettingsScreen
    /// The window has closed.
    var onClose: (() -> Void)?
    /// Start indexing was pressed here and has been sent to the helper.
    var onStarted: (() -> Void)?
    /// Delete index ran (or failed part way); the status cache should read again.
    var onIndexDeleted: (() -> Void)?

    private let shortcut: ShortcutControl
    private let loginItem: LoginItem
    private let appChoices: AppChoices
    private let deleteIndex: DeleteIndex
    private let usesGlass: Bool
    /// What `ShortcutControl.takeNotice()` handed over, shown in Search for as long as this window lives.
    private var notice: String?
    /// A failure of this window's own (a choice or the delete that could not be done).
    private var problem: String?

    private var section = SettingsScreen.Section.folders
    private var confirmingRemoval: String?
    private var confirmingDelete = false
    private var ticker: Timer?
    private let foldersView = SettingsFoldersView()
    private let fileTypesView = SettingsFileTypesView()
    private let searchView = SettingsSearchView()
    private let indexingView = SettingsIndexingView()
    private var sidebarButtons: [SettingsScreen.Section: SidebarButton] = [:]
    private let paneTitle = NSTextField(labelWithString: "")
    private let document = FlippedView()
    private var documentBottom: NSLayoutConstraint?
    private let noticeRow = NSView()
    private let noticeText = NSTextField(wrappingLabelWithString: "")
    private let dismissButton = TabbableButton(title: SettingsScreen.dismissTitle, target: nil, action: nil)
    private var scrollBelowStrip: NSLayoutConstraint?
    private var scrollBelowNotice: NSLayoutConstraint?

    /// A window over the real login item and app lookup. Its Delete index closes the index, writes `settings.json` and
    /// clears the Caches folders but sends `reset` to no helper: the app builds its window with the full initialiser.
    convenience init(model: SettingsModel) {
        self.init(
            model: model, shortcut: ShortcutControl(), loginItem: LoginItem(service: MainAppLoginService()),
            appChoices: AppChoices(), deleteIndex: Self.unwiredDeleteIndex())
    }

    static func unwiredDeleteIndex() -> DeleteIndex {
        DeleteIndex(closeIndex: {}, sendReset: {})
    }

    /// Reads the shortcut notice once, here: a window opened later shows none, and one with a notice opens on Search.
    init(
        model: SettingsModel, shortcut: ShortcutControl, loginItem: LoginItem, appChoices: AppChoices, deleteIndex: DeleteIndex,
        glass: Bool = Glass.isAvailable
    ) {
        self.model = model
        self.shortcut = shortcut
        self.loginItem = loginItem
        self.appChoices = appChoices
        self.deleteIndex = deleteIndex
        usesGlass = glass
        settingsScreen = SettingsScreen(model: model)
        notice = shortcut.takeNotice()
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = SettingsWindow.title
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        delegate = self
        if notice != nil { section = .search }
        wire()
        contentView = makeContent()
        setContentSize(Self.contentSize)
        refresh()
    }

    /// An accessory app that activates stays behind (see `Panel.show`), so the policy is regular while it is up.
    /// `message` (the launch failure) goes to the shortcut's status line and opens Search.
    func show(message: String? = nil) {
        clearStaleMessagesOnOpen()
        shortcut.clearMessage()
        notice = shortcut.takeNotice() ?? notice
        if let message {
            shortcut.report(message)
            select(.search)
        }
        refresh()
        if !isVisible { center() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        releaseFocusOnOpen()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func clearStaleMessagesOnOpen() {
        if !isVisible { loginItem.clearMessage() }
    }

    func windowWillClose(_ notification: Notification) {
        ticker?.invalidate()
        ticker = nil
        searchView.shortcutView.stopRecording()
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        searchView.shortcutView.stopRecording()
        refresh()
    }

    /// While the shortcut records, the next key press is the new shortcut: nothing else sees it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown,
           searchView.shortcutView.isRecording {
            searchView.shortcutView.stopRecording()
            refresh()
        }
        if event.type == .keyDown, searchView.shortcutView.consume(event) { return }
        super.sendEvent(event)
    }

    /// What a click on a sidebar item does.
    func select(_ section: SettingsScreen.Section) {
        self.section = section
        confirmingRemoval = nil
        confirmingDelete = false
        problem = nil
        model.clearError()
        searchView.shortcutView.stopRecording()
        refresh()
    }

    /// Reads the model now and draws, setting each view only when its value changed.
    func refresh() {
        let screen = SettingsScreen(
            model: model, section: section, confirmingRemoval: confirmingRemoval, confirmingDelete: confirmingDelete,
            shortcut: shortcut, notice: notice, appChoices: appChoices, loginItem: loginItem,
            unreadable: section == .indexing ? Self.unreadableFiles() : [], problem: problem)
        settingsScreen = screen
        for (item, button) in sidebarButtons {
            let selected = item == screen.section
            if button.isSelected != selected || (button.state == .on) != selected { button.isSelected = selected }
        }
        if paneTitle.stringValue != screen.section.title { paneTitle.stringValue = screen.section.title }
        renderSetAsideNotice(screen.setAsideNotice)
        for (item, view) in sectionViews where view.isHidden == (item == screen.section) { view.isHidden = item != screen.section }
        if let selected = sectionViews.first(where: { $0.0 == screen.section })?.1 { pinDocumentBottom(below: selected) }
        switch screen.section {
        case .folders: foldersView.render(screen)
        case .fileTypes: fileTypesView.render(screen)
        case .search: searchView.render(screen)
        case .indexing: indexingView.render(screen)
        }
        rebuildKeyLoop(screen)
    }

    private func renderSetAsideNotice(_ text: String?) {
        let shown = text != nil
        if let text, noticeText.stringValue != text {
            noticeText.stringValue = text
            noticeText.setAccessibilityLabel(text)
        }
        if noticeRow.isHidden == shown { noticeRow.isHidden = !shown }
        if scrollBelowStrip?.isActive == shown { scrollBelowStrip?.isActive = !shown }
        if scrollBelowNotice?.isActive == !shown { scrollBelowNotice?.isActive = shown }
    }

    @objc private func dismissPressed() {
        model.dismissSetAsideNotice()
        refresh()
    }

    /// A fresh connection for each read, closed at once: a list read after a reset never holds the old file.
    private static func unreadableFiles() -> [UnreadableFile] {
        let reader = IndexReader()
        defer { reader.close() }
        return reader.couldNotRead()
    }

    private var sectionViews: [(SettingsScreen.Section, NSView)] {
        [(.folders, foldersView), (.fileTypes, fileTypesView), (.search, searchView), (.indexing, indexingView)]
    }

    // MARK: the views

    private func makeContent() -> NSView {
        let sidebar = SidebarPanel(glass: usesGlass)
        var above = sidebar.topAnchor
        var gap = SettingsShell.rowStart
        for item in SettingsScreen.Section.allCases {
            let button = SidebarButton(title: item.title, symbol: item.symbol)
            button.target = self
            button.action = #selector(sidebarPressed(_:))
            button.identifier = NSUserInterfaceItemIdentifier(item.rawValue)
            sidebarButtons[item] = button
            sidebar.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: above, constant: gap),
                button.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: SettingsShell.inset),
                button.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -SettingsShell.inset),
            ])
            above = button.bottomAnchor
            gap = Space.s1
        }

        paneTitle.font = Typeface.paneTitle
        paneTitle.textColor = Design.label
        paneTitle.setAccessibilityElement(true)
        paneTitle.setAccessibilityRole(.staticText)
        paneTitle.translatesAutoresizingMaskIntoConstraints = false
        let hairline = PaneHairline()
        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(paneTitle)
        strip.addSubview(hairline)
        NSLayoutConstraint.activate([
            paneTitle.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: SettingsShell.contentMargin),
            paneTitle.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            paneTitle.trailingAnchor.constraint(lessThanOrEqualTo: strip.trailingAnchor, constant: -SettingsShell.contentMargin),
            hairline.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])

        document.translatesAutoresizingMaskIntoConstraints = false
        for (_, view) in sectionViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: SettingsShell.contentMargin),
                view.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -SettingsShell.contentMargin),
                view.topAnchor.constraint(equalTo: document.topAnchor, constant: SettingsShell.contentMargin),
            ])
        }

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let clip = scroll.contentView
        let shrink = document.heightAnchor.constraint(equalToConstant: 0)
        shrink.priority = .defaultLow
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            shrink,
        ])

        dismissButton.cell = QuietTitleCell(textCell: SettingsScreen.dismissTitle)
        dismissButton.target = self
        dismissButton.action = #selector(dismissPressed)
        dismissButton.isBordered = false
        dismissButton.alignment = .right
        dismissButton.attributedTitle = NSAttributedString(string: SettingsScreen.dismissTitle, attributes: [
            .font: Typeface.note,
            .foregroundColor: Design.secondaryLabel,
        ])
        dismissButton.setAccessibilityLabel(SettingsScreen.dismissTitle)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let paneWidth = Self.contentSize.width - SettingsShell.sidebarWidth - SettingsShell.separator
        noticeText.font = Typeface.note
        noticeText.textColor = Design.secondaryLabel
        noticeText.maximumNumberOfLines = 2
        noticeText.isSelectable = false
        noticeText.preferredMaxLayoutWidth = paneWidth - 2 * SettingsShell.contentMargin - Space.s4
            - ceil(dismissButton.intrinsicContentSize.width)
        noticeText.setAccessibilityElement(true)
        noticeText.setAccessibilityRole(.staticText)
        noticeText.translatesAutoresizingMaskIntoConstraints = false
        noticeRow.translatesAutoresizingMaskIntoConstraints = false
        noticeRow.isHidden = true
        noticeRow.addSubview(noticeText)
        noticeRow.addSubview(dismissButton)
        NSLayoutConstraint.activate([
            noticeText.leadingAnchor.constraint(equalTo: noticeRow.leadingAnchor, constant: SettingsShell.contentMargin),
            noticeText.topAnchor.constraint(equalTo: noticeRow.topAnchor, constant: Space.s3),
            noticeText.bottomAnchor.constraint(equalTo: noticeRow.bottomAnchor, constant: -Space.s3),
            noticeText.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -Space.s4),
            dismissButton.trailingAnchor.constraint(equalTo: noticeRow.trailingAnchor, constant: -SettingsShell.contentMargin),
            dismissButton.centerYAnchor.constraint(equalTo: noticeText.centerYAnchor),
        ])

        let divider = PaneHairline()
        let content = NSView()
        content.addSubview(sidebar)
        content.addSubview(divider)
        content.addSubview(scroll)
        content.addSubview(noticeRow)
        content.addSubview(strip)
        scrollBelowStrip = scroll.topAnchor.constraint(equalTo: strip.bottomAnchor)
        scrollBelowNotice = scroll.topAnchor.constraint(equalTo: noticeRow.bottomAnchor)
        NSLayoutConstraint.activate([
            noticeRow.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            noticeRow.topAnchor.constraint(equalTo: strip.bottomAnchor),
            noticeRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollBelowStrip!,
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SettingsShell.sidebarWidth),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: SettingsShell.separator),
            strip.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            strip.topAnchor.constraint(equalTo: content.topAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: SettingsShell.stripHeight),
            scroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    private func pinDocumentBottom(below view: NSView) {
        guard documentBottom?.secondItem !== view else { return }
        documentBottom?.isActive = false
        let pin = document.bottomAnchor.constraint(greaterThanOrEqualTo: view.bottomAnchor, constant: Space.s7)
        pin.isActive = true
        documentBottom = pin
    }

    private func wire() {
        foldersView.onTick = { [weak self] path, on in
            self?.model.setTicked(path, on)
            self?.refresh()
        }
        foldersView.onReindex = { [weak self] path in
            guard let self else { return }
            let applied = model.reindex(path)
            refresh()
            if applied { onStarted?() }
        }
        foldersView.onRemove = { [weak self] path in
            self?.confirmingRemoval = path
            self?.refresh()
        }
        foldersView.onCancel = { [weak self] in
            self?.confirmingRemoval = nil
            self?.refresh()
        }
        foldersView.onConfirm = { [weak self] path in
            self?.model.removeFolder(path, confirmed: true)
            self?.confirmingRemoval = nil
            self?.refresh()
        }
        foldersView.onAdd = { [weak self] in
            for url in FolderPicker.chooseFolders() { self?.model.addFolder(url) }
            self?.refresh()
        }
        fileTypesView.onKind = { [weak self] key, on in
            self?.model.setKind(key, on: on)
            self?.refresh()
        }
        wireSearch()
        wireIndexing()
    }

    private func wireSearch() {
        let shortcutView = searchView.shortcutView
        shortcutView.onStartRecording = { [weak self] in
            self?.shortcut.clearMessage()
            self?.refresh()
        }
        shortcutView.onRecorded = { [weak self] recorded in
            switch recorded {
            case .cancelled: break
            case let .combination(combination): self?.shortcut.record(combination)
            case .unnamedKey: self?.shortcut.refuseUnnamedKey()
            }
            self?.refresh()
        }
        shortcutView.onBackToDefault = { [weak self] in
            self?.shortcut.backToDefault()
            self?.refresh()
        }
        searchView.onPick = { [weak self] kind, name in
            guard let self, let option = AppChoices.options(for: kind).first(where: { $0.name == name }) else { return }
            do {
                try appChoices.choose(option, for: kind)
                problem = nil
            } catch {
                problem = "Could not save your settings."
            }
            refresh()
        }
    }

    private func wireIndexing() {
        indexingView.onStart = { [weak self] in
            guard let self else { return }
            let started = model.startIndexing()
            refresh()
            if started { onStarted?() }
        }
        indexingView.onLogin = { [weak self] on in
            self?.loginItem.set(on: on)
            self?.refresh()
        }
        indexingView.onDelete = { [weak self] in
            self?.confirmingDelete = true
            self?.refresh()
        }
        indexingView.onCancel = { [weak self] in
            self?.confirmingDelete = false
            self?.refresh()
        }
        indexingView.onConfirm = { [weak self] in
            guard let self else { return }
            confirmingDelete = false
            do {
                try deleteIndex.run(confirmed: true)
                problem = nil
            } catch {
                problem = "Could not delete the index."
            }
            refresh()
            onIndexDeleted?()
        }
    }

    /// Tab visits the sidebar, then what a person can press in the selected section, and comes back to the start.
    private func rebuildKeyLoop(_ screen: SettingsScreen) {
        let pane: [NSView]
        switch screen.section {
        case .folders: pane = foldersView.keyViews
        case .fileTypes: pane = fileTypesView.keyViews
        case .search: pane = searchView.keyViews
        case .indexing: pane = indexingView.keyViews
        }
        let notice: [NSView] = screen.setAsideNotice == nil ? [] : [dismissButton]
        let loop = (SettingsScreen.Section.allCases.compactMap { sidebarButtons[$0] } + notice + pane)
            .filter { ($0 as? NSControl)?.isEnabled == true }
        for (index, view) in loop.enumerated() { view.nextKeyView = loop[(index + 1) % loop.count] }
        initialFirstResponder = loop.first
        keepFocus()
    }

    /// A row or a confirm that went away took the focus with it; Tab starts again from the first stop.
    private func keepFocus() {
        guard isVisible, let view = firstResponder as? NSView else { return }
        if view.window == nil || view.isHiddenOrHasHiddenAncestor || ((view as? NSControl)?.isEnabled == false) {
            makeFirstResponder(nil)
        }
    }

    func releaseFocusOnOpen() {
        makeFirstResponder(nil)
    }

    @objc private func sidebarPressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let item = SettingsScreen.Section(rawValue: raw) else { return }
        select(item)
    }
}
