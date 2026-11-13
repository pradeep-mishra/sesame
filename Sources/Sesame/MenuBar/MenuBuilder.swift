import AppKit

/// What each action item of the menu does. The app wires the real closures; a test passes a recorder.
struct MenuActions {
    let pause: @MainActor () -> Void
    let resume: @MainActor () -> Void
    let resumeAnyway: @MainActor () -> Void
    let retryDownload: @MainActor () -> Void
    let open: @MainActor () -> Void
    let settings: @MainActor () -> Void
    let quit: @MainActor () -> Void
}

/// Holds one closure as the target of one menu item (an `NSMenuItem` keeps its target only weakly).
@MainActor
private final class MenuActionTarget: NSObject {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) { self.run = run }

    @objc func fire(_ sender: Any?) { run() }
}

/// The menu and the targets of its items, which live as long as the menu does.
@MainActor
private final class SesameMenu: NSMenu {
    var targets: [MenuActionTarget] = []
}

@MainActor
enum MenuBuilder {
    private static let kinds: [(kind: String, name: String)] = [
        ("photo", "Photos"), ("pdf", "PDFs"), ("doc", "Documents"),
        ("audio", "Audio"), ("video", "Video"),
    ]

    static func build(_ model: MenuModel, actions: MenuActions) -> NSMenu {
        let menu = SesameMenu(title: "Sesame")
        menu.autoenablesItems = false

        var pending: [NSMenuItem] = []

        func line(_ text: String) {
            pending.append(item(text, enabled: false))
        }
        func action(_ text: String, key: String = "", symbol: String? = nil, run: @escaping @MainActor () -> Void) {
            let target = MenuActionTarget(run)
            menu.targets.append(target)
            let entry = item(text, enabled: true, symbol: symbol)
            entry.target = target
            entry.action = #selector(MenuActionTarget.fire(_:))
            if !key.isEmpty {
                entry.keyEquivalent = key
                entry.keyEquivalentModifierMask = .command
            }
            pending.append(entry)
        }
        func group(_ add: () -> Void) {
            pending = []
            add()
            guard !pending.isEmpty else { return }
            menu.addItem(.separator())
            for entry in pending { menu.addItem(entry) }
        }

        let header = MenuHeaderView(title: model.headerTitle, detail: model.headerDetail, dot: model.headerDot)
        let head = item(model.statusLine, enabled: false)
        head.view = header
        head.setAccessibilityLabel(header.label)
        menu.addItem(head)

        group {
            if model.firstActionEnabled {
                switch model.state {
                case .paused: action(model.firstActionTitle, symbol: "play", run: actions.resume)
                case .failed: action(model.firstActionTitle, run: actions.retryDownload)
                default: action(model.firstActionTitle, symbol: "pause", run: actions.pause)
                }
            }
            if let title = model.resumeAnywayTitle { action(title, run: actions.resumeAnyway) }
        }

        group {
            if let permission = model.permissionLine { line(permission) }
            if !model.doneByKind.values.allSatisfy({ $0 == 0 }) {
                for (kind, name) in kinds {
                    if model.kindsOn[kind] == false {
                        line("\(name): Off")
                    } else {
                        line("\(name): \(MenuModel.grouped(model.doneByKind[kind, default: 0]))")
                    }
                }
            }
        }

        group {
            action("Open Sesame", symbol: "magnifyingglass", run: actions.open)
            action("Settings…", key: ",", symbol: "gearshape", run: actions.settings)
        }
        group {
            action("Quit Sesame", key: "q", symbol: "power", run: actions.quit)
        }
        return menu
    }

    /// An item whose VoiceOver description is its text.
    private static func item(_ text: String, enabled: Bool, symbol: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        entry.isEnabled = enabled
        entry.setAccessibilityLabel(text)
        if let symbol, let image = Design.symbol(symbol, pointSize: 16) {
            image.isTemplate = true
            entry.image = image
        }
        return entry
    }
}
