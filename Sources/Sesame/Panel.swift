import AppKit
import Carbon.HIToolbox
import SesameEngine

/// `HelperClient` has one delegate and `HelperEmbedder` takes it; this takes its place, hands every event on to the
/// embedder, tells the panel about each preview reply, and tells the pipeline when the index helper committed.
final class HelperEventRelay: HelperClientDelegate, @unchecked Sendable {
    private let embedder: HelperEmbedder
    private let onPreview: @Sendable (PreviewReply) -> Void
    private let onIndexChanged: @Sendable () -> Void

    init(
        embedder: HelperEmbedder, onPreview: @escaping @Sendable (PreviewReply) -> Void,
        onIndexChanged: @escaping @Sendable () -> Void
    ) {
        self.embedder = embedder
        self.onPreview = onPreview
        self.onIndexChanged = onIndexChanged
    }

    /// `changed` means the index helper committed: the closure runs once for it and for no other event.
    static func route(_ event: HelperEvent, onIndexChanged: () -> Void) {
        if case .changed = event { onIndexChanged() }
    }

    func helperClient(_ client: HelperClient, didReceive event: HelperEvent) {
        embedder.helperClient(client, didReceive: event)
        if case let .preview(reply) = event { onPreview(reply) }
        Self.route(event, onIndexChanged: onIndexChanged)
    }
}

/// The accessibility labels of the panel and its list (spec S1: VoiceOver labels), written once.
enum AccessibilityLabels {
    static let searchBox = "Search your files"
    static let resultList = "Results"
    static let preview = "Preview"

    /// A result row: the file's name, then its kind ("beach-dog.jpg (photo)").
    static func resultRow(name: String, kind: String) -> String {
        "\(name) (\(kind))"
    }

    static func resultRow(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return resultRow(name: url.lastPathComponent, kind: Rules.kind(forExtension: url.pathExtension.lowercased()) ?? "file")
    }
}

/// The search panel: one window made at launch, kept hidden, shown and hidden by the shortcut. The E1 split look:
/// the search box on top, the calm result list on the left (40%), the preview pane on the right.
@MainActor
final class Panel: NSPanel, Sendable {
    static let size = NSSize(width: 960, height: 560)
    private static let searchBarHeight: CGFloat = 58
    private static let footerHeight: CGFloat = 32
    /// How long Enter waits for the helper's preview reply, which says what kind of file it is opening.
    private static let replyWaitSeconds = 1.0

    /// The panel's one search box, made once.
    private(set) var queryBox: QueryBox!
    private let results = ResultList()
    private let pane = Pane()
    private let banner = IndexingBannerPanel()
    private let notReady = NotReadyPanel()
    private let emptyHint = EmptyHintPanel()
    private let searchFailedView = SearchFailedPanel()
    private let statusNote = StatusNote()
    private let permissionNote = StatusNote(identifier: "PermissionNote")
    private let divider = NSBox()
    private var bannerHeight: NSLayoutConstraint!
    /// The app's one index reader: the search pipeline and the status cache both read through it.
    let reader: IndexReader
    /// What the panel draws its states from; it never reads a source itself (design section 8).
    private var status: StatusCache
    private var pipeline: SearchPipeline?
    private var helper: HelperClient?
    private var relay: HelperEventRelay?
    private var idleTimer: Timer?
    private var ticketsWithoutPipeline = 0
    /// The ticket of the text in the box (or of the emptied box); a list of any other ticket is not shown.
    private var currentTicket: Int?
    /// The ticket whose embed failed. It counts only while it is still `currentTicket`: the next keystroke or an
    /// emptied box makes a new ticket, which clears the failure.
    private var failedTicket: Int?
    private let gate = TicketGate()
    /// The lists of the current ticket: the keyword rows, and the ranked list once it is in.
    private var keywordHits: [SearchHit] = []
    private var rankedHits: [SearchHit]?
    private var shownList = ListShown.empty
    private var snapshotTimer: Timer?
    /// Command+comma: the app shows the Settings window (slice 1 has no menu bar to hold that command).
    var onOpenSettings: (@MainActor () -> Void)?
    /// True once a helper is attached: the panel then reads the model, settings and index for its states.
    private var readsState = false
    private(set) var isShown = false
    private var previewTicket = 0
    /// The newest preview asked for, and its answer once it is in. A reply of any other ticket is dropped.
    private var requested: (ticket: Int, path: String)?
    /// What `requested` was asked for; a selection with the same key is not asked again (`PreviewRequestKey`).
    private var requestedKey: PreviewRequestKey?
    private var answer: (path: String, reply: PreviewReply)?
    /// Enter pressed before the reply was in: the file it will open, and the wait that ends it.
    private var pendingOpen: String?
    private var pendingTimer: Timer?
    private var enterTask: Task<Void, Never>?
    /// How audio and video open; a test puts a recording fake here.
    var scripting: any MediaScripting = LiveMediaScripting()

