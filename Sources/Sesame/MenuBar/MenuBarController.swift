import AppKit

/// The seam over the system's status item and its button, so a test never touches `NSStatusBar.system`.
@MainActor
protocol StatusItemHost: AnyObject {
    var buttonAccessibilityLabel: String { get set }
    var buttonTitle: String { get set }
    var buttonImage: NSImage? { get set }
    var menu: NSMenu? { get set }
}

/// Keeps the status item in step with the `MenuModel`: label, title and image on every update, a new menu only when the
/// model changed.
@MainActor
final class MenuBarController {
    private let host: StatusItemHost
    private let actions: MenuActions
    private var shown: MenuModel?

    init(host: StatusItemHost, actions: MenuActions) {
        self.host = host
        self.actions = actions
    }

    func update(_ model: MenuModel) {
        host.buttonAccessibilityLabel = model.statusItemLabel
        host.buttonTitle = model.statusItemLabel
        host.buttonImage = StatusIcons.image(for: model.state)
        guard model != shown else { return }
        host.menu = MenuBuilder.build(model, actions: actions)
        shown = model
    }
}

@MainActor
final class SystemStatusItemHost: StatusItemHost {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init() {
        item.button?.imagePosition = .imageOnly
    }

    var buttonAccessibilityLabel: String {
        get { item.button?.accessibilityLabel() ?? "" }
        set { item.button?.setAccessibilityLabel(newValue) }
    }

    var buttonTitle: String {
        get { "" }
        set { _ = newValue }
    }

    var buttonImage: NSImage? {
        get { item.button?.image }
        set { item.button?.image = newValue }
    }

    var menu: NSMenu? {
        get { item.menu }
        set { item.menu = newValue }
    }
}
