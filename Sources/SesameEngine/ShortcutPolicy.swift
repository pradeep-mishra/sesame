import Foundation

public struct ShortcutChoice: Equatable {
    public let accepted: Bool
    public let combination: String
    public let message: String?
}

/// Which global shortcuts Sesame accepts. A combination is "+"-joined, lower case, as settings.json keeps it.
public enum ShortcutPolicy {
    /// The closed list of refused combinations, each as a sorted set of keys.
    private static let refused: Set<[String]> = [
        ["cmd", "space"], ["cmd", "tab"], ["cmd", "q"], ["cmd", "h"], ["cmd", "w"], ["cmd", "ctrl", "q"],
    ].reduce(into: []) { $0.insert($1.sorted()) }

    public static func choose(_ proposed: String, keeping current: String) -> ShortcutChoice {
        let keys = proposed.lowercased().split(separator: "+").map(String.init)
        if !keys.contains(where: { ["cmd", "ctrl", "opt"].contains($0) }) {
            return refusal(current, "Use Command, Control or Option with a key.")
        }
        if refused.contains(keys.sorted()) {
            return refusal(current, "That shortcut is already used by macOS. Pick another.")
        }
        return ShortcutChoice(accepted: true, combination: keys.joined(separator: "+"), message: nil)
    }

    private static func refusal(_ current: String, _ message: String) -> ShortcutChoice {
        ShortcutChoice(accepted: false, combination: current, message: message)
    }
}
