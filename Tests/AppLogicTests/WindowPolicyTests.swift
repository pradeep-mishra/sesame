import AppKit
import Foundation
import Testing
@testable import Sesame

// plan-2 fix round B, tester step, item B10 (S1.29 noted): `Panel.hide` must not drop the app to the accessory activation
// policy while a Setup window is visible (it counted only Settings). Written from the fix-round document ("count Setup
// and Settings windows. Test through the existing PanelRig pattern or the pure policy function"). No product source was
// read. A real window cannot be made visible here (no window is ever ordered front, and no app is launched), so the test
// goes through a pure function, and the table is written by hand from the sentence above.
//
// API SHAPE B10 pins (new; the fixer's `Panel.hide` reads the visible Setup and Settings windows and passes what it saw):
//     enum WindowPolicy {                                   // in the `Sesame` target
//         static func policyAfterPanelHides(settingsVisible: Bool, setupVisible: Bool) -> NSApplication.ActivationPolicy
//     }
//   - a Settings window or a Setup window (or both) visible: `.regular` (the app keeps its place while a window of its own
//     is up);
//   - neither visible: `.accessory` (the menu bar app goes back to having no Dock icon).
// `Panel.hide` must call it with the real visibility of both windows; that call is not reachable offscreen and is read by
// the reviewer. WHAT THE RED MEANS: the name does not exist, so the test target does not compile until it does.

@Suite("WindowPolicyTests")
struct WindowPolicyTests {

    // (settings visible, setup visible, policy)
    private static let table: [(Bool, Bool, NSApplication.ActivationPolicy)] = [
        (false, false, .accessory),
        (true, false, .regular),
        (false, true, .regular),
        (true, true, .regular),
    ]

    @MainActor
    @Test func theAppStaysRegularWhileSettingsOrSetupIsUpAndGoesBackToAccessoryOtherwise() {
        for (settings, setup, expected) in Self.table {
            let policy = WindowPolicy.policyAfterPanelHides(settingsVisible: settings, setupVisible: setup)
            #expect(policy == expected, "settings visible \(settings), setup visible \(setup): got \(policy.rawValue), expected \(expected.rawValue)")
        }
    }
}
