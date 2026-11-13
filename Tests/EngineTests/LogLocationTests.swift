import Foundation
import Testing
import SesameEngine

// Spec line 26, design line 24, plan-2-tasks line 26 and feature map S8.13 put the three logs under `Sesame/logs/`. Not pinned:
// the file name behind `LogFile.encode` (any third `.log`), and the mode of `logs/`. The loose entries allowed beside `logs/`
// are the ones S8.13's layout check lists.

/// The URL of a log: `logs/<name>` under the Sesame folder when that file exists, else the old loose place. Readers of a log
/// that a test did not write itself use this, so they work before and after the logs moved under `logs/`.
func sesameLogURL(_ folder: URL, _ name: String) -> URL {
    let under = folder.appendingPathComponent("logs", isDirectory: true).appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: under.path) { return under }
    return folder.appendingPathComponent(name)
}

private func llWriteAll() {
    try? Log.write(.loginStatus(.enabled), to: .app)
    try? Log.write(.unit(inputs: 4), to: .index)
    try? Log.write(.unit(inputs: 7), to: .encode)
}

/// The names in `logs/` under the Sesame folder; empty when there is no such folder.
private func llLogsFolderNames(_ folder: URL) -> [String] {
    (try? names(in: folder.appendingPathComponent("logs", isDirectory: true))) ?? []
}

private let llLooseAllowed: Set<String> = ["logs", "models", "index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "settings.json"]

@Suite("LogLocationTests", .serialized)
struct LogLocationTests {

    @Test func theAppLogIsWrittenUnderTheLogsFolder() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            try? Log.write(.loginStatus(.enabled), to: .app)
            let path = t.folder.appendingPathComponent("logs/app.log")
            let text = try? String(contentsOf: path, encoding: .utf8)
            #expect(text == "login status=enabled\n", "Sesame/logs/app.log holds \(String(describing: text)); the Sesame folder holds \((try? names(in: t.folder)) ?? [])")
        }
    }

    @Test func theIndexLogIsWrittenUnderTheLogsFolder() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            try? Log.write(.unit(inputs: 4), to: .index)
            let path = t.folder.appendingPathComponent("logs/index.log")
            let text = try? String(contentsOf: path, encoding: .utf8)
            #expect(text == "unit n=4\n", "Sesame/logs/index.log holds \(String(describing: text)); the Sesame folder holds \((try? names(in: t.folder)) ?? [])")
        }
    }

    @Test func theThirdLogIsWrittenUnderTheLogsFolderToo() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            try? Log.write(.unit(inputs: 7), to: .encode)
            let held = llLogsFolderNames(t.folder).filter { $0.hasSuffix(".log") }
            #expect(held.count == 1, "Sesame/logs/ holds \(held) after one encode write; the Sesame folder holds \((try? names(in: t.folder)) ?? [])")
            if let name = held.first {
                let text = try? String(contentsOf: t.folder.appendingPathComponent("logs").appendingPathComponent(name), encoding: .utf8)
                #expect(text == "unit n=7\n", "Sesame/logs/\(name) holds \(String(describing: text))")
            }
        }
    }

    @Test func allThreeLogsTogetherAreExactlyTheFilesUnderLogs() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            llWriteAll()
            let held = llLogsFolderNames(t.folder)
            #expect(held.count == 3 && held.contains("app.log") && held.contains("index.log") && held.allSatisfy { $0.hasSuffix(".log") },
                    "Sesame/logs/ holds \(held), expected three .log files including app.log and index.log")
        }
    }

    @Test func nothingLooseLandsInTheSesameFolderBesideTheLogsFolder() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            llWriteAll()
            let loose = try names(in: t.folder)
            let looseLogs = loose.filter { $0.hasSuffix(".log") }
            #expect(looseLogs.isEmpty, "log files sit loose in the Sesame folder: \(looseLogs)")
            let stray = loose.filter { !llLooseAllowed.contains($0) }
            #expect(stray.isEmpty, "the Sesame folder holds entries outside models/, index.sqlite*, settings.json and logs/: \(stray)")
        }
    }
}
