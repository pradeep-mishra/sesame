import AppKit
import SesameEngine

/// The setup window: four steps (Welcome, Folders, Permissions, Shortcut) with Back and Next, the model's progress
/// at the foot of every step, and Start indexing on the Folders step. Its title holds "Set up" so the test kit finds it.
/// It builds its own `SetupModel` and `SetupFlow`; the views only draw a `SetupScreen`.
///
/// Plain AppKit views, not SwiftUI: measured with the kit's `dump setup`, SwiftUI's buttons reach the
/// accessibility tree with no label at all, and the kit clicks by label. An NSButton carries its title.
@MainActor
final class SetupWindow: NSWindow, NSWindowDelegate {
    static let size = NSSize(width: 560, height: 600)
    private static let contentWidth = size.width - 2 * Space.s6

    let model: SetupModel
    private(set) var flow = SetupFlow()
    /// The value the window draws now (`screen` is NSWindow's own).
    private(set) var setupScreen: SetupScreen

    /// True while a Setup window is on screen.
    static var isShowing: Bool {
        NSApp.windows.contains { $0 is SetupWindow && $0.isVisible }
    }

    /// Retry was pressed: the app starts the download again.
    private let onRetry: (@MainActor () -> Void)?
    /// Start indexing was pressed and settings.json is written. The app passes the supervisor's `reevaluate()`, which
    /// is then the one thing that starts the helper (or holds it back while a pause reason holds). Without it the
    /// window sends `folders` to the helper itself.
    private let onStarted: (@MainActor () -> Void)?
    /// A refresh saw the model become whole.
    var onModelWhole: () -> Void = {}
    /// The window has closed.
    var onClose: (() -> Void)?

    private let usesGlass: Bool
    private let folders: SetupFolders
    private let helper: HelperClient
    private let status: StatusCache
    private var ticker: Timer?
    private var wasWhole: Bool

    private let welcomeStack = NSStackView()
    private let stepDots = StepDots(step: .welcome)
    private let foldersStack = NSView()
    private let permissionsStack = NSStackView()
    private let shortcutStack = NSView()
    private let keycaps = KeycapRow()
    private var noteAnchors: (model: NSLayoutConstraint, footer: NSLayoutConstraint)?

    private let summaryLabel = SetupWindow.wrapping(color: Design.label, font: Typeface.body)
    private let totalLabel = SetupWindow.wrapping(color: Design.secondaryLabel, font: Typeface.secondary)
    private let rowsStack = NSStackView()
    private let addFolderButton = SetupButton(title: SetupModel.addFolderTitle, target: nil, action: nil)
    private let startErrorLabel = SetupWindow.wrapping(color: Design.error, font: Typeface.body)
    private lazy var startErrorRow = Self.errorRow(startErrorLabel)
    private let notNowButton = SetupButton(title: SetupScreen.notNowTitle, target: nil, action: nil)
    private let hintLabel = SetupWindow.wrapping(color: Design.secondaryLabel, font: Typeface.secondary)
    private let runningLabel = SetupWindow.wrapping(color: Design.secondaryLabel, font: Typeface.secondary)

    private let progressBar = NSProgressIndicator()
    private let progressLabel = FigureView()
    private let statusLine = NSStackView()
    private lazy var modelCard = makeModelCard()
    private let modelBlock = NSStackView()
    private let damagedLabel = SetupWindow.wrapping(color: Design.label, font: Typeface.body)
    private let errorLabel = SetupWindow.wrapping(color: Design.error, font: Typeface.body)
    private lazy var failureRow = Self.errorRow(errorLabel)
    private let nextStepLabel = SetupWindow.label(SetupScreen.nextStepText, font: Typeface.secondary, color: Design.secondaryLabel)
    private let retryButton = SetupButton(title: SetupModel.retryTitle, target: nil, action: nil)

    private let backButton = SetupButton(title: SetupScreen.backTitle, target: nil, action: nil)
    private let nextButton = SetupButton(title: SetupScreen.nextTitle, target: nil, action: nil)
    private let finishButton = SetupButton(title: SetupScreen.finishTitle, target: nil, action: nil)

    private struct RowViews {
        let line: NSView
        let checkbox: SetupButton
        let count: NSTextField
    }

    private var rowViews: [String: RowViews] = [:]
    private var shownKeys: [String] = []

