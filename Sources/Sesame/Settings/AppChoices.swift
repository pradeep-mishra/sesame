import AppKit
import Foundation
import SesameEngine

/// One app a picker offers: the name the person sees (also what `settings.json` stores) and its bundle id.
struct AppOption: Equatable {
    let name: String
    let bundleID: String
}

/// Asks the machine whether an app is installed.
protocol AppLookup {
    func isInstalled(bundleID: String) -> Bool
}

struct InstalledApps: AppLookup {
    func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

enum AppChoicesError: Error, Equatable {
    case unknownKind(String)
}

/// The two "open with" pickers of Settings (mockup F3): which apps each offers, whether an app is installed, and
/// where a choice is stored (`openWith.pdf|media` of `settings.json`). Opens no app.
struct AppChoices {
    static let kinds = ["pdf", "media"]

    private static let table: [String: [AppOption]] = [
        "pdf": [
            AppOption(name: "Preview", bundleID: "com.apple.Preview"),
            AppOption(name: "Adobe Acrobat", bundleID: "com.adobe.Acrobat.Pro"),
            AppOption(name: "Skim", bundleID: "net.sourceforge.skim-app.skim"),
        ],
        "media": [
            AppOption(name: "QuickTime Player", bundleID: "com.apple.QuickTimePlayerX"),
            AppOption(name: "IINA", bundleID: "com.colliderli.iina"),
            AppOption(name: "VLC", bundleID: "org.videolan.vlc"),
        ],
    ]

    let lookup: any AppLookup

    init(lookup: any AppLookup = InstalledApps()) { self.lookup = lookup }

    static func options(for kind: String) -> [AppOption] { table[kind] ?? [] }

    /// nil when the app is installed; else the line Settings shows under the picker.
    func note(for option: AppOption) -> String? {
        lookup.isInstalled(bundleID: option.bundleID)
            ? nil : "\(option.name) is not installed. Enter opens the file in the default app."
    }

    /// Stores the app's name in `openWith.<kind>`; allowed for an app that is not installed.
    func choose(_ option: AppOption, for kind: String) throws {
        guard Self.kinds.contains(kind) else { throw AppChoicesError.unknownKind(kind) }
        var settings = try SettingsFile().read()
        switch kind {
        case "pdf": settings.openWith.pdf = option.name
        default: settings.openWith.media = option.name
        }
        try SettingsFile().write(settings)
    }
}
