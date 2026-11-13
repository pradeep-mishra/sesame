import Foundation

/// The global shortcut at launch. The saved combination is tried first, then the default. When neither can be
/// registered the app would be invisible, so `onFailure` gets a message once and the caller shows it.
@MainActor
enum LaunchHotKey {
    static let failedText =
        "Sesame could not register its keyboard shortcut. Another app may be using it. Record a new one here."

    /// What the launch ended with. One registration is live at most, and none for `.none`.
    enum Outcome: Equatable {
        /// The saved combination registered.
        case saved(String)
        /// The saved one was refused (or is not a combination) and the default registered.
        case fellBack(live: String, refused: String)
        /// Neither registered.
        case none
    }

    static func resolve(combination: String, registrar: any HotKeyRegistrar, onFailure: (String) -> Void) -> Outcome {
        if registrar.register(combination) { return .saved(combination) }
        let fallback = ShortcutControl.defaultCombination
        if combination != fallback, registrar.register(fallback) {
            return .fellBack(live: fallback, refused: combination)
        }
        onFailure(failedText)
        return .none
    }

    /// The combination now in force, or nil when neither could be registered.
    @discardableResult
    static func register(combination: String, registrar: any HotKeyRegistrar, onFailure: (String) -> Void) -> String? {
        switch resolve(combination: combination, registrar: registrar, onFailure: onFailure) {
        case .saved(let live), .fellBack(let live, _): return live
        case .none: return nil
        }
    }
}