    init() {
        let reader = IndexReader()
        self.reader = reader
        status = StatusCache.live(reader: reader, modelState: { .whole })
        super.init(
            contentRect: NSRect(origin: .zero, size: Panel.size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Sesame"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        setFrame(NSRect(origin: .zero, size: Panel.size), display: false)

        queryBox = QueryBox(nextTicket: { [unowned self] in self.takeTicket() })
        queryBox.onChange = { [unowned self] text, ticket in self.queryChanged(text, ticket: ticket) }
        results.onSelect = { [unowned self] hit in self.selectionChanged(hit) }
        results.returnFocus = { [unowned self] in makeFirstResponder(queryBox.field) }
        contentView = makeContent()
        initialFirstResponder = queryBox.field
        // Tab goes from the search box to the list and back; Shift+Tab the other way.
        queryBox.field.nextKeyView = results.keyView
        results.keyView.nextKeyView = queryBox.field
        listen(to: status)
    }

    override var canBecomeKey: Bool { true }

    /// The app that was in front when the panel opened, put back in front when it closes (spec S1.4).
    private var previousApp: NSRunningApplication?

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        queryBox.clear()
        emptyTheBox()
        cancelPendingOpen()
        pane.notice = nil
        results.show(.empty)
        shownList = .empty
        center()
        // Measured: an accessory app that calls activate stays behind the app in front (System Events and
        // the kit still read the old app), so typed text never reaches the panel. A regular app does take
        // the front; the policy goes back to accessory in hide().
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        level = .floating
        makeFirstResponder(queryBox.field)
        isShown = true
        Probe.emit("shown", 0)
        // After the probe stamp: the open itself does no disk work (design section 8). It draws the cached state and
        // asks the cache for a fresh one, which arrives through `onChange`.
        helper?.panelDidOpen()
        if readsState { status.panelOpened() }
        refreshScreen()
        snapshotTimer?.invalidate()
        if readsState {
            snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.status.refresh() }
            }
        }
    }

    /// `restoringPreviousApp` is false when another app is about to take the front (Enter, Command+Enter).
    func hide(restoringPreviousApp: Bool = true) {
        isShown = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        enterTask?.cancel()
        cancelPendingOpen()
        orderOut(nil)
        NSApp.setActivationPolicy(WindowPolicy.policyAfterPanelHides(
            settingsVisible: ShortcutSettingsWindow.isShowing, setupVisible: SetupWindow.isShowing))
        if restoringPreviousApp { previousApp?.activate() }
        previousApp = nil
        helper?.panelDidClose()
    }

    /// The global shortcut: opens the panel, and closes it while it is open.
    func shortcutPressed() {
        if isShown { hide() } else { show() }
    }

    /// Esc: text in the box (spaces count) is cleared and the panel stays; an empty box closes it.
    func pressEscape() {
        if queryBox.text.isEmpty {
            hide()
            return
        }
        queryBox.clear()
        emptyTheBox()
        pane.notice = nil
        refreshScreen()
    }

    /// The box holds no text: a fresh ticket makes every list in flight stale, and nothing is submitted for it.
    private func emptyTheBox() {
        let ticket = takeTicket()
        currentTicket = ticket
        failedTicket = nil
        keywordHits = []
        rankedHits = nil
        gate.boxChanged(text: "", ticket: ticket)
        // No file is selected for an empty box: the pane is cleared and a late preview reply is dropped.
        selectionChanged(nil)
    }

    /// The panel draws from this cache from now on; a change in its value redraws the screen.
    func attach(status cache: StatusCache) {
        status.onChange = nil
        status = cache
        listen(to: cache)
        refreshScreen()
    }

    private func listen(to cache: StatusCache) {
        cache.onChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshScreen() } }
        }
    }

    /// The search runs through the one `HelperClient` of the app: `encode` embeds the typed text for it.
    func attach(helper: HelperClient) {
        self.helper = helper
        readsState = true
        let embedder = HelperEmbedder(client: helper)
        let made = SearchPipeline(
            search: Search(reader: reader), reader: reader, embedder: embedder,
            visible: { SearchPipeline.visibleFromSettings() }, now: { SearchPipeline.uptimeSeconds() })
        let events = HelperEventRelay(
            embedder: embedder,
            onPreview: { [weak self] reply in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.previewArrived(reply) } }
            },
            onIndexChanged: { [weak self] in
                made.indexChanged()
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.status.helperChanged() } }
            })
        relay = events
        helper.delegate = events
        made.onKeyword = { [weak self] ticket, hits in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.listArrived(ticket, hits, ranked: false) } }
        }
        made.onRanked = { [weak self] ticket, hits in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.listArrived(ticket, hits, ranked: true) } }
        }
        made.onFailed = { [weak self] ticket in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.searchFailed(ticket) } }
        }
        pipeline = made
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in made.tick() }
    }

    // MARK: search

    private func takeTicket() -> Int {
        if let pipeline { return pipeline.newTicket() }
        ticketsWithoutPipeline += 1
        return ticketsWithoutPipeline
    }

    private func queryChanged(_ text: String, ticket: Int) {
        currentTicket = ticket
        failedTicket = nil
        keywordHits = []
        rankedHits = nil
        pane.notice = nil
        gate.boxChanged(text: text, ticket: ticket)
        refreshScreen()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pipeline?.submit(text: text, ticket: ticket)
        }
    }

    /// The keyword rows show at once when the whole text was found as a phrase; the ranked list replaces them in
    /// place, or says "No matches" when it is empty. A list of an older ticket is dropped.
    private func listArrived(_ ticket: Int, _ hits: [SearchHit], ranked: Bool) {
        guard ticket == currentTicket else { return }
        if ranked {
            rankedHits = hits
            gate.rankedListArrived(ticket: ticket, count: hits.count)
        } else if rankedHits == nil {
            keywordHits = hits
        }
        refreshScreen()
    }

    /// The embed of this ticket's text failed: the panel says so in place of "Searching", unless the text has moved on
    /// or the ranked list is already in.
    private func searchFailed(_ ticket: Int) {
        guard ticket == currentTicket, rankedHits == nil else { return }
        failedTicket = ticket
        refreshScreen()
    }

    // MARK: the screen

    /// Shows what `PanelScreen` chooses from the cached state (the model, settings and index, refreshed in the
    /// background when the panel opens and once a second while it is open). The list is replaced only when what it
    /// shows changed, so a selection the person moved stays put.
    private func refreshScreen() {
        let inputs = status.snapshot().inputs(typed: queryBox.text, rankedCount: rankedHits?.count)
        let failed = failedTicket != nil && failedTicket == currentTicket
        let screen = PanelScreen.choose(
            inputs, keywordRows: keywordHits.count, stillRanking: gate.stillRankingShown, searchFailed: failed)
        banner.show(screen.banner)
        let wantedBannerHeight = screen.banner == nil ? 0 : IndexingBannerPanel.height
        if bannerHeight.constant != wantedBannerHeight { bannerHeight.constant = wantedBannerHeight }
        statusNote.show(screen.status)
        permissionNote.show(screen.permissionNote)
        var notReadyView: NotReadyView?
        var hint: EmptyHint?
        var searchFailedShown = false
        let list: ListShown
        switch screen.body {
        case let .notReady(view):
            notReadyView = view
            list = .empty
        case let .emptyHint(shown):
            hint = shown
            list = .empty
        case .searching: list = .searching
        case .searchFailed:
            searchFailedShown = true
            list = .empty
        case .noMatches: list = .noMatches
        case .rows: list = .rows(rankedHits ?? keywordHits)
        }
        let fullWidth = notReadyView != nil
        let hideDivider = fullWidth || hint != nil
        if divider.isHidden != hideDivider { divider.isHidden = hideDivider }
        if results.view.isHidden != fullWidth { results.view.isHidden = fullWidth }
        if pane.view.isHidden != fullWidth { pane.view.isHidden = fullWidth }
        notReady.show(notReadyView)
        emptyHint.show(hint)
        searchFailedView.show(searchFailedShown)
        if list != shownList {
            shownList = list
            results.show(list.content)
            keepFocusInBox()
        }
    }

    /// Typed keys must reach the search box: a reload or a selection change never leaves the focus anywhere else.
    /// The list keeps it only when the person tabbed to it.
    private func keepFocusInBox() {
        let responder = firstResponder
        if responder === results.keyView || responder === queryBox.field { return }
        if let editor = responder as? NSText, editor.delegate === queryBox.field { return }
        makeFirstResponder(queryBox.field)
    }

    override func becomeKey() {
        super.becomeKey()
        keepFocusInBox()
    }

    /// Another window taking key (a click on another app, Cmd-Tab) closes a shown panel; the app the person chose stays in front.
    override func resignKey() {
        super.resignKey()
        if isShown { hide(restoringPreviousApp: false) }
    }

    // MARK: the pane

    /// A new selection asks the helper for its preview; the newer ticket makes the older answer stale. The same request
    /// again (a ranked list replacing the keyword rows with the same file, passage and text) is not asked for twice;
    /// another passage or text of a PDF or document is.
    private func selectionChanged(_ hit: SearchHit?) {
        guard let hit else {
            requested = nil
            requestedKey = nil
            answer = nil
            cancelPendingOpen()
            pane.clear()
            return
        }
        // The kind is what the last reply for this file said; before any reply it is "" and the whole key counts.
        let key = PreviewRequestKey(
            path: hit.path, passageID: hit.passageID, kind: requestedKey?.path == hit.path ? requestedKey?.kind ?? "" : "",
            query: queryBox.text)
        if !key.needsRequest(after: requestedKey) { return }
        cancelPendingOpen()
        previewTicket += 1
        requested = (previewTicket, hit.path)
        requestedKey = key
        answer = nil
        pane.showPending(path: hit.path)
        helper?.preview(ticket: previewTicket, file: hit.path, passage: Int(exactly: hit.passageID), query: queryBox.text)
    }

    private func previewArrived(_ reply: PreviewReply) {
        // Every PNG is loaded, so every one is deleted; only the newest is drawn.
        let image = reply.png.flatMap { ScratchPNG.load(path: $0) }
        guard let requested, reply.ticket == requested.ticket else { return }
        answer = (requested.path, reply)
        if let key = requestedKey, key.path == requested.path {
            requestedKey = PreviewRequestKey(path: key.path, passageID: key.passageID, kind: reply.kind, query: key.query)
        }
        pane.show(reply, path: requested.path, image: image)
        if pendingOpen == requested.path { finishOpen(requested.path, reply: reply) }
    }

    // MARK: keys

    /// Up and Down move the selection; Enter opens, Command+Enter reveals in Finder, Command+C copies the file when
    /// no text in the box is selected. Typing stays in the search box, which gets every other key.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handle(event) { return }
        super.sendEvent(event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chord = HotKey.combination(keyCode: Int(event.keyCode), modifiers: modifiers) ?? ""
        if SettingsWindow.isOpenCommand(chord) {
            openSettings()
            return true
        }
        switch Int(event.keyCode) {
        case kVK_UpArrow, kVK_DownArrow:
            guard modifiers.isEmpty else { return false }
            pane.notice = nil
            results.move(by: Int(event.keyCode) == kVK_UpArrow ? -1 : 1)
            return true
        case kVK_Escape:
            guard modifiers.isEmpty else { return false }
            pressEscape()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if modifiers.isEmpty {
                pressEnter()
            } else if modifiers == .command {
                revealSelected()
            } else {
                return false
            }
            return true
        default:
            guard modifiers == .command else { return false }
            switch event.charactersIgnoringModifiers {
            case "a":
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                return true
            case "c":
                copySelected()
                return true
            case "v":
                if let pasted = NSPasteboard.general.string(forType: .string) {
                    queryBox.paste(pasted, replacing: queryBox.field.currentEditor()?.selectedRange ?? NSRange(location: (queryBox.text as NSString).length, length: 0))
                }
                return true
            default:
                return false
            }
        }
    }

    /// Settings comes up first and then the panel goes, so the app stays in front and keeps its policy.
    private func openSettings() {
        onOpenSettings?()
        if isShown { hide(restoringPreviousApp: false) }
    }

    /// Enter opens the first result of the text in the box, never one of an older keystroke: the gate waits for
    /// that ticket's ranked list for 2 s and otherwise the panel says "Still ranking".
    func pressEnter() {
        // The ranked list of a failed embed never comes: Enter opens a keyword row if one is shown, else does nothing.
        if failedTicket != nil, failedTicket == currentTicket {
            openSelected()
            return
        }
        enterTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let decision = await gate.pressEnter()
            if Task.isCancelled { return }
            switch decision {
            case let .open(ticket):
                if ticket == currentTicket { openSelected() }
            case .stillRanking:
                refreshScreen()
            case .nothing:
                break
            }
        }
    }

    /// The reply says what kind of file this is, so it is waited for up to a second; without it the file opens in
    /// its default app.
    private func openSelected() {
        guard let hit = results.selectedHit, pendingOpen == nil else { return }
        if Opener.isGone(path: hit.path) { return fileIsGone(hit.path) }
        if let answer, answer.path == hit.path { return finishOpen(hit.path, reply: answer.reply) }
        pendingOpen = hit.path
        pendingTimer = Timer.scheduledTimer(withTimeInterval: Self.replyWaitSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishOpen(hit.path, reply: nil) }
        }
    }

    /// Audio and video open at the reply's second, else at the second stored with the selected passage.
    private func finishOpen(_ path: String, reply: PreviewReply?) {
        cancelPendingOpen()
        if Opener.isGone(path: path) { return fileIsGone(path) }
        let kind = reply?.kind ?? Rules.kind(forExtension: URL(fileURLWithPath: path).pathExtension.lowercased()) ?? ""
        let isMedia = kind == "audio" || kind == "video"
        let spot = Opener.moment(reply: reply, stored: isMedia && reply?.seconds == nil ? storedSecond(of: path) : nil)
        if isShown { hide(restoringPreviousApp: false) }
        if kind == "pdf" {
            Opener.perform(Opener.action(kind: kind, path: path, spot: nil), path: path)
        } else {
            Opener.open(kind: kind, path: path, spot: spot, chosen: Opener.chosenMedia(), using: scripting)
        }
    }

    private func storedSecond(of path: String) -> Int? {
        guard let hit = results.selectedHit, hit.path == path, let spot = reader.passageSpot(hit.passageID),
              spot.source == "audio" || spot.source == "frame" else { return nil }
        return Int(spot.start)
    }

    private func revealSelected() {
        guard let hit = results.selectedHit else { return }
        if Opener.isGone(path: hit.path) { return fileIsGone(hit.path) }
        hide(restoringPreviousApp: false)
        Opener.reveal(path: hit.path)
    }

    /// With text selected in the box the box copies it. Otherwise the key is the file's: it copies the file, or
    /// says the file has gone, or does nothing when there is no result.
    private func copySelected() {
        let selected = (firstResponder as? NSTextView)?.selectedRange.length ?? 0
        if selected > 0 {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            return
        }
        guard let hit = results.selectedHit else { return }
        if Opener.isGone(path: hit.path) { return fileIsGone(hit.path) }
        _ = Opener.copyFileURL(selectedTextLength: 0, path: hit.path, to: .general)
    }

    /// The row leaves the list and the next one is selected; the pane keeps saying why.
    private func fileIsGone(_ path: String) {
        cancelPendingOpen()
        results.dropGone(path)
        pane.notice = Pane.statusText(.gone)
    }

    private func cancelPendingOpen() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingOpen = nil
    }

    // MARK: layout

    private func makeContent() -> NSView {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Design.secondaryLabel
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let field = queryBox.field
        field.placeholderAttributedString = NSAttributedString(
            string: AccessibilityLabels.searchBox,
            attributes: [.foregroundColor: NSColor.placeholderTextColor, .font: Typeface.query])
        let top = NSBox()
        top.boxType = .separator
        divider.boxType = .separator
        let preview = pane.view
        field.setAccessibilityLabel(AccessibilityLabels.searchBox)
        preview.setAccessibilityElement(true)
        preview.setAccessibilityRole(.group)
        preview.setAccessibilityLabel(AccessibilityLabels.preview)

        let footer = NSView()
        footer.setAccessibilityIdentifier("PanelFooter")
        let hintLine = QuietLabel(labelWithString: "↩ Open  ⌘↩ Reveal  ⌘C Copy  esc Close")
        hintLine.font = Typeface.caption
        hintLine.textColor = Design.secondaryLabel
        hintLine.setContentCompressionResistancePriority(.required, for: .horizontal)
        let notes = NSStackView(views: [statusNote, permissionNote])
        notes.orientation = .horizontal
        notes.alignment = .centerY
        notes.spacing = Space.s4
        for part in [hintLine, notes] {
            part.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(part)
        }
        let parts: [NSView] = [icon, field, top, banner, results.view, divider, preview, footer, emptyHint, searchFailedView, notReady]
        for part in parts {
            part.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(part)
        }
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bannerHeight,
            banner.topAnchor.constraint(equalTo: top.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            hintLine.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: Space.s6),
            hintLine.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            notes.leadingAnchor.constraint(greaterThanOrEqualTo: hintLine.trailingAnchor, constant: Space.s4),
            notes.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -Space.s6),
            notes.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            emptyHint.topAnchor.constraint(equalTo: banner.bottomAnchor),
            emptyHint.bottomAnchor.constraint(equalTo: footer.topAnchor),
            emptyHint.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            emptyHint.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            searchFailedView.topAnchor.constraint(equalTo: banner.bottomAnchor),
            searchFailedView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            searchFailedView.leadingAnchor.constraint(equalTo: results.view.leadingAnchor),
            searchFailedView.trailingAnchor.constraint(equalTo: results.view.trailingAnchor),
            notReady.topAnchor.constraint(equalTo: banner.bottomAnchor),
            notReady.bottomAnchor.constraint(equalTo: footer.topAnchor),
            notReady.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            notReady.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Space.s6),
            icon.centerYAnchor.constraint(equalTo: background.topAnchor, constant: Self.searchBarHeight / 2),
            icon.widthAnchor.constraint(equalToConstant: 20),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Space.s3),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Space.s6),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            top.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.searchBarHeight),
            top.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            results.view.topAnchor.constraint(equalTo: banner.bottomAnchor),
            results.view.bottomAnchor.constraint(equalTo: footer.topAnchor),
            results.view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            results.view.widthAnchor.constraint(equalTo: background.widthAnchor, multiplier: 0.4),
            divider.leadingAnchor.constraint(equalTo: results.view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: banner.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            preview.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            preview.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            preview.topAnchor.constraint(equalTo: banner.bottomAnchor),
            preview.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])
        return background
    }
}

/// What the list shows, as a value: `ResultList.Content` is not Equatable and the list is replaced only on a change.
private enum ListShown: Equatable {
    case empty
    case searching
    case noMatches
    case rows([SearchHit])

    var content: ResultList.Content {
        switch self {
        case .empty: return .empty
        case .searching: return .searching
        case .noMatches: return .noMatches
        case let .rows(found): return .rows(found)
        }
    }
}
