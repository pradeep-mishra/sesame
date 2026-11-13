import Foundation
import Testing

private struct Probe {
    let status: Int32
    let output: String
    let calls: Int
}

private func probe(_ mode: String) throws -> Probe {
    let base = try KC.tempDir("kit-probe-")
    let bin = base + "/bin"
    let fake = base + "/fake"
    let kit = base + "/sesame-kit"
    try FileManager.default.createDirectory(atPath: kit + "/run", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: fake, withIntermediateDirectories: true)
    try KC.write(bin + "/osascript", """
    #!/bin/bash
    n=$(( $(cat "$FAKE/count" 2>/dev/null || echo 0) + 1 ))
    echo $n > "$FAKE/count"
    case "$MODE" in
      transient) if [ $n -le 2 ]; then echo "execution error: System Events got an error: transient (-600)" >&2; exit 1; fi ;;
      permission) echo "execution error: Not authorized to send Apple events to System Events. (-1743)" >&2; exit 1 ;;
      assistive) echo "execution error: osascript is not allowed assistive access. (-25211)" >&2; exit 1 ;;
      persistent) echo "execution error: boom happened (-600)" >&2; exit 1 ;;
      slow) if [ $n -eq 1 ]; then sleep 22; fi ;;
    esac
    exit 0

    """)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/osascript")
    let path = bin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
    let env = ["KIT_ROOT": kit, "FAKE": fake, "MODE": mode, "PATH": path, "KIT_NO_EVIDENCE": "1"]
    let start = try KC.run(KC.scripts + "/kit-privacy.sh", ["prompts", "start", "t1"], env: env, limit: 150)
    if start.status == 0 { _ = try KC.run(KC.scripts + "/kit-privacy.sh", ["prompts", "stop", "t1"], env: env, limit: 60) }
    let calls = Int((KC.read(fake + "/count") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    return Probe(status: start.status, output: start.output, calls: calls)
}

@Suite("KitPromptsProbeTests", .serialized)
struct KitPromptsProbeTests {
    @Test("prompts start: a probe that fails twice with a non-permission error and then reads the windows starts the watcher")
    func transientFailureThenSuccessPasses() throws {
        let r = try probe("transient")
        #expect(r.status == 0 && r.output.contains("PROMPTS watcher t1 started"), "a transient failure stopped the watcher: rc \(r.status) \(r.output.suffix(400))")
        #expect(r.calls >= 3, "the probe was tried \(r.calls) times, the third try succeeds")
        #expect(!r.output.contains("NEEDS A PERSON"), "a transient failure was reported as a missing permission: \(r.output.suffix(400))")
    }

    @Test("prompts start: an error -1743 or -25211 in osascript's stderr is NEEDS A PERSON, exit 3")
    func permissionErrorNeedsAPerson() throws {
        for mode in ["permission", "assistive"] {
            let r = try probe(mode)
            #expect(r.status == 3 && r.output.contains("NEEDS A PERSON"), "\(mode): rc \(r.status) \(r.output.suffix(400))")
            #expect(!r.output.contains("RERUN"), "\(mode) was also called a RERUN: \(r.output.suffix(400))")
        }
    }

    @Test("prompts start: a failure that carries no permission code on all 3 tries is RERUN, exit 4, with osascript's own words in the message")
    func persistentFailureIsRerun() throws {
        let r = try probe("persistent")
        #expect(r.status == 4 && r.output.contains("RERUN") && r.output.contains("boom happened"), "rc \(r.status) \(r.output.suffix(400))")
        #expect(!r.output.contains("NEEDS A PERSON"), "a non-permission failure was reported as a missing permission: \(r.output.suffix(400))")
        #expect(r.calls == 3, "the probe was tried \(r.calls) times, not 3")
    }

    @Test("prompts start: a first probe that takes 22 seconds is within the 30 second limit and starts the watcher")
    func slowProbeIsNotATimeout() throws {
        let r = try probe("slow")
        #expect(r.status == 0 && r.output.contains("PROMPTS watcher t1 started"), "a 22 s probe failed: rc \(r.status) \(r.output.suffix(400))")
    }
}
