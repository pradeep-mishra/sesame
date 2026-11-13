import Foundation
import Testing

private let lockedLine = "NEEDS A PERSON: the screen is locked, unlock it and keep it awake"

private let lockedReading = "<key>IOConsoleLocked</key>\n<true/>\n<key>IOConsoleUsers</key>\n<array/>\n"
private let lockedSessionReading = "<key>IOConsoleUsers</key>\n<array><dict>\n<key>CGSSessionScreenIsLocked</key>\n<true/>\n</dict></array>\n"
private let unlockedReading = "<key>IOConsoleLocked</key>\n<false/>\n<key>IOConsoleUsers</key>\n<array/>\n"
private let unlockedSessionReading = "<key>IOConsoleUsers</key>\n<array><dict>\n<key>CGSSessionScreenIsLocked</key>\n<false/>\n<key>kCGSSessionOnConsoleKey</key>\n<true/>\n</dict></array>\n"

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func status(_ ran: KC.Ran) -> Int? {
    guard let l = KC.lines(ran.output).last(where: { $0.hasPrefix("RC=") }) else { return nil }
    return Int(l.dropFirst(3))
}

private let windowHarness = #"""
sleep() { :; }
kq() {
  case "$(basename "$1")" in
    kit-ax.sh) echo "no Sesame window"; return 1 ;;
    *) return 99 ;;
  esac
}
"""#

private struct Rig {
    let base: String
    let kit: String
    let scripts: String
    let launches: String

    init() throws {
        base = try KC.tempDir("kit-lock-")
        kit = base + "/sesame-kit"
        scripts = base + "/scripts"
        launches = base + "/launches.log"
        try FileManager.default.createDirectory(atPath: kit + "/run", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: KC.scripts, toPath: scripts)
        try KC.write(launches, "")
        for name in ["kit-launch.sh", "kit-reset.sh", "kit-fixtures.sh", "kit-index.sh", "kit-ax.sh", "kit-doctor.sh", "kit-perms.sh", "kit-mirror.sh"] {
            let path = scripts + "/" + name
            try KC.write(path, "#!/bin/bash\necho \"\(name) $*\" >> \"\(launches)\"\nexit 0\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    func run(_ args: [String], reading: String) throws -> KC.Ran {
        try KC.run(scripts + "/kit-run.sh", args, env: ["KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1", "KIT_SCREEN_LOCK_READING": reading])
    }

    var launched: String { KC.read(launches) ?? "" }
}

@Suite("kit: a locked screen is a NEEDS A PERSON, not a missing window", .serialized)
struct KitScreenLockedTests {
    private func locked(_ reading: String?) throws -> Int? {
        let kit = try KC.kitRoot()
        var env: [String: String] = [:]
        if let reading { env["KIT_SCREEN_LOCK_READING"] = reading }
        let ran = try KC.bash("kit_screen_locked; echo \"RC=$?\"", kit: kit, env: env)
        return status(ran)
    }

    @Test("kit_screen_locked reads IOConsoleLocked and CGSSessionScreenIsLocked: true is status 0, false, a missing key and an empty reading are status 1")
    func helperReadings() throws {
        ok(try locked(lockedReading) == 0, "IOConsoleLocked true was not read as locked")
        ok(try locked(lockedSessionReading) == 0, "CGSSessionScreenIsLocked true was not read as locked")
        ok(try locked(unlockedReading) == 1, "IOConsoleLocked false was read as locked")
        ok(try locked(unlockedSessionReading) == 1, "CGSSessionScreenIsLocked false was read as locked")
        ok(try locked("<key>IOConsoleUsers</key>\n<array/>\n") == 1, "a reading with no lock key was read as locked")
        ok(try locked("") == 1, "an empty reading was read as locked")
    }

    @Test("wait_setup_window with a locked screen: status 3, the NEEDS A PERSON line, and no `no setup window` line")
    func waitSetupLocked() throws {
        let ran = try KC.bash(windowHarness + "\nwait_setup_window 2; echo \"RC=$?\"", kit: try KC.kitRoot(), env: ["KIT_SCREEN_LOCK_READING": lockedReading])
        ok(status(ran) == 3, "exit \(String(describing: status(ran))):\n\(ran.output)")
        ok(KC.lines(ran.output).contains(lockedLine), "the line is missing:\n\(ran.output)")
        ok(!ran.output.contains("no setup window"), "the plain no-window line was printed:\n\(ran.output)")
    }

    @Test("wait_setup_window with an unlocked screen keeps its status 1 and its line, without the stale task text")
    func waitSetupUnlocked() throws {
        let ran = try KC.bash(windowHarness + "\nwait_setup_window 2; echo \"RC=$?\"", kit: try KC.kitRoot(), env: ["KIT_SCREEN_LOCK_READING": unlockedReading])
        ok(status(ran) == 1, "exit \(String(describing: status(ran))):\n\(ran.output)")
        let line = KC.lines(ran.output).first ?? ""
        ok(KC.has(line, #"^no setup window: Sesame shows none 2 s after it started, at [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \(kit-ax\.sh dump setup said: no Sesame window\)$"#), "the line is not today's, without the stale text:\n\(ran.output)")
        ok(!ran.output.contains("plan-1-t28") && !ran.output.contains("NEEDS A PERSON"), "stale text or a person line:\n\(ran.output)")
    }

    @Test("settings_open with a locked screen: status 3 and the NEEDS A PERSON line; unlocked keeps `no Settings window` and status 1")
    func settingsOpen() throws {
        let kit = try KC.kitRoot()
        let lockedRan = try KC.bash(windowHarness + "\nsettings_open; echo \"RC=$?\"", kit: kit, env: ["KIT_SCREEN_LOCK_READING": lockedReading])
        ok(status(lockedRan) == 3 && KC.lines(lockedRan.output).contains(lockedLine) && !lockedRan.output.contains("no Settings window"), "locked: exit \(String(describing: status(lockedRan))):\n\(lockedRan.output)")
        let openRan = try KC.bash(windowHarness + "\nsettings_open; echo \"RC=$?\"", kit: kit, env: ["KIT_SCREEN_LOCK_READING": unlockedReading])
        ok(status(openRan) == 1 && openRan.output.contains("no Settings window: kit-ax.sh dump settings said \"no Sesame window\""), "unlocked: exit \(String(describing: status(openRan))):\n\(openRan.output)")
    }

    @Test("kit-doctor.sh has a screen check: a locked screen is a NEEDS A PERSON line, an unlocked one is OK")
    func doctorCheck() throws {
        let text = KC.read(KC.scripts + "/kit-doctor.sh") ?? ""
        guard let fn = KC.shellFunction("step_screen", in: text) else { ok(false, "kit-doctor.sh has no step_screen"); return }
        ok(text.contains("\n  step_screen\n"), "main does not call step_screen")
        let body = "need() { echo \"NEEDS A PERSON: $1\"; }\nok() { echo \"OK $1\"; }\n" + fn + "\nstep_screen; echo \"RC=$?\"\n"
        let lockedRan = try KC.bash(body, kit: try KC.kitRoot(), env: ["KIT_SCREEN_LOCK_READING": lockedReading])
        ok(KC.lines(lockedRan.output).contains(lockedLine), "locked:\n\(lockedRan.output)")
        let openRan = try KC.bash(body, kit: try KC.kitRoot(), env: ["KIT_SCREEN_LOCK_READING": unlockedReading])
        ok(!openRan.output.contains("NEEDS A PERSON") && openRan.output.contains("OK "), "unlocked:\n\(openRan.output)")
    }

    @Test("kit-run.sh with a locked screen refuses a recipe, a check run and a batch: exit 3, the NEEDS A PERSON line, and no kit script is launched")
    func runRefuses() throws {
        let rig = try Rig()
        try KC.write(rig.kit + "/run/id", "S5\n")
        try KC.write(rig.kit + "/run/version", "v1\n")
        for args in [["prep", "setup"], ["prep", "photos"], ["S9", "--ids", "S9.1"], ["batch", "A"]] {
            let ran = try rig.run(args, reading: lockedReading)
            ok(ran.status == 3, "\(args): exit \(ran.status):\n\(ran.output)")
            ok(KC.lines(ran.output).contains(lockedLine), "\(args): the line is missing:\n\(ran.output)")
            ok(rig.launched.isEmpty, "\(args): something was launched:\n\(rig.launched)")
        }
    }

    @Test("kit-run.sh with an unlocked screen is as before: prep with no starting state is exit 4, usage is exit 2, batches lists and starts nothing")
    func runUnlockedUnchanged() throws {
        let rig = try Rig()
        let prep = try rig.run(["prep", "setup"], reading: unlockedReading)
        ok(prep.status == 4 && prep.output.contains("no starting state") && !prep.output.contains("screen is locked"), "prep setup: exit \(prep.status):\n\(prep.output)")
        let usage = try rig.run(["nope"], reading: lockedReading)
        ok(usage.status == 2 && usage.output.contains("usage: kit-run.sh"), "usage with a locked screen: exit \(usage.status):\n\(usage.output)")
        let batches = try rig.run(["batches"], reading: lockedReading)
        ok(batches.status == 0 && !batches.output.contains("screen is locked"), "batches: exit \(batches.status):\n\(batches.output)")
        ok(rig.launched.isEmpty, "something was launched:\n\(rig.launched)")
    }
}
