import Foundation
import ServiceManagement
import SesameEngine

/// The login item as macOS holds it. The real one wraps `SMAppService.mainApp`; tests give a fake.
protocol LoginService {
    var status: LoginStatus { get }
    func register() throws
    func unregister() throws
}

/// `SMAppService.mainApp`. Never used by a test.
struct MainAppLoginService: LoginService {
    var status: LoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Launch at login. macOS holds the state; Sesame stores only `loginDefaultApplied` (design section 1), so the
/// switch reads the live status each time and the first run is the only time the app registers by itself.
@MainActor
final class LoginItem {
    nonisolated static let note = "The shortcut works only while Sesame is running."
    nonisolated static let failureMessage = "Could not change Launch at login."

    private let service: any LoginService

    /// Set when a change failed; the switch itself stays at the live status.
    private(set) var message: String?

    init(service: any LoginService) {
        self.service = service
    }

    /// On for `enabled` and `requires_approval` (the person has only to approve it); off for the other two.
    var isOn: Bool {
        switch service.status {
        case .enabled, .requiresApproval: true
        case .notRegistered, .notFound: false
        }
    }

    /// The first run registers once and remembers it; later runs do nothing, so a person who turned it off stays off.
    func applyFirstRunDefault() {
        guard var settings = try? SettingsFile().read(), !settings.loginDefaultApplied else { return }
        change(register: true)
        settings.loginDefaultApplied = true
        try? SesameFolder.create()
        try? SettingsFile().write(settings)
    }

    func clearMessage() {
        message = nil
    }

    func set(on: Bool) {
        change(register: on)
    }

    private func change(register: Bool) {
        do {
            if register { try service.register() } else { try service.unregister() }
            message = nil
        } catch {
            message = Self.failureMessage
        }
        try? Log.write(.loginStatus(service.status), to: .app)
    }
}