    init(
        files: [ModelFile], folders: SetupFolders, helper: HelperClient, status: StatusCache,
        onStarted: (@MainActor () -> Void)? = nil, onRetry: (@MainActor () -> Void)? = nil,
        glass: Bool = Glass.isAvailable
    ) {
        usesGlass = glass
        let model = SetupModel(files: files)
        let first = SetupFlow()
        self.model = model
        self.folders = folders
        self.helper = helper
        self.status = status
        self.onStarted = onStarted
        self.onRetry = onRetry
        wasWhole = model.modelIsWhole
        setupScreen = SetupScreen(flow: first, model: model, folders: folders)
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Set up Sesame"
        isReleasedWhenClosed = false
        delegate = self
        if glass {
            isOpaque = false
            backgroundColor = .clear
        }
        model.onStart = { [weak self] in self?.started() }
        model.onRetry = { [weak self] in self?.onRetry?() }
        contentView = makeContent()
        setContentSize(Self.size)
        render()
    }

    /// An accessory app that activates stays behind (see `Panel.show`), so the policy is regular while the
    /// window is up.
    func show() {
        refresh()
        center()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        if let first = initialFirstResponder { makeFirstResponder(first) }
        // At launch the system has not finished starting the app, and the first activate is dropped (measured:
        // the window was up but Finder stayed in front); ask again once launching is over.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.isVisible, !NSApp.isActive else { return }
            NSApp.activate()
            self.makeKeyAndOrderFront(nil)
        }
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        ticker?.invalidate()
        ticker = nil
        onClose?()
    }

    /// Reads the model files and the estimates now and draws.
    func refresh() {
        model.refresh()
        folders.refreshEstimates()
        render()
        if model.modelIsWhole != wasWhole {
            wasWhole = model.modelIsWhole
            if wasWhole { onModelWhole() }
        }
    }

    // MARK: the views

    private static func wrapping(color: NSColor, font: NSFont) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = font
        field.textColor = color
        field.preferredMaxLayoutWidth = contentWidth
        return field
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        return field
    }

    private static func title(_ text: String) -> NSTextField {
        let field = label(text, font: Typeface.heroTitle, color: Design.label)
        field.alignment = .center
        return field
    }

    private static func centred(_ field: NSTextField) -> NSTextField {
        field.alignment = .center
        return field
    }

    private static func fillWidth(_ views: [NSView], of stack: NSStackView) {
        NSLayoutConstraint.activate(views.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    private static func body(_ text: String, color: NSColor = Design.label, font: NSFont = Typeface.body) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.preferredMaxLayoutWidth = contentWidth
        return field
    }

    private static func column(_ views: [NSView], spacing: CGFloat = Space.s4) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private static func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = Space.s3
        return stack
    }

    private static func errorRow(_ label: NSTextField) -> NSStackView {
        label.preferredMaxLayoutWidth = contentWidth - 2 * Space.s5 - 32
        let symbol = WarningSymbolView(pointSize: 16)
        symbol.isEnabled = false
        let row = row([symbol, label])
        row.alignment = .top
        return row
    }

    private static func card(_ content: NSView, padding: CGFloat = Space.s4) -> GroupCard {
        let card = GroupCard(rows: [content])
        card.translatesAutoresizingMaskIntoConstraints = false
        for constraint in [
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -padding),
        ] {
            constraint.priority = NSLayoutConstraint.Priority(999)
            constraint.isActive = true
        }
        return card
    }

    private static func permissionRow(name: String, detail: String) -> NSStackView {
        column([
            label(name, font: Typeface.rowName, color: Design.label),
            label(detail, font: Typeface.secondary, color: Design.secondaryLabel),
        ], spacing: Space.s1)
    }

    private static func permissionsCard() -> GroupCard {
        let rows = SetupScreen.permissionRows.map { permissionRow(name: $0.name, detail: $0.detail) }
        let list = NSView()
        let rowsStack = column(rows, spacing: Space.s5)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(rowsStack)
        var constraints = [
            rowsStack.topAnchor.constraint(equalTo: list.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: list.trailingAnchor),
        ]
        for row in rows.dropLast() {
            let line = PermissionHairline()
            line.translatesAutoresizingMaskIntoConstraints = false
            list.addSubview(line)
            constraints += [
                line.leadingAnchor.constraint(equalTo: list.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: list.trailingAnchor),
                line.heightAnchor.constraint(equalToConstant: 1),
                line.centerYAnchor.constraint(equalTo: row.bottomAnchor, constant: Space.s3),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return card(list, padding: Space.s5)
    }

    private func makeContent() -> NSView {
        let buttons = [retryButton, addFolderButton, notNowButton, backButton, nextButton, finishButton]
        let actions: [(SetupButton, Selector)] = [
            (retryButton, #selector(retryPressed)), (addFolderButton, #selector(addFolderPressed)),
            (notNowButton, #selector(notNowPressed)), (backButton, #selector(backPressed)),
            (nextButton, #selector(nextPressed)), (finishButton, #selector(finishPressed)),
        ]
        for (button, action) in actions {
            button.target = self
            button.action = action
        }
        for button in buttons {
            if button !== addFolderButton && button !== notNowButton {
                Glass.style(button, accent: button === nextButton || button === finishButton, glass: usesGlass)
            }
            button.setAccessibilityLabel(button.title)
        }
        for quiet in [addFolderButton, notNowButton] {
            quiet.isBordered = false
            quiet.attributedTitle = NSAttributedString(string: quiet.title, attributes: [
                .font: Typeface.body, .foregroundColor: Design.secondaryLabel,
            ])
        }

        nextButton.keyEquivalent = "\r"
        finishButton.keyEquivalent = "\r"

        fillWelcomeStack()
        fillStatusLine()
        fillFoldersStack()

        let permissionCard = Self.permissionsCard()
        let permissionsTitle = Self.title(SetupScreen.permissionsHeading)
        let permissionsIntro = Self.centred(Self.body(SetupScreen.permissionsIntro))
        let permissionsNote = Self.centred(Self.body(SetupFlow.neverAskedLine, color: Design.secondaryLabel, font: Typeface.secondary))
        for view in [permissionsTitle, permissionsIntro, permissionCard, permissionsNote] {
            permissionsStack.addArrangedSubview(view)
        }
        permissionsStack.setCustomSpacing(Space.s3, after: permissionsTitle)
        permissionsStack.setCustomSpacing(Space.s3, after: permissionsIntro)
        Self.fillWidth([permissionsTitle, permissionsIntro, permissionsNote], of: permissionsStack)

        permissionsStack.orientation = .vertical
        permissionsStack.alignment = .leading
        permissionsStack.spacing = Space.s4
        NSLayoutConstraint.activate([permissionCard.widthAnchor.constraint(equalTo: permissionsStack.widthAnchor)])

        modelBlock.orientation = .vertical
        modelBlock.alignment = .centerX
        modelBlock.spacing = 0
        modelBlock.addArrangedSubview(statusLine)
        modelBlock.addArrangedSubview(modelCard)

        let content = NSView()
        if let backdrop = Glass.backdrop(enabled: usesGlass) {
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(backdrop)
            NSLayoutConstraint.activate([
                backdrop.topAnchor.constraint(equalTo: content.topAnchor),
                backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        let placed: [NSView] = [
            welcomeStack, foldersStack, permissionsStack, shortcutStack, modelBlock,
            backButton, stepDots, nextButton, finishButton,
        ]
        for view in placed {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let welcomeSpace = NSLayoutGuide()
        content.addLayoutGuide(welcomeSpace)
        let welcomeCentre = welcomeStack.centerYAnchor.constraint(equalTo: welcomeSpace.centerYAnchor)
        welcomeCentre.priority = NSLayoutConstraint.Priority(750)
        let welcomeBottom = welcomeStack.bottomAnchor.constraint(lessThanOrEqualTo: modelBlock.topAnchor, constant: -Space.s5)
        welcomeBottom.priority = NSLayoutConstraint.Priority(999)
        var constraints = [
            welcomeSpace.topAnchor.constraint(equalTo: content.topAnchor),
            welcomeSpace.bottomAnchor.constraint(equalTo: modelBlock.topAnchor, constant: -Space.s5),
            welcomeCentre,
            welcomeBottom,
            welcomeStack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: Space.s6),
            welcomeStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Space.s6),
            welcomeStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Space.s6),
            modelBlock.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Space.s6),
            modelBlock.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Space.s6),
            modelBlock.bottomAnchor.constraint(equalTo: backButton.topAnchor, constant: -Space.s5),
            modelCard.widthAnchor.constraint(equalTo: modelBlock.widthAnchor),
            backButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Space.s6),
            backButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Space.s6),
            nextButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Space.s6),
            nextButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Space.s6),
            finishButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Space.s6),
            finishButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Space.s6),
            stepDots.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stepDots.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
        ]
        let foldersBottom = foldersStack.bottomAnchor.constraint(lessThanOrEqualTo: modelBlock.topAnchor, constant: -Space.s5)
        foldersBottom.priority = NSLayoutConstraint.Priority(999)
        constraints.append(foldersBottom)
        for step in [foldersStack, permissionsStack, shortcutStack] {
            constraints += [
                step.topAnchor.constraint(equalTo: content.topAnchor, constant: Space.s7),
                step.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Space.s6),
                step.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Space.s6),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        fillShortcutView()
        return content
    }

    private func fillShortcutView() {
        let title = Self.title(SetupScreen.shortcutHeading)
        let lead = Self.centred(Self.label(SetupScreen.shortcutLead, font: Typeface.body, color: Design.secondaryLabel))
        let note = Self.centred(Self.body(SetupScreen.shortcutNote, color: Design.secondaryLabel, font: Typeface.secondary))
        runningLabel.stringValue = SetupScreen.shortcutRunningLine
        runningLabel.alignment = .center
        let noteBlock = NSStackView(views: [note, runningLabel])
        noteBlock.orientation = .vertical
        noteBlock.alignment = .centerX
        noteBlock.spacing = Space.s3
        Self.fillWidth([note, runningLabel], of: noteBlock)
        let space = NSLayoutGuide()
        shortcutStack.addLayoutGuide(space)
        for view in [title, lead, keycaps, noteBlock] {
            view.translatesAutoresizingMaskIntoConstraints = false
            shortcutStack.addSubview(view)
        }
        let aboveModel = noteBlock.bottomAnchor.constraint(equalTo: modelBlock.topAnchor, constant: -Space.s5)
        let aboveFooter = noteBlock.bottomAnchor.constraint(equalTo: backButton.topAnchor, constant: -Space.s5)
        noteAnchors = (aboveModel, aboveFooter)
        var constraints = [
            title.topAnchor.constraint(equalTo: shortcutStack.topAnchor),
            lead.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Space.s3),
            space.topAnchor.constraint(equalTo: lead.bottomAnchor),
            space.bottomAnchor.constraint(equalTo: note.topAnchor),
            keycaps.centerXAnchor.constraint(equalTo: shortcutStack.centerXAnchor),
            keycaps.centerYAnchor.constraint(equalTo: space.centerYAnchor),
            keycaps.topAnchor.constraint(greaterThanOrEqualTo: lead.bottomAnchor, constant: Space.s5),
            keycaps.bottomAnchor.constraint(lessThanOrEqualTo: note.topAnchor, constant: -Space.s5),
            shortcutStack.bottomAnchor.constraint(equalTo: noteBlock.bottomAnchor),
            aboveModel,
        ]
        for view in [title, lead, noteBlock] {
            constraints += [
                view.leadingAnchor.constraint(equalTo: shortcutStack.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: shortcutStack.trailingAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func makeModelCard() -> GroupCard {
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.setAccessibilityElement(false)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        damagedLabel.preferredMaxLayoutWidth = Self.contentWidth - 2 * Space.s5
        let modelStack = Self.column([
            Self.label(SetupScreen.modelHeading, font: Typeface.groupLabel, color: Design.label),
            progressBar, progressLabel, damagedLabel, failureRow, nextStepLabel, retryButton,
        ], spacing: Space.s3)
        let card = Self.card(modelStack)
        NSLayoutConstraint.activate([
            progressBar.widthAnchor.constraint(equalTo: modelStack.widthAnchor),
            progressLabel.widthAnchor.constraint(equalTo: modelStack.widthAnchor),
        ])
        return card
    }

    private func fillStatusLine() {
        statusLine.orientation = .horizontal
        statusLine.alignment = .centerY
        statusLine.spacing = Space.s2
        statusLine.addArrangedSubview(Self.symbolView("checkmark.circle.fill", pointSize: Hero.statusGlyph, tint: Design.secondaryLabel))
        statusLine.addArrangedSubview(Self.label(SetupScreen.modelReadyText, font: Typeface.secondary, color: Design.secondaryLabel))
    }

    private func fillWelcomeStack() {
        welcomeStack.orientation = .vertical
        welcomeStack.alignment = .centerX
        welcomeStack.spacing = 0
        let glyph = Self.symbolView("magnifyingglass", pointSize: Hero.glyph, tint: Design.label)
        let heading = Self.label(SetupScreen.welcomeHeading, font: Typeface.heroTitle, color: Design.label)
        heading.alignment = .center
        let subline = Self.label(SetupScreen.welcomeSubline, font: Typeface.body, color: Design.secondaryLabel)
        subline.alignment = .center
        let promises = Self.column(SetupScreen.welcomePromises.map { promise in
            let text = Self.column([
                Self.label(promise.title, font: Typeface.rowName, color: Design.label),
                Self.label(promise.detail, font: Typeface.secondary, color: Design.secondaryLabel),
            ], spacing: Space.s1)
            let symbol = Self.symbolView(promise.symbol, pointSize: Hero.promiseGlyph, tint: Design.label)
            symbol.widthAnchor.constraint(equalToConstant: Space.s7).isActive = true
            let row = Self.row([symbol, text])
            row.spacing = Space.s4
            row.alignment = .top
            return row
        }, spacing: Space.s4)
        promises.widthAnchor.constraint(lessThanOrEqualToConstant: Hero.column).isActive = true
        for view in [glyph, heading, subline, promises] { welcomeStack.addArrangedSubview(view) }
        welcomeStack.setCustomSpacing(Space.s5, after: glyph)
        welcomeStack.setCustomSpacing(Space.s3, after: heading)
        welcomeStack.setCustomSpacing(Space.s7, after: subline)
    }

    private static func symbolView(_ name: String, pointSize: CGFloat, tint: NSColor) -> NSImageView {
        let view = NSImageView()
        view.image = Design.symbol(name, pointSize: pointSize)
        view.contentTintColor = tint
        view.isEnabled = false
        view.setAccessibilityElement(false)
        return view
    }

    private func fillFoldersStack() {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = Space.s5
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document
        scroll.setAccessibilityLabel("Folders")
        let listCard = Self.card(scroll, padding: Space.s5)
        let reference = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        reference.font = Typeface.body
        let rowHeight = reference.fittingSize.height
        let fitsRows = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        fitsRows.priority = NSLayoutConstraint.Priority(499)
        NSLayoutConstraint.activate([
            fitsRows,
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 6 * rowHeight + 5 * Space.s5),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        let heading = Self.title(SetupScreen.foldersHeading)
        let header = Self.column([heading, summaryLabel, totalLabel], spacing: Space.s3)
        for field in [summaryLabel, totalLabel] { field.alignment = .center }
        Self.fillWidth([heading, summaryLabel, totalLabel], of: header)
        let readNote = Self.body(SetupFolders.readNote, color: Design.secondaryLabel, font: Typeface.secondary)
        readNote.alignment = .center
        hintLabel.alignment = .center
        let foot = NSStackView(views: [hintLabel, readNote, notNowButton, startErrorRow])
        foot.orientation = .vertical
        foot.alignment = .centerX
        foot.spacing = Space.s4
        Self.fillWidth([hintLabel, readNote], of: foot)

        for part in [header, listCard, addFolderButton, foot] {
            part.translatesAutoresizingMaskIntoConstraints = false
            foldersStack.addSubview(part)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: foldersStack.topAnchor),
            header.leadingAnchor.constraint(equalTo: foldersStack.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: foldersStack.trailingAnchor),
            listCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Space.s3),
            listCard.leadingAnchor.constraint(equalTo: foldersStack.leadingAnchor),
            listCard.trailingAnchor.constraint(equalTo: foldersStack.trailingAnchor),
            addFolderButton.topAnchor.constraint(equalTo: listCard.bottomAnchor, constant: Space.s4),
            addFolderButton.leadingAnchor.constraint(equalTo: listCard.leadingAnchor),
            foot.topAnchor.constraint(equalTo: addFolderButton.bottomAnchor, constant: Space.s4),
            foot.leadingAnchor.constraint(equalTo: foldersStack.leadingAnchor),
            foot.trailingAnchor.constraint(equalTo: foldersStack.trailingAnchor),
            foot.bottomAnchor.constraint(lessThanOrEqualTo: foldersStack.bottomAnchor),
        ])
    }

    // MARK: what the screen says

    /// Draws a new `SetupScreen`, setting each view only when its value changed (an unchanged set would still
    /// disturb the accessibility tree twice a second).
    private func render() {
        let screen = SetupScreen(flow: flow, model: model, folders: folders)
        setupScreen = screen

        if stepDots.step != screen.step { stepDots.step = screen.step }
        setHidden(welcomeStack, screen.step != .welcome)
        setHidden(foldersStack, screen.step != .folders)
        setHidden(permissionsStack, screen.step != .permissions)
        setHidden(shortcutStack, screen.step != .shortcut)
        if !screen.shortcutText.isEmpty { keycaps.text = screen.shortcutText }
        if let anchors = noteAnchors, anchors.footer.isActive != screen.modelIsWhole {
            anchors.model.isActive = false
            anchors.footer.isActive = false
            (screen.modelIsWhole ? anchors.footer : anchors.model).isActive = true
        }

        setText(summaryLabel, screen.summary)
        setText(totalLabel, screen.totalText ?? "", hidesWhenEmpty: true)
        renderRows(screen)
        setText(startErrorLabel, screen.startErrorText ?? "")
        setHidden(startErrorRow, screen.startErrorText == nil)
        setText(hintLabel, screen.hint ?? "", hidesWhenEmpty: true)
        setHidden(runningLabel, !screen.showsRunningLine)

        progressLabel.text = screen.modelProgress
        if progressBar.doubleValue != screen.modelFraction { progressBar.doubleValue = screen.modelFraction }
        setHidden(progressBar, screen.modelIsWhole)
        setHidden(progressLabel, screen.modelIsWhole)
        setHidden(statusLine, !screen.modelIsWhole || screen.step != .welcome)
        setHidden(modelCard, screen.modelIsWhole)
        setText(damagedLabel, screen.damagedText ?? "", hidesWhenEmpty: true)
        setText(errorLabel, screen.errorText ?? "")
        setHidden(failureRow, screen.errorText == nil)
        setHidden(nextStepLabel, screen.errorText == nil)

        func enabled(_ title: String) -> Bool { screen.buttons.contains { $0.title == title && $0.isEnabled } }
        func shown(_ title: String) -> Bool { screen.buttons.contains { $0.title == title } }
        setHidden(retryButton, !shown(SetupModel.retryTitle))
        setEnabled(retryButton, enabled(SetupModel.retryTitle))
        setEnabled(addFolderButton, enabled(SetupModel.addFolderTitle))
        setHidden(notNowButton, !shown(SetupScreen.notNowTitle))
        setEnabled(notNowButton, enabled(SetupScreen.notNowTitle))
        setHidden(backButton, screen.step == .welcome)
        setEnabled(backButton, enabled(SetupScreen.backTitle))
        let footerTitle = shown(SetupModel.startTitle) ? SetupModel.startTitle : SetupScreen.nextTitle
        if nextButton.title != footerTitle {
            nextButton.title = footerTitle
            nextButton.setAccessibilityLabel(footerTitle)
            nextButton.setAccessibilityTitle(footerTitle)
        }
        setHidden(nextButton, !shown(footerTitle))
        setEnabled(nextButton, enabled(footerTitle))
        setHidden(finishButton, !shown(SetupScreen.finishTitle))
        setEnabled(finishButton, enabled(SetupScreen.finishTitle))

        rebuildKeyLoop(screen)
    }

    /// The folder lines are kept and updated in place; the list is rebuilt only when a folder is added, so a click
    /// on a tick never removes the button being clicked.
    private func renderRows(_ screen: SetupScreen) {
        let keys = screen.rows.map { "r:" + $0.path }
        let lines = screen.rows.map { ($0, "r:" + $0.path) }
        for (row, key) in lines { update(row, key: key) }
        guard keys != shownKeys else { return }
        shownKeys = keys
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (_, key) in lines {
            guard let views = rowViews[key] else { continue }
            rowsStack.addArrangedSubview(views.line)
            views.line.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    private func update(_ row: SetupScreen.Row, key: String) {
        let views = rowViews[key] ?? makeRow(path: row.path)
        rowViews[key] = views
        if views.checkbox.title != row.name { views.checkbox.title = row.name }
        let state: NSControl.StateValue = row.ticked ? .on : .off
        if views.checkbox.state != state { views.checkbox.state = state }
        setEnabled(views.checkbox, row.isEnabled)
        if views.checkbox.accessibilityLabel() != row.label { views.checkbox.setAccessibilityLabel(row.label) }
        if views.checkbox.toolTip != row.tooltip { views.checkbox.toolTip = row.tooltip }
        setText(views.count, row.count, hidesWhenEmpty: true)
    }

    private func makeRow(path: String) -> RowViews {
        let checkbox = SetupButton()
        checkbox.setButtonType(.switch)
        checkbox.font = Typeface.body
        checkbox.lineBreakMode = .byTruncatingMiddle
        checkbox.identifier = NSUserInterfaceItemIdentifier(path)
        checkbox.setAccessibilityHelp(path)
        checkbox.target = self
        checkbox.action = #selector(rowToggled(_:))
        checkbox.setContentCompressionResistancePriority(.required, for: .vertical)
        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let count = Self.label("", font: Typeface.secondary, color: Design.secondaryLabel)
        count.alignment = .right
        count.setAccessibilityElement(false)
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = NSView()
        for view in [checkbox, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            line.addSubview(view)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            checkbox.topAnchor.constraint(equalTo: line.topAnchor),
            checkbox.bottomAnchor.constraint(equalTo: line.bottomAnchor),
            count.trailingAnchor.constraint(equalTo: line.trailingAnchor),
            count.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -Space.s3),
        ])
        return RowViews(line: line, checkbox: checkbox, count: count)
    }

    /// Tab visits what a person can press on this step, in reading order, and comes back to the start.
    private func rebuildKeyLoop(_ screen: SetupScreen) {
        var loop: [NSView] = []
        if screen.step == .folders {
            loop += screen.rows.compactMap { rowViews["r:" + $0.path]?.checkbox }
            loop += [addFolderButton, notNowButton]
        }
        loop += [retryButton, backButton, nextButton, finishButton]
        for (index, view) in loop.enumerated() { view.nextKeyView = loop[(index + 1) % loop.count] }
        initialFirstResponder = loop.first { view in
            guard let button = view as? NSButton else { return false }
            return button.isEnabled && !button.isHiddenOrHasHiddenAncestor
        }
    }

    private func setText(_ field: NSTextField, _ text: String, hidesWhenEmpty: Bool = false) {
        if field.stringValue != text { field.stringValue = text }
        if hidesWhenEmpty { setHidden(field, text.isEmpty) }
    }

    private func setHidden(_ view: NSView, _ hidden: Bool) {
        if view.isHidden != hidden { view.isHidden = hidden }
    }

    private func setEnabled(_ button: NSButton, _ enabled: Bool) {
        if button.isEnabled != enabled { button.isEnabled = enabled }
    }

    // MARK: the buttons

    @objc private func backPressed() {
        flow.back()
        refresh()
    }

    @objc private func nextPressed() {
        if nextButton.title == SetupModel.startTitle {
            startPressed()
            return
        }
        flow.next()
        refresh()
    }

    @objc private func notNowPressed() {
        flow.next()
        refresh()
    }

    /// Finish keeps the ticked folders as waiting ticks and marks setup finished; it starts nothing.
    @objc private func finishPressed() {
        guard flow.canFinish else { return }
        handOverFolders()
        model.finishSetup()
        close()
    }

    @objc private func retryPressed() {
        model.retry()
        refresh()
    }

    @objc private func addFolderPressed() {
        folders.addFolder()
        refresh()
    }

    @objc private func rowToggled(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        folders.setTicked(path, sender.state == .on)
        refresh()
    }

    private func handOverFolders() {
        for row in folders.rows where row.note == nil {
            model.addFolder(URL(fileURLWithPath: row.path))
            model.setFolder(row.path, ticked: row.ticked)
        }
    }

    /// Start indexing writes the ticks to settings.json, then tells the helper and the status cache.
    private func startPressed() {
        handOverFolders()
        model.startIndexing()
        if model.started && model.startErrorText == nil { flow.next() }
        refresh()
    }

    private func started() {
        status.settingsChanged()
        if let onStarted {
            onStarted()
        } else {
            helper.sendFolders()
        }
    }
}

private final class PermissionHairline: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        refreshColour()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        refreshColour()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColour()
    }

    private func refreshColour() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Design.separator.cgColor
        }
    }
}
