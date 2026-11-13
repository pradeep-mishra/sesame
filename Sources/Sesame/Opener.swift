import AppKit
import SesameEngine

/// The one seam to the machine for opening audio and video: an AppleScript run and a plain open of the default app.
protocol MediaScripting: Sendable {
    func run(_ source: String) -> Bool
    func open(_ url: URL)
}

struct LiveMediaScripting: MediaScripting {
    func run(_ source: String) -> Bool {
        var failure: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        _ = script.executeAndReturnError(&failure)
        return failure == nil
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Where an audio or video file opens: QuickTime Player at a moment, or the default app (every other listed app, installed or not).
enum MediaTarget: Equatable {
    case quickTime
    case defaultApp
}

/// What Enter does for one file (design section 5). Chosen from the kind word and the spot, with no side effect.
enum OpenAction: Equatable {
    case defaultApp(URL)
    case preview(URL, page: Int?)
    case quickTime(URL, seconds: Int?)
}

/// Every open of a result goes through here: Enter, Command+Enter and Command+C.
enum Opener {
    /// `spot` is the page, or the whole seconds; it is ignored for photos, documents and unknown kinds.
    static func action(kind: String, path: String, spot: Int?) -> OpenAction {
        let url = URL(fileURLWithPath: path)
        switch kind {
        case "pdf":
            return .preview(url, page: spot)
        case "audio", "video":
            return .quickTime(url, seconds: spot)
        default:
            return .defaultApp(url)
        }
    }

    static func opensInText(kind: String, defaultAppName: String) -> String {
        switch kind {
        case "pdf": return "Opens in Preview"
        case "audio", "video":
            return mediaTarget(chosen: chosenMedia()) == .quickTime ? "Opens in QuickTime Player" : "Opens in \(defaultAppName)"
        default: return "Opens in \(defaultAppName)"
        }
    }

    static func mediaTarget(chosen: String) -> MediaTarget {
        chosen.isEmpty || chosen == "QuickTime Player" ? .quickTime : .defaultApp
    }

    /// The reply's second when the reply has one, else the stored second.
    static func moment(reply: PreviewReply?, stored: Int?) -> Int? {
        reply?.seconds ?? stored
    }

    /// The app chosen for audio and video in Settings; empty when none is chosen or the file cannot be read.
    static func chosenMedia() -> String {
        (try? SettingsFile().read())?.openWith.media ?? ""
    }

    static func quickTimeScript(path: String, seconds: Int) -> String {
        let quoted = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
            tell application "QuickTime Player"
                set theDocument to open POSIX file "\(quoted)"
                set current time of theDocument to \(max(seconds, 0))
                play theDocument
                activate
            end tell
            """
    }

    /// Command+C: the file URL goes on the pasteboard when no text in the box is selected and a file is selected.
    /// True when the key was used up.
    static func copyFileURL(selectedTextLength: Int, path: String?, to pasteboard: NSPasteboard) -> Bool {
        guard selectedTextLength == 0, let path else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
    }

    static func isGone(path: String) -> Bool {
        !FileManager.default.fileExists(atPath: path)
    }

    // MARK: effects

    /// The name Launch Services gives the app that opens this file, for "Opens in <app>".
    @MainActor
    static func defaultAppName(forPath path: String) -> String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)) else {
            return "the default app"
        }
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// A chosen app that is missing falls back to the default app. Landing on the page or second is plan 4 and 5.
    @MainActor
    static func perform(_ action: OpenAction, path: String) {
        let file = URL(fileURLWithPath: path)
        switch action {
        case let .defaultApp(url):
            NSWorkspace.shared.open(url)
        case let .preview(url, _):
            open(url, withAppID: "com.apple.Preview", fallback: file)
        case let .quickTime(url, _):
            open(url, withAppID: "com.apple.QuickTimePlayerX", fallback: file)
        }
    }

    /// Audio and video with QuickTime Player chosen run the script; if it fails, or for any other file or app, the default app opens the file.
    @MainActor
    static func open(kind: String, path: String, spot: Int?, chosen: String, using scripting: any MediaScripting) {
        if kind == "audio" || kind == "video", mediaTarget(chosen: chosen) == .quickTime,
           scripting.run(quickTimeScript(path: path, seconds: spot ?? 0)) {
            return
        }
        scripting.open(URL(fileURLWithPath: path))
    }

    @MainActor
    static func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @MainActor
    private static func open(_ url: URL, withAppID id: String, fallback: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            NSWorkspace.shared.open(fallback)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
