import AppKit

/// Removes the app's defaults domain once the folder picker closes, so no defaults file stays in
/// the person's Library. The standard open panel writes one on its own.
enum FolderPickerDefaults {
    /// Runs one program and returns its exit status.
    typealias Runner = @Sendable (_ executable: String, _ arguments: [String]) throws -> Int32

    static var appBundleID: String? { Bundle.main.bundleIdentifier }

    /// Runs the real `defaults`, once, through `run` on a background queue and returns at once.
    /// Does nothing for a missing or blank id. A failure is ignored.
    static func cleanup(bundleID: String?, run: @escaping Runner) {
        guard let id = bundleID, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = try? run("/usr/bin/defaults", ["delete", id])
        }
    }

    static let systemRunner: Runner = { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// The standard open panel, set to choose folders.
@MainActor
enum FolderPicker {
    /// Shows the panel and returns the folders the person chose (none when they cancel).
    static func chooseFolders() -> [URL] {
        pick {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.prompt = "Add"
            panel.message = "Choose the folders Sesame should read."
            return panel.runModal() == .OK ? panel.urls : []
        }
    }

    /// Runs `present` (the modal panel), then cleans up the defaults domain, and returns what
    /// `present` returned.
    static func pick(
        present: () -> [URL],
        bundleID: String? = FolderPickerDefaults.appBundleID,
        run: @escaping FolderPickerDefaults.Runner = FolderPickerDefaults.systemRunner
    ) -> [URL] {
        let urls = present()
        FolderPickerDefaults.cleanup(bundleID: bundleID, run: run)
        return urls
    }
}
