import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let cfStubScript = #"""
#!/bin/sh
dir=$(dirname "$0")
mode="$1"
shift
while IFS= read -r line; do
  printf '%s\t%s\n' "$$" "$line" >> "$dir/$mode.stdin"
done
"""#

private struct CFFolder {
    var path: String
    var code: Bool
    var reading: Bool = true
}

@MainActor
private final class CFEnv {
    let dir: URL
    let helper: URL
    let textModel: URL
    let mmModel: URL
    let home: URL
    var settings: URL {
        home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true).appendingPathComponent("settings.json")
    }

    init(home: URL) throws {
        let fm = FileManager.default
        self.home = home
        dir = fm.temporaryDirectory.appendingPathComponent("sesame-codefeed-stub-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        helper = dir.appendingPathComponent("stub-helper")
        try cfStubScript.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        textModel = dir.appendingPathComponent("text-model.gguf")
        mmModel = dir.appendingPathComponent("mm-model.gguf")
        fm.createFile(atPath: textModel.path, contents: Data("t".utf8))
        fm.createFile(atPath: mmModel.path, contents: Data("m".utf8))
    }

    func makeClient() -> HelperClient {
        HelperClient(helper: helper, textModel: textModel, mmModel: mmModel)
    }

    func foldersLines() -> [String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("index.stdin"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { entry in
            let parts = entry.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 && parts[1].contains("\"folders\"") ? String(parts[1]) : nil
        }
    }

    func makeFolder(_ name: String) throws -> String {
        let url = home.resolvingSymlinksInPath().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func writeSettings(codeSearchOn: Bool, _ folders: [CFFolder]) throws {
        let entries = folders.map { entry -> [String: Any] in
            ["path": entry.path, "code": entry.code, "reading": entry.reading]
        }
        let object: [String: Any] = [
            "version": 3, "startPressed": true, "indexDeleted": false, "folders": entries,
            "codeSearchOn": codeSearchOn,
            "kindsOn": ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true],
            "hotkey": "ctrl+opt+space",
            "openWith": ["pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"],
            "speeds": [String: Double](), "loginDefaultApplied": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: settings, options: .atomic)
    }

    func cleanup() {
        if let text = try? String(contentsOf: dir.appendingPathComponent("index.stdin"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let pid = Int(line.split(separator: "\t").first ?? "") { _ = Darwin.kill(pid_t(pid), SIGKILL) }
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }
}

@MainActor
private func cfRun(_ body: @MainActor (CFEnv) async throws -> Void) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("sesame-codefeed-home-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    let env = try CFEnv(home: home)
    defer {
        env.cleanup()
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: home)
    }
    _ = try SesameFolder.create()
    guard fm.fileExists(atPath: env.settings.deletingLastPathComponent().path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before touching anything")
        return
    }
    try await body(env)
}

@MainActor
private func cfEventually(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private struct CFEntry: Equatable {
    var path: String
    var code: Bool
}

private func cfEntries(_ line: String) -> [CFEntry]? {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          obj["cmd"] as? String == "folders", Set(obj.keys) == ["cmd", "folders"],
          let list = obj["folders"] as? [[String: Any]] else { return nil }
    var result: [CFEntry] = []
    for entry in list {
        guard Set(entry.keys) == ["path", "code"], let path = entry["path"] as? String, let code = entry["code"] as? Bool else { return nil }
        result.append(CFEntry(path: path, code: code))
    }
    return result
}

@MainActor
private func cfSend(_ client: HelperClient, _ env: CFEnv, expecting count: Int) async -> [CFEntry]? {
    client.sendFolders()
    let arrived = await cfEventually { env.foldersLines().count >= count }
    #expect(arrived, "folders line \(count) never reached the index stub: \(env.foldersLines())")
    guard env.foldersLines().count >= count else { return nil }
    let line = env.foldersLines()[count - 1]
    let entries = cfEntries(line)
    #expect(entries != nil, "not a folders line of {path, code} entries: \(line)")
    return entries
}

private func cfAllFalse(_ paths: [String]) -> [CFEntry] {
    paths.map { CFEntry(path: $0, code: false) }
}

extension ModelDownloadTests {
    @Suite("HelperClientCodeFeedTests", .serialized)
    struct HelperClientCodeFeedTests {

        @MainActor
        @Test func theLineCarriesCodeFalseForEveryFolderWhateverTheStoredTicksAndTheOldSwitch() async throws {
            try await cfRun { env in
                let repo = try env.makeFolder("Developer/api-client")
                let other = try env.makeFolder("Developer/legacy-sync")
                let plain = try env.makeFolder("Documents")
                let later = try env.makeFolder("Added Later")
                try env.writeSettings(codeSearchOn: true, [
                    CFFolder(path: repo, code: true), CFFolder(path: other, code: false), CFFolder(path: plain, code: false),
                    CFFolder(path: later, code: true, reading: false),
                ])
                let sent = await cfSend(env.makeClient(), env, expecting: 1)
                #expect(sent == cfAllFalse([repo, other, plain]),
                        "switch on, a stored tick true: expected the three reading folders in order, every code false; got \(String(describing: sent))")
            }
        }

        @MainActor
        @Test func withTheOldSwitchOffTheLineIsTheSameAndSendingChangesNothingOnDisk() async throws {
            try await cfRun { env in
                let repo = try env.makeFolder("Developer/api-client")
                let second = try env.makeFolder("Developer/legacy-sync")
                let plain = try env.makeFolder("Documents")
                try env.writeSettings(codeSearchOn: false, [
                    CFFolder(path: repo, code: true), CFFolder(path: second, code: true), CFFolder(path: plain, code: false),
                ])
                let before = try Data(contentsOf: env.settings)
                let sent = await cfSend(env.makeClient(), env, expecting: 1)
                #expect(sent == cfAllFalse([repo, second, plain]), "switch off: every code false; got \(String(describing: sent))")

                #expect(try Data(contentsOf: env.settings) == before, "sending the line changed settings.json")
                let stored = try SettingsFile().read()
                #expect(!stored.codeSearchOn)
                #expect(stored.folders.first { $0.path == repo }?.code == true, "the stored tick of the repo was changed")
                #expect(stored.folders.first { $0.path == second }?.code == true, "the stored tick of the second repo was changed")
                #expect(stored.folders.first { $0.path == plain }?.code == false)
            }
        }

        @MainActor
        @Test func everySendIsTheWholeCurrentListWithCodeFalseWhateverTheSwitchDoes() async throws {
            try await cfRun { env in
                let repo = try env.makeFolder("Developer/api-client")
                let other = try env.makeFolder("Developer/legacy-sync")
                let folders = [CFFolder(path: repo, code: true), CFFolder(path: other, code: false)]
                let client = env.makeClient()

                try env.writeSettings(codeSearchOn: true, folders)
                let first = await cfSend(client, env, expecting: 1)
                #expect(first == cfAllFalse([repo, other]), "switch on: \(String(describing: first))")

                try env.writeSettings(codeSearchOn: false, folders)
                let second = await cfSend(client, env, expecting: 2)
                #expect(second == cfAllFalse([repo, other]), "switch turned off: \(String(describing: second))")

                try env.writeSettings(codeSearchOn: true, [CFFolder(path: other, code: true)])
                let third = await cfSend(client, env, expecting: 3)
                #expect(third == cfAllFalse([other]), "switch on again, one folder left: \(String(describing: third))")

                let stored = try SettingsFile().read()
                #expect(stored.folders.first { $0.path == other }?.code == true)
            }
        }

        @MainActor
        @Test func anOverlappingPairIsSentInOrderWithBothFlagsFalse() async throws {
            try await cfRun { env in
                let outerA = try env.makeFolder("ov-a/outer")
                let innerA = try env.makeFolder("ov-a/outer/inner")
                let outerB = try env.makeFolder("ov-b/outer")
                let innerB = try env.makeFolder("ov-b/outer/inner")
                let outerD = try env.makeFolder("ov-d/outer")
                let innerD = try env.makeFolder("ov-d/outer/inner")
                let folders = [
                    CFFolder(path: outerA, code: false), CFFolder(path: innerA, code: true),
                    CFFolder(path: outerB, code: true), CFFolder(path: innerB, code: false),
                    CFFolder(path: outerD, code: true), CFFolder(path: innerD, code: true),
                ]
                let client = env.makeClient()
                try env.writeSettings(codeSearchOn: true, folders)
                let on = await cfSend(client, env, expecting: 1)
                #expect(on == cfAllFalse([outerA, innerA, outerB, innerB, outerD, innerD]),
                        "switch on: all six false, in the stored order; got \(String(describing: on))")

                try env.writeSettings(codeSearchOn: false, folders)
                let off = await cfSend(client, env, expecting: 2)
                #expect(off == cfAllFalse([outerA, innerA, outerB, innerB, outerD, innerD]),
                        "switch off: all six false; got \(String(describing: off))")
            }
        }

        @MainActor
        @Test func aFolderThatIsNotReadingIsNotSentWhateverItsTickAndTheSwitch() async throws {
            try await cfRun { env in
                let reading = try env.makeFolder("Developer/api-client")
                let waiting = try env.makeFolder("Developer/waiting-repo")
                let waitingNoTick = try env.makeFolder("Documents")
                let folders = [
                    CFFolder(path: reading, code: true),
                    CFFolder(path: waiting, code: true, reading: false),
                    CFFolder(path: waitingNoTick, code: false, reading: false),
                ]
                let client = env.makeClient()
                try env.writeSettings(codeSearchOn: true, folders)
                let on = await cfSend(client, env, expecting: 1)
                #expect(on == cfAllFalse([reading]), "switch on: only the reading folder is sent, code false; got \(String(describing: on))")

                try env.writeSettings(codeSearchOn: false, folders)
                let off = await cfSend(client, env, expecting: 2)
                #expect(off == cfAllFalse([reading]), "switch off: only the reading folder is sent, code false; got \(String(describing: off))")
            }
        }
    }
}

