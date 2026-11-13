import AppKit

enum WindowPolicy {
    /// The activation policy once the panel is hidden: the app stays regular while a Settings or a Setup window is
    /// up, and goes back to accessory (no Dock icon) otherwise.
    static func policyAfterPanelHides(settingsVisible: Bool, setupVisible: Bool) -> NSApplication.ActivationPolicy {
        settingsVisible || setupVisible ? .regular : .accessory
    }
}
