import Foundation
import SesameEngine

/// The setup window's four steps as a pure state machine (design section 1). It knows nothing about the model:
/// Next and Back work the same while the model downloads. Whether Start indexing is enabled is
/// `SetupModel.canStartIndexing`; the flow only says which step shows the button.
struct SetupFlow {
    enum Step: Int, CaseIterable, Sendable {
        case welcome, folders, permissions, shortcut

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .folders: "Folders"
            case .permissions: "Permissions"
            case .shortcut: "Shortcut"
            }
        }
    }

    static let steps = Step.allCases

    /// The folders macOS asks about, once each, the first time Sesame reads them.
    static let permissionFolders = [
        "Desktop",
        "Documents",
        "Downloads",
        "Removable volumes (USB drives, external disks)",
    ]

    static let neverAskedLine = "Sesame never asks for Full Disk Access, camera or microphone."

    private(set) var step = Step.welcome

    var canGoBack: Bool { step != .welcome }
    var canGoNext: Bool { step != .shortcut }
    var canFinish: Bool { step == .shortcut }
    var showsStartIndexing: Bool { step == .folders }

    mutating func next() {
        if let following = Step(rawValue: step.rawValue + 1) { step = following }
    }

    mutating func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    /// The first-window rule: setup shows until it was finished or Start was pressed or the index was deleted, whatever
    /// the model says. A model that is not whole after that is shown by the panel and the menu as Downloading.
    static func needed(settings: Settings, modelWhole: Bool) -> Bool {
        !(settings.setupFinished || settings.startPressed || settings.indexDeleted)
    }
}
