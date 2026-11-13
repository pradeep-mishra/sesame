import AppKit
import SesameEngine

/// The search box (design section 3): every keystroke takes a ticket and is reported with the text now in the box.
/// Text typed or pasted beyond 500 characters is cut to the first 500 (counted as characters) and the cut text shown.
/// The text field is made only when the panel asks for it, so the logic runs without a window.
@MainActor
final class QueryBox: NSObject, NSTextFieldDelegate {
    private let nextTicket: @MainActor () -> Int
    private var fieldIfMade: NSTextField?
    private(set) var text = ""

    /// Called after each change of the text with the text now in the box and that keystroke's ticket.
    var onChange: (@MainActor (String, Int) -> Void)?

    init(nextTicket: @escaping @MainActor () -> Int) {
        self.nextTicket = nextTicket
        super.init()
    }

    /// One keystroke per character, at the end of the text.
    func type(_ characters: String) {
        for character in characters { change(to: text + String(character)) }
    }

    func paste(_ pasted: String) {
        change(to: text + pasted)
    }

    /// A paste over the field editor's selection (`selection` in UTF-16 units, clamped to the text): the selected
    /// characters are replaced, or the text is inserted at the caret, and the caret lands after the pasted text.
    func paste(_ pasted: String, replacing selection: NSRange) {
        let current = text as NSString
        let location = min(max(selection.location, 0), current.length)
        let length = min(max(selection.length, 0), current.length - location)
        let joined = current.replacingCharacters(in: NSRange(location: location, length: length), with: pasted)
        change(to: joined, caret: location + (pasted as NSString).length)
    }

    func deleteBackward() {
        change(to: String(text.dropLast()))
    }

    /// The panel opened: an empty box, and no keystroke.
    func clear() {
        text = ""
        if let fieldIfMade, !fieldIfMade.stringValue.isEmpty { fieldIfMade.stringValue = "" }
    }

    var field: NSTextField {
        if let fieldIfMade { return fieldIfMade }
        let made = NSTextField(string: text)
        made.isBordered = false
        made.drawsBackground = false
        made.focusRingType = .none
        made.font = .systemFont(ofSize: 22)
        made.placeholderString = "Search your files"
        made.setAccessibilityLabel("Search your files")
        made.usesSingleLineMode = true
        made.cell?.isScrollable = true
        made.delegate = self
        fieldIfMade = made
        return made
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let edited = notification.object as? NSTextField else { return }
        change(to: edited.stringValue)
    }

    /// `caret` is where the caret goes in the field (UTF-16 units, kept inside the text); without it the caret goes to the end.
    private func change(to candidate: String, caret: Int? = nil) {
        let ticket = nextTicket()
        text = PanelState.cut(candidate)
        // The field is written only when it differs from the box (a cut or a paste), never for text the person typed,
        // and then the caret goes to the end of what is shown. A paste at a place writes it and puts the caret there.
        if let fieldIfMade, caret != nil || fieldIfMade.stringValue != text {
            let end = (text as NSString).length
            fieldIfMade.stringValue = text
            fieldIfMade.currentEditor()?.selectedRange = NSRange(location: min(caret ?? end, end), length: 0)
        }
        Probe.emit("key", ticket)
        onChange?(text, ticket)
    }
}
