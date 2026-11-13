import Foundation

/// Which files of a repo git says may be read: tracked, plus untracked and not ignored. Git is the only judge of
/// `.gitignore`; when it cannot answer there is no answer, and the caller skips the repo.
public enum GitFiles {
    /// The git that ships with macOS.
    public static let systemGit = "/usr/bin/git"

    private final class Output: @unchecked Sendable {
        var data = Data()
    }

    /// The repo-relative paths `git ls-files -z --cached --others --exclude-standard` prints for the repo folder, or nil
    /// when git cannot answer (it is missing, exits non-zero, does not finish within `timeout` seconds, or the folder is
    /// not a repo). The repo's own config cannot run code (`core.fsmonitor` and `core.hooksPath` are forced off), no
    /// system or user config is read, and the environment is built from nothing, so no `GIT_*` setting of ours reaches it.
    public static func list(repo: String, git: String, timeout: TimeInterval = 30) -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = [
            "--no-pager", "-C", repo,
            "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.excludesFile=/dev/null",
            "ls-files", "-z", "--cached", "--others", "--exclude-standard",
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/var/empty",
            "XDG_CONFIG_HOME": "/var/empty",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_NO_LAZY_FETCH": "1",
            // An empty or broken `.git` must not send git up to a repo that holds this folder.
            "GIT_CEILING_DIRECTORIES": (repo as NSString).deletingLastPathComponent,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Read on another thread so a git that never finishes (a `.gitignore` that is a FIFO) cannot hold us.
        let collected = Output()
        let finished = DispatchSemaphore(value: 0)
        let reader = output.fileHandleForReading
        DispatchQueue.global().async {
            collected.data = reader.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        var names = Set<String>()
        for piece in collected.data.split(separator: 0) { names.insert(String(decoding: piece, as: UTF8.self)) }
        return names
    }
}
