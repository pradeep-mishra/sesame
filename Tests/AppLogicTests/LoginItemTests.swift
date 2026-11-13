import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t23, tester step. Written from the t23 entry, design sections 1 and 6, the plan-2 Conventions (fixed names:
// `LoginItem`, `LoginService`, `loginDefaultApplied`, the typed line `login status=<enabled|requires_approval|
// not_registered|not_found>` in `app.log`) and the plan-1 tests' public names only; no product source read.
//
// Launch at login is held by macOS (`SMAppService.mainApp`); Sesame stores only `loginDefaultApplied` in `settings.json`
// (design section 1). Every test here gives `LoginItem` a fake service, so the real `SMAppService` is never called.
// Everything runs in a throwaway HOME. Expected values are written here by hand from the entry; none comes from the code.
//
// SUITE PLACEMENT. Nested inside `ModelDownloadTests` like the other HOME-setting suites (HOME is process-wide);
// `swift test --filter ModelDownloadTests` also runs this suite.
//
// API SHAPES these tests pin (the entry names `LoginItem(service:)`, `LoginService`, the four statuses, `register()`,
// `unregister()`, `isOn`, `set(on:)`, `message` and `LoginItem.note`, and fixes no signatures; the first-run call and the
// status type are this file's picks; if one is wrong, ask for a test change rather than guessing):
//   1. `enum LoginStatus: String` in the `Sesame` target with the cases `.enabled`, `.requiresApproval`, `.notRegistered`
//      and `.notFound`; the raw values are the four words the log line carries ("enabled", "requires_approval",
//      "not_registered", "not_found").
//   2. `protocol LoginService` with `var status: LoginStatus { get }`, `func register() throws`, `func unregister() throws`.
//   3. `final class LoginItem`, may be `@MainActor` (every test here is):
//        `init(service: any LoginService)`
//        `func applyFirstRunDefault()`  non-throwing; "the first run": when `loginDefaultApplied` is false in
//                                       `settings.json` (or the file is absent) it registers once and stores
//                                       `loginDefaultApplied` true through `SettingsFile`; when it is true it does nothing.
//        `var isOn: Bool { get }`       reads `service.status` on every call.
//        `func set(on: Bool)`           non-throwing; calls `register()` or `unregister()`; a throw is caught.
//        `var message: String?`         nil until a change fails; then "Could not change Launch at login.".
//        `static let note: String`      "The shortcut works only while Sesame is running."
//   4. The typed line goes to `app.log` through `SesameFolder.append`. Design section 1 writes the name `logs/app.log`,
//      while `SesameFolder` refuses any name with a slash, so the test reads `Sesame/app.log` and, if that is absent,
//      `Sesame/logs/app.log`. A line is exactly `login status=<status>`; the status is the live one read from the service
//      AFTER the register or unregister call (each fake below changes its status the way macOS does).

private let liSettingsText = """
{
  "version": 3,
  "startPressed": true,
  "indexDeleted": false,
  "folders": [
    {"path": "/Users/test/Pictures", "code": false, "reading": true},
    {"path": "/Users/test/Developer/api-client", "code": true, "reading": false}
  ],
  "codeSearchOn": true,
  "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
  "hotkey": "cmd+opt+k",
  "openWith": {"pdf": "Skim", "media": "IINA", "code": "Cursor"},
  "speeds": {"photo": 0.5},
  "loginDefaultApplied": APPLIED
}
"""

/// A stand-in for `SMAppService.mainApp`. `register()` and `unregister()` leave `status` as the test scripted, the way
/// macOS does; a scripted throw changes nothing. Any thread may use it.
private final class LIFakeService: LoginService, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginStatus
    private var registered = 0
    private var unregistered = 0
    var statusAfterRegister: LoginStatus = .enabled
    var statusAfterUnregister: LoginStatus = .notRegistered
    var registerThrows = false
    var unregisterThrows = false

    struct Refused: Error {}

    init(_ status: LoginStatus) { current = status }

    var status: LoginStatus {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    var registerCount: Int { lock.lock(); defer { lock.unlock() }; return registered }
    var unregisterCount: Int { lock.lock(); defer { lock.unlock() }; return unregistered }

    func register() throws {
        lock.lock(); registered += 1; lock.unlock()
        if registerThrows { throw Refused() }
        status = statusAfterRegister
    }

    func unregister() throws {
        lock.lock(); unregistered += 1; lock.unlock()
        if unregisterThrows { throw Refused() }
        status = statusAfterUnregister
    }
}

private func liFolder(_ home: URL) -> URL {
    home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
}

private func liWriteSettings(_ home: URL, applied: Bool) throws {
    let text = liSettingsText.replacingOccurrences(of: "APPLIED", with: applied ? "true" : "false")
    try text.write(to: liFolder(home).appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
}

private func liSettingsOnDisk(_ home: URL) throws -> NSDictionary {
    let data = try Data(contentsOf: liFolder(home).appendingPathComponent("settings.json"))
    return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private func liWithoutLogin(_ dictionary: NSDictionary) -> NSDictionary {
    let copy = NSMutableDictionary(dictionary: dictionary)
    copy.removeObject(forKey: "loginDefaultApplied")
    return copy
}

/// Every line of `app.log` that carries a login status, in order. An absent log is an empty list.
private func liLoginLines(_ home: URL) -> [String] {
    let candidates = [liFolder(home).appendingPathComponent("app.log"),
                      liFolder(home).appendingPathComponent("logs/app.log")]
    guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { $0.contains("login status=") }
}

private let liMessage = "Could not change Launch at login."

extension ModelDownloadTests {
    @Suite("LoginItemTests", .serialized)
    struct LoginItemTests {

        // MARK: the note

        @Test func theNoteIsExactlyTheSentenceTheEntryGives() {
            #expect(LoginItem.note == "The shortcut works only while Sesame is running.")
        }

        // MARK: the status words

        @Test func theFourStatusesCarryTheWordsTheLogLineUses() {
            #expect(LoginStatus.enabled.rawValue == "enabled")
            #expect(LoginStatus.requiresApproval.rawValue == "requires_approval")
            #expect(LoginStatus.notRegistered.rawValue == "not_registered")
            #expect(LoginStatus.notFound.rawValue == "not_found")
        }

        // MARK: the first run registers and remembers it

        @MainActor
        @Test func theFirstRunRegistersOnceAndStoresLoginDefaultAppliedAndNothingElse() async throws {
            try await spWithHome { home in
                try liWriteSettings(home, applied: false)
                let before = try liSettingsOnDisk(home)
                #expect((before["loginDefaultApplied"] as? NSNumber)?.boolValue == false, "the starting file should say false")
                let service = LIFakeService(.notRegistered)
                let item = LoginItem(service: service)

                item.applyFirstRunDefault()

                #expect(service.registerCount == 1, "register() was called \(service.registerCount) times on the first run")
                #expect(service.unregisterCount == 0)
                let after = try liSettingsOnDisk(home)
                #expect((after["loginDefaultApplied"] as? NSNumber)?.boolValue == true, "loginDefaultApplied is \(String(describing: after["loginDefaultApplied"]))")
                #expect(liWithoutLogin(after) == liWithoutLogin(before),
                        "a key other than loginDefaultApplied changed: before \(liWithoutLogin(before)), after \(liWithoutLogin(after))")
                #expect(item.message == nil, "a first run that worked left the message \(String(describing: item.message))")
            }
        }

        @MainActor
        @Test func aFreshInstallWithNoSettingsFileAlsoRegistersOnceAndWritesTheFlag() async throws {
            try await spWithHome { home in
                let file = liFolder(home).appendingPathComponent("settings.json")
                #expect(!FileManager.default.fileExists(atPath: file.path), "the test should start with no settings file")
                let service = LIFakeService(.notRegistered)
                let item = LoginItem(service: service)

                item.applyFirstRunDefault()

                #expect(service.registerCount == 1, "register() was called \(service.registerCount) times")
                let after = try liSettingsOnDisk(home)
                #expect((after["loginDefaultApplied"] as? NSNumber)?.boolValue == true)
            }
        }

        @MainActor
        @Test func aSecondCallInTheSameLaunchAndAnotherLaunchNeverRegisterAgain() async throws {
            try await spWithHome { home in
                try liWriteSettings(home, applied: false)
                let service = LIFakeService(.notRegistered)
                let first = LoginItem(service: service)
                first.applyFirstRunDefault()
                #expect(service.registerCount == 1)

                first.applyFirstRunDefault()
                #expect(service.registerCount == 1, "the same launch registered again: \(service.registerCount) calls")

                // a later launch: a new LoginItem over the same HOME, after the person turned the item off in System Settings
                service.status = .notRegistered
                let later = LoginItem(service: service)
                later.applyFirstRunDefault()
                #expect(service.registerCount == 1, "a later launch registered again: \(service.registerCount) calls")
                #expect(service.unregisterCount == 0)
                #expect((try liSettingsOnDisk(home)["loginDefaultApplied"] as? NSNumber)?.boolValue == true)
            }
        }

        @MainActor
        @Test func aLaterRunNeverRegistersWhateverTheLiveStatusIs() async throws {
            for status in [LoginStatus.notRegistered, .notFound, .requiresApproval, .enabled] {
                try await spWithHome { home in
                    try liWriteSettings(home, applied: true)
                    let before = try liSettingsOnDisk(home)
                    let service = LIFakeService(status)
                    let item = LoginItem(service: service)

                    item.applyFirstRunDefault()

                    #expect(service.registerCount == 0, "[\(status.rawValue)] register() was called with loginDefaultApplied already true")
                    #expect(service.unregisterCount == 0)
                    #expect(try liSettingsOnDisk(home) == before, "[\(status.rawValue)] settings.json changed on a later run")
                    #expect(item.isOn == (status == .requiresApproval || status == .enabled), "[\(status.rawValue)] isOn is \(item.isOn)")
                }
            }
        }

        // MARK: isOn reads the live status, never a copy

        @MainActor
        @Test func isOnIsTrueForEnabledAndRequiresApprovalAndFalseForTheOtherTwo() async throws {
            try await spWithHome { _ in
                let table: [(LoginStatus, Bool)] = [
                    (.enabled, true), (.requiresApproval, true), (.notRegistered, false), (.notFound, false),
                ]
                for (status, expected) in table {
                    let item = LoginItem(service: LIFakeService(status))
                    #expect(item.isOn == expected, "status \(status.rawValue): isOn is \(item.isOn), wanted \(expected)")
                }
            }
        }

        @MainActor
        @Test func isOnFollowsTheServiceWhenTheStatusChangesBehindTheItemsBack() async throws {
            try await spWithHome { _ in
                let service = LIFakeService(.enabled)
                let item = LoginItem(service: service)
                #expect(item.isOn == true)

                // the person flips the switch in System Settings: Sesame hears nothing, the next read must still be right
                service.status = .notRegistered
                #expect(item.isOn == false, "isOn kept an old answer after the status became not_registered")
                service.status = .requiresApproval
                #expect(item.isOn == true, "isOn kept an old answer after the status became requires_approval")
                service.status = .notFound
                #expect(item.isOn == false, "isOn kept an old answer after the status became not_found")
                service.status = .enabled
                #expect(item.isOn == true, "isOn kept an old answer after the status became enabled")
                #expect(service.registerCount == 0 && service.unregisterCount == 0, "reading isOn changed the registration")
            }
        }

        // MARK: toggling

        @MainActor
        @Test func setOffUnregistersAndSetOnRegistersAndIsOnFollows() async throws {
            try await spWithHome { home in
                try liWriteSettings(home, applied: true)
                let service = LIFakeService(.enabled)
                let item = LoginItem(service: service)

                item.set(on: false)
                #expect(service.unregisterCount == 1, "set(on: false) called unregister() \(service.unregisterCount) times")
                #expect(service.registerCount == 0)
                #expect(item.isOn == false)

                item.set(on: true)
                #expect(service.registerCount == 1, "set(on: true) called register() \(service.registerCount) times")
                #expect(service.unregisterCount == 1)
                #expect(item.isOn == true)
                #expect(item.message == nil, "message after two changes that worked: \(String(describing: item.message))")
            }
        }

        // MARK: a throw leaves the switch at the live status and gives the message

        @MainActor
        @Test func aRegisterThatThrowsLeavesTheSwitchOffAndSetsTheMessage() async throws {
            try await spWithHome { home in
                try liWriteSettings(home, applied: true)
                let service = LIFakeService(.notRegistered)
                service.registerThrows = true
                let item = LoginItem(service: service)
                #expect(item.message == nil, "the message should be empty before any change")

                item.set(on: true)

                #expect(service.registerCount == 1)
                #expect(item.isOn == false, "isOn is \(item.isOn) after register() threw; the live status is not_registered")
                #expect(item.message == liMessage, "message is \(String(describing: item.message))")
            }
        }

        @MainActor
        @Test func anUnregisterThatThrowsLeavesTheSwitchOnAndSetsTheMessage() async throws {
            try await spWithHome { home in
                try liWriteSettings(home, applied: true)
                let service = LIFakeService(.enabled)
                service.unregisterThrows = true
                let item = LoginItem(service: service)

                item.set(on: false)

                #expect(service.unregisterCount == 1)
                #expect(item.isOn == true, "isOn is \(item.isOn) after unregister() threw; the live status is enabled")
                #expect(item.message == liMessage, "message is \(String(describing: item.message))")
            }
        }

        @MainActor
        @Test func aThrowOnTheFirstRunLeavesTheSwitchAtTheLiveStatusAndSetsTheMessage() async throws {
            try await spWithHome { home in
                try liWriteSettings(home, applied: false)
                let service = LIFakeService(.notRegistered)
                service.registerThrows = true
                let item = LoginItem(service: service)

                item.applyFirstRunDefault()

                #expect(service.registerCount >= 1)
                #expect(item.isOn == false, "isOn is \(item.isOn) after the first register() threw")
                #expect(item.message == liMessage, "message is \(String(describing: item.message))")
            }
        }

        // MARK: the typed log line

        @MainActor
        @Test func theFirstRegisterAndEachToggleAppendOneLoginStatusLineWithTheLiveStatus() async throws {
            try await spWithHome { home in
                try liWriteSettings(home, applied: false)
                let service = LIFakeService(.notRegistered)
                let item = LoginItem(service: service)
                #expect(liLoginLines(home).isEmpty, "a login line exists before anything happened")

                item.applyFirstRunDefault()
                #expect(liLoginLines(home) == ["login status=enabled"], "after the first register: \(liLoginLines(home))")

                item.set(on: false)
                #expect(liLoginLines(home) == ["login status=enabled", "login status=not_registered"],
                        "after turning it off: \(liLoginLines(home))")

                item.set(on: true)
                #expect(liLoginLines(home) == ["login status=enabled", "login status=not_registered", "login status=enabled"],
                        "after turning it on again: \(liLoginLines(home))")
            }
        }

        @MainActor
        @Test func theLineCarriesWhateverStatusTheServiceReportsAfterTheCall() async throws {
            let table: [(LoginStatus, String)] = [
                (.enabled, "login status=enabled"),
                (.requiresApproval, "login status=requires_approval"),
                (.notRegistered, "login status=not_registered"),
                (.notFound, "login status=not_found"),
            ]
            for (after, line) in table {
                try await spWithHome { home in
                    try liWriteSettings(home, applied: true)
                    let service = LIFakeService(.notRegistered)
                    service.statusAfterRegister = after
                    let item = LoginItem(service: service)

                    item.set(on: true)

                    #expect(liLoginLines(home) == [line], "register() left \(after.rawValue): the log holds \(liLoginLines(home))")
                }
            }
        }

        @MainActor
        @Test func theLineHoldsNothingButTheStatusNoPathNoText() async throws {
            try await spWithHome { home in
                try liWriteSettings(home, applied: false)
                let service = LIFakeService(.notRegistered)
                service.statusAfterRegister = .requiresApproval
                let item = LoginItem(service: service)

                item.applyFirstRunDefault()
                item.set(on: false)
                item.set(on: true)

                let allowed: Set<String> = ["enabled", "requires_approval", "not_registered", "not_found"]
                let lines = liLoginLines(home)
                #expect(lines.count == 3, "expected three login lines, got \(lines)")
                for line in lines {
                    #expect(line.hasPrefix("login status="), "line \(line)")
                    let word = String(line.dropFirst("login status=".count))
                    #expect(allowed.contains(word), "the line carries \(word), which is not one of the four statuses")
                    #expect(!line.contains(home.path) && !line.contains("/"), "the line holds a path: \(line)")
                }
            }
        }
    }
}
