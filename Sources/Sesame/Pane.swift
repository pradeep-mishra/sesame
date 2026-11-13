import AppKit
import SesameEngine

/// The right side of the E1 split panel: the helper's picture of the selected file (a PDF's page with "Page N of M"
/// under it) or the passage of a document with the matched words marked, its name, full path, kind, size and date, the
/// app it opens in, and one quiet status line. The app draws what the helper sent and parses nothing from the user's file.
@MainActor
final class Pane {
    let view = NSView()
    private let picture = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
    private let locator = NSTextField(labelWithString: "")
    private let passage = NSTextView()
    private let passageScroll = NSScrollView()
    private let frame = PreviewFrame()
    private let opensIn = NSTextField(labelWithString: "")
    private let statusLine = NSTextField(labelWithString: "")
    private var statusFromReply: String?

    /// A line that outlives the selection that caused it: "That file is no longer there" after a row was dropped.
    var notice: String? {
        didSet { showStatus() }
    }

    /// The line for a preview reply's status; nil when there is nothing to say.
    static func statusText(_ status: PreviewStatus) -> String? {
        switch status {
        case .ok: return nil
        case .changed: return "changed since indexed"
        case .gone: return "That file is no longer there"
        }
    }

    init() {
        view.setAccessibilityLabel("File preview")
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.imageAlignment = .alignCenter
        picture.setAccessibilityLabel("Preview picture")
        picture.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        picture.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = Design.label
        name.lineBreakMode = .byTruncatingMiddle
        path.font = Typeface.secondary
        path.textColor = Design.secondaryLabel
        path.lineBreakMode = .byTruncatingMiddle
        details.font = Typeface.secondary
        details.textColor = Design.secondaryLabel
        locator.font = Typeface.body
        locator.textColor = Design.label
        opensIn.font = Typeface.secondary
        opensIn.textColor = Design.secondaryLabel
        statusLine.font = Typeface.secondary
        statusLine.textColor = Design.secondaryLabel

        passage.isEditable = false
        passage.isSelectable = true
        passage.drawsBackground = false
        passage.isVerticallyResizable = true
        passage.isHorizontallyResizable = false
        passage.autoresizingMask = [.width]
        passage.textContainerInset = NSSize(width: Space.s2, height: Space.s2)
        passage.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        passage.textContainer?.widthTracksTextView = true
        passage.setAccessibilityLabel("Passage")
        passageScroll.documentView = passage
        passageScroll.hasVerticalScroller = true
        passageScroll.drawsBackground = false
        passageScroll.borderType = .noBorder

        picture.translatesAutoresizingMaskIntoConstraints = false
        passageScroll.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(picture)
        frame.addSubview(passageScroll)

        let texts = NSStackView(views: [name, path, details, locator, opensIn, statusLine])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = Space.s3
        texts.translatesAutoresizingMaskIntoConstraints = false
        texts.setContentHuggingPriority(.required, for: .vertical)
        texts.setContentCompressionResistancePriority(.required, for: .vertical)
        picture.setContentHuggingPriority(.init(rawValue: 100), for: .vertical)
        frame.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frame)
        view.addSubview(texts)

        var constraints = [
            frame.topAnchor.constraint(equalTo: view.topAnchor, constant: Space.s6),
            frame.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Space.s6),
            frame.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Space.s6),
            texts.topAnchor.constraint(equalTo: frame.bottomAnchor, constant: Space.s4),
            texts.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Space.s6),
            texts.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Space.s6),
            texts.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Space.s6),
            picture.topAnchor.constraint(equalTo: frame.topAnchor, constant: Space.s3),
            picture.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -Space.s3),
            picture.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: Space.s3),
            picture.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -Space.s3),
            passageScroll.topAnchor.constraint(equalTo: frame.topAnchor, constant: Space.s3),
            passageScroll.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -Space.s3),
            passageScroll.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: Space.s3),
            passageScroll.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -Space.s3),
        ]
        for label in [name, path, details, locator, opensIn, statusLine] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: texts.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        clear()
    }

    /// Nothing selected. The notice, if any, stays.
    func clear() {
        picture.image = nil
        picture.isHidden = false
        picture.setAccessibilityLabel("Preview picture")
        showPassage(nil, marks: [])
        for label in [name, path, details, locator, opensIn] { set(label, nil) }
        statusFromReply = nil
        showStatus()
        updateFrame()
    }

    /// The file is selected and the helper has not answered yet: what the list already knows.
    func showPending(path filePath: String) {
        clear()
        set(name, URL(fileURLWithPath: filePath).lastPathComponent)
        set(path, filePath)
    }

    /// The helper's answer for the selected file. `image` is nil for a gone file or a picture that did not load.
    func show(_ reply: PreviewReply, path filePath: String, image: NSImage?) {
        picture.image = image
        picture.isHidden = reply.kind == "doc"
        picture.setAccessibilityLabel("Preview of \(reply.name)")
        showPassage(reply.text, marks: reply.marks)
        set(locator, reply.status == .gone ? nil : reply.locator)
        set(name, reply.name)
        set(path, filePath)
        var facts = [reply.kind]
        if let size = reply.size { facts.append(Self.sizeText(size)) }
        if let mtime = reply.mtime { facts.append(Self.dateText(mtime)) }
        set(details, reply.status == .gone ? nil : facts.joined(separator: " · "))
        set(opensIn, reply.status == .gone ? nil
            : Opener.opensInText(kind: reply.kind, defaultAppName: Opener.defaultAppName(forPath: filePath)))
        statusFromReply = Self.statusText(reply.status)
            ?? (image == nil && (reply.text ?? "").isEmpty ? "Can't preview this file" : nil)
        showStatus()
        updateFrame()
    }

    private func updateFrame() {
        let hasPicture = !picture.isHidden && picture.image != nil
        let hidden = !hasPicture && passageScroll.isHidden
        if frame.isHidden != hidden { frame.isHidden = hidden }
    }

    /// The passage of a document with a background colour on the marked ranges (flat start, end UTF-16 offsets into
    /// `text`); an empty or missing passage hides the view and drops the text and every colour with it.
    private func showPassage(_ text: String?, marks: [Int]) {
        let shown = text ?? ""
        passageScroll.isHidden = shown.isEmpty
        guard let storage = passage.textStorage else { return }
        let plain: [NSAttributedString.Key: Any] = [.font: Typeface.body, .foregroundColor: Design.label]
        storage.setAttributedString(NSAttributedString(string: shown, attributes: plain))
        var pair = 0
        while pair + 1 < marks.count {
            let range = NSRange(location: marks[pair], length: marks[pair + 1] - marks[pair])
            if range.location >= 0, range.length > 0, NSMaxRange(range) <= storage.length {
                storage.addAttribute(.backgroundColor, value: Design.matchFill, range: range)
            }
            pair += 2
        }
        passage.scroll(.zero)
    }

    private func showStatus() {
        set(statusLine, notice ?? statusFromReply)
    }

    private func set(_ label: NSTextField, _ text: String?) {
        label.stringValue = text ?? ""
        label.isHidden = text == nil
    }

    private static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func dateText(_ epochSeconds: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds)).formatted(date: .abbreviated, time: .omitted)
    }
}

private final class PreviewFrame: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Radius.group
        layer?.borderWidth = 1
        refreshColours()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        refreshColours()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColours()
    }

    private func refreshColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Design.controlBackground.cgColor
            layer?.borderColor = Design.separator.cgColor
        }
    }
}
