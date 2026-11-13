import AppKit
import Carbon.HIToolbox
import SesameEngine

/// A global shortcut as settings.json keeps it ("ctrl+opt+space"): "+"-joined, lower case, modifiers `ctrl` `opt` `cmd`
/// `shift` and one key. This maps that text to the Carbon key code and modifiers, and a key event to that text.
enum HotKey {
    /// Named by the key's position (`kVK_`), so the name does not depend on the keyboard layout.
    private static let keys: [(name: String, code: Int)] = [
        ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
        ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
        ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
        ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
        ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
        ("z", kVK_ANSI_Z),
        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
        ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ("space", kVK_Space), ("return", kVK_Return), ("tab", kVK_Tab), ("delete", kVK_Delete),
        ("left", kVK_LeftArrow), ("right", kVK_RightArrow), ("up", kVK_UpArrow), ("down", kVK_DownArrow),
        ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4), ("f5", kVK_F5), ("f6", kVK_F6),
        ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12),
        ("comma", kVK_ANSI_Comma), ("period", kVK_ANSI_Period), ("slash", kVK_ANSI_Slash),
        ("semicolon", kVK_ANSI_Semicolon), ("quote", kVK_ANSI_Quote), ("backslash", kVK_ANSI_Backslash),
        ("bracketleft", kVK_ANSI_LeftBracket), ("bracketright", kVK_ANSI_RightBracket),
        ("minus", kVK_ANSI_Minus), ("equal", kVK_ANSI_Equal), ("grave", kVK_ANSI_Grave),
    ]
    private static let codeByName = Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0.code) })
    private static let nameByCode = Dictionary(uniqueKeysWithValues: keys.map { ($0.code, $0.name) })

    /// The Carbon key code and modifier mask of a combination, or nil when it is not one key with modifiers.
    static func parse(_ combination: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        var key: Int?
        for part in combination.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "ctrl": modifiers |= UInt32(controlKey)
            case "opt": modifiers |= UInt32(optionKey)
            case "cmd": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default:
                guard key == nil, let code = codeByName[part] else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        return (UInt32(key), modifiers)
    }

    /// The combination a key press makes, or nil for a key that has no name here.
    static func combination(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let key = nameByCode[keyCode] else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.shift) { parts.append("shift") }
        return (parts + [key]).joined(separator: "+")
    }
}

/// The shortcut control of Settings (design sections 1 and 6): the combination in force, what it reads as, and the one
/// status message. A recorded combination goes through `ShortcutPolicy`; an accepted one is stored in settings.json and
/// reported to `onChange`, which the app connects to its hotkey registration. A refusal keeps the old combination.
@MainActor
final class ShortcutControl {
    nonisolated static let defaultCombination = "ctrl+opt+space"
    nonisolated static let recordTitle = "Record new shortcut"
    nonisolated static let backToDefaultTitle = "Back to default"
    nonisolated static let accessibilityLabel = "Keyboard shortcut"
    nonisolated static let unusableKeyText = "That key can't be used as a shortcut. Pick another."
    nonisolated static let notSavedText = "The shortcut could not be saved."
    nonisolated static let unavailableText = "That shortcut is not available. Pick another."

    private let onChange: (String) -> Void
    private(set) var combination: String
    /// Why the last recorded key was refused; nil at the start and after an accepted key or Back to default.
    private(set) var message: String?
    /// What `adoptLive` has to tell Settings, until `takeNotice()` hands it over.
    private var notice: String?

    private let registrar: (any HotKeyRegistrar)?

    /// `registrar` is told of every accepted change; the caller registers the combination in force at launch.
    init(registrar: (any HotKeyRegistrar)? = nil, onChange: @escaping (String) -> Void = { _ in }) {
        self.registrar = registrar
        self.onChange = onChange
        let stored = (try? SettingsFile().read().hotkey) ?? ""
        combination = HotKey.parse(stored) == nil ? Self.defaultCombination : stored
    }

    /// What the control shows: "Control Option Space" for the default.
    var displayText: String {
        Self.words(for: combination)
    }

    /// The recorder saw this combination.
    func record(_ proposed: String) {
        let choice = ShortcutPolicy.choose(proposed, keeping: combination)
        guard choice.accepted else {
            message = choice.message
            return
        }
        guard HotKey.parse(choice.combination) != nil else {
            message = Self.unusableKeyText
            return
        }
        store(choice.combination)
    }

    func backToDefault() {
        store(Self.defaultCombination)
    }

    /// The recorder saw a key that has no name here.
    func refuseUnnamedKey() {
        message = Self.unusableKeyText
    }

    /// Puts a message from outside the recorder (the launch failure) in the status line; nothing else changes.
    func report(_ text: String) {
        message = text
    }

    func clearMessage() {
        message = nil
    }

    /// The saved combination was refused at launch and `live` (the default) registered. `live` is stored as the
    /// combination in force, so the file never reads as working when it is not, and one notice is queued for Settings.
    /// The registration is already live, so `onChange` is not called. A failed write keeps `live` in force and the
    /// notice then says it was not saved.
    func adoptLive(_ live: String, refused: String) {
        combination = live
        do {
            let file = SettingsFile()
            var settings = try file.read()
            settings.hotkey = live
            try file.write(settings)
            let taken = Self.words(for: refused)
            notice = "The shortcut \(taken) is taken by another app, so Sesame is using \(Self.words(for: live))."
        } catch {
            notice = Self.notSavedText
        }
    }

    /// The notice `adoptLive` queued, once; nil after that and when nothing was adopted.
    func takeNotice() -> String? {
        defer { notice = nil }
        return notice
    }

    /// The old registration goes first and the new one is made; if macOS refuses it, or settings.json cannot be
    /// written, the old one is put back and nothing else changes.
    private func store(_ new: String) {
        let old = combination
        if let registrar {
            registrar.unregister()
            guard registrar.register(new) else {
                _ = registrar.register(old)
                message = Self.unavailableText
                return
            }
        }
        do {
            let file = SettingsFile()
            var settings = try file.read()
            settings.hotkey = new
            try file.write(settings)
        } catch {
            if let registrar {
                registrar.unregister()
                _ = registrar.register(old)
            }
            message = Self.notSavedText
            return
        }
        combination = new
        message = nil
        onChange(new)
    }

    private nonisolated static func words(for combination: String) -> String {
        let parts = combination.lowercased().split(separator: "+").map(String.init)
        let modifierWords = [("ctrl", "Control"), ("opt", "Option"), ("shift", "Shift"), ("cmd", "Command")]
        let modifiers = modifierWords.filter { parts.contains($0.0) }.map(\.1)
        let keys = parts.filter { part in !modifierWords.contains { $0.0 == part } }.map(\.capitalized)
        return (modifiers + keys).joined(separator: " ")
    }
}
