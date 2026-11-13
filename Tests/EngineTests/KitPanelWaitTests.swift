import Foundation
import Testing

private let panelFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("scripts/kit-lib/panel.sh")

private struct Outcome {
    let rc: Int
    let reads: Int
    let elapsedMs: Int
    let dumpHolds: String
    let output: String
}

private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private func bash(_ script: String, limit: TimeInterval = 60) throws -> String {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitwait-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", script]
    p.standardOutput = handle
    p.standardError = handle
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if p.isRunning {
        p.terminate()
        p.waitUntilExit()
    }
    try? handle.synchronize()
    return (try? String(contentsOf: out, encoding: .utf8)) ?? ""
}

private func waitList(max: Int, plan: [String]) throws -> Outcome? {
    guard FileManager.default.fileExists(atPath: panelFile.path) else {
        Issue.record("scripts/kit-lib/panel.sh not found")
        return nil
    }
    let script = """
    KIT_SCRIPTS=/nonexistent
    . \(shq(panelFile.path))
    PLAN=(\(plan.map(shq).joined(separator: " ")))
    NOW_MS=0
    READS=0
    date() { echo $((NOW_MS / 1000)); }
    sleep() { NOW_MS=$(awk -v t="$NOW_MS" -v s="$1" 'BEGIN { printf "%d", t + s * 1000 }'); }
    tree() {
      local i
      printf '%s\\n' 'window 700 x 400 at 0,0' 'AXWindow label="Sesame"' '  AXTextField value="q"' '  AXScrollArea' '    AXList'
      for ((i = 1; i <= $1; i++)); do printf '%s\\n' '      AXRow' "        AXStaticText value=\\"file$i.txt\\""; done
      printf '%s\\n' "  AXStaticText value=\\"$2\\""
    }
    pn_dump() {
      local entry cost kind
      READS=$((READS + 1))
      [ "$READS" -le 400 ] || { echo "RUNAWAY"; exit 99; }
      if [ "$READS" -le "${#PLAN[@]}" ]; then entry="${PLAN[$((READS - 1))]}"; else entry="${PLAN[$((${#PLAN[@]} - 1))]}"; fi
      cost="${entry%%:*}"
      kind="${entry#*:}"
      NOW_MS=$((NOW_MS + cost * 1000))
      case "$kind" in
        steady) PN_DUMP="$(tree 3 'pane steady')" ;;
        vary) PN_DUMP="$(tree $((READS % 7 + 1)) "pane v$READS")" ;;
        needs) PN_DUMP="NEEDS A PERSON: Sesame did not answer Apple Events within 10 s, restart it" ;;
        searching) PN_DUMP="$(tree 0 'Searching')" ;;
      esac
      return 0
    }
    pn_wait_list \(max)
    rc=$?
    echo "RESULT rc=$rc reads=$READS now_ms=$NOW_MS"
    echo "DUMP $(printf '%s' "$PN_DUMP" | tr '\\n' '~')"
    """
    let text = try bash(script)
    var rc = -1, reads = -1, now = -1
    var held = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line.hasPrefix("RESULT ") {
            for field in line.dropFirst(7).split(separator: " ") {
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, let n = Int(pair[1]) else { continue }
                switch pair[0] {
                case "rc": rc = n
                case "reads": reads = n
                case "now_ms": now = n
                default: break
                }
            }
        } else if line.hasPrefix("DUMP ") {
            held = String(line.dropFirst(5))
        }
    }
    if rc < 0 { Issue.record(Comment(rawValue: "the harness gave no result: \(text.suffix(400))")) }
    return Outcome(rc: rc, reads: reads, elapsedMs: now, dumpHolds: held, output: text)
}

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

@Suite("KitPanelWaitTests", .serialized)
struct KitPanelWaitTests {
    @Test("a slow list (12 s a dump, max 20) that holds still for three reads settles with status 0 after 36 s, inside max + 4 x first")
    func slowListSettlesPastMax() throws {
        guard let r = try waitList(max: 20, plan: ["12:steady"]) else { return }
        ok(r.rc == 0, "a list whose three successive reads are identical must settle (status 0), got \(r.rc) after \(r.reads) reads, \(r.elapsedMs) ms")
        ok(r.reads == 3, "three identical reads settle it, so exactly three dumps: \(r.reads)")
        ok(r.dumpHolds.contains("pane steady"), "PN_DUMP must hold the settled dump")
        ok(r.elapsedMs <= 68_000, "it must settle inside the budget of 68 s: \(r.elapsedMs) ms")
    }

    @Test("a slow list that never settles (5 s a dump, max 10) gets max + 4 x 5 = 30 s, then returns 4: not earlier, not much later")
    func slowListNeverSettlesStopsAtBudget() throws {
        guard let r = try waitList(max: 10, plan: ["5:vary"]) else { return }
        ok(r.rc == 4, "a list that never holds still returns 4, got \(r.rc)")
        ok(r.elapsedMs >= 30_000, "a 5 s first dump earns 4 x 5 s on top of max, so it must keep reading until 30 s: stopped at \(r.elapsedMs) ms")
        ok(r.elapsedMs <= 37_000, "it must stop once 30 s have passed (one dump of 5 s and the sleeps of slack): \(r.elapsedMs) ms")
    }

    @Test("a first dump of 1 s adds 4 s: max 10 allows 14 s")
    func oneSecondFirstDumpAddsFourSeconds() throws {
        guard let r = try waitList(max: 10, plan: ["1:vary"]) else { return }
        ok(r.rc == 4, "a list that never holds still returns 4, got \(r.rc)")
        ok(r.elapsedMs >= 14_000, "max + 4 x 1 is 14 s: stopped at \(r.elapsedMs) ms")
        ok(r.elapsedMs <= 17_000, "it must stop once 14 s have passed: \(r.elapsedMs) ms")
    }

    @Test("a fast list that never settles still times out at max (3 s)")
    func fastListTimesOutAtMax() throws {
        guard let r = try waitList(max: 3, plan: ["0:vary"]) else { return }
        ok(r.rc == 4, "a list that never holds still returns 4, got \(r.rc)")
        ok(r.elapsedMs >= 3_000, "it must not give up before max: \(r.elapsedMs) ms")
        ok(r.elapsedMs <= 5_000, "a fast first dump earns no extra time: stopped at \(r.elapsedMs) ms")
    }

    @Test("only the first dump sets the budget: a fast first dump followed by 12 s dumps still times out near max (20 s)")
    func laterSlowDumpsDoNotExtendTheBudget() throws {
        guard let r = try waitList(max: 20, plan: ["0:vary", "12:vary"]) else { return }
        ok(r.rc == 4, "a list that never holds still returns 4, got \(r.rc)")
        ok(r.elapsedMs >= 20_000, "it must not give up before max: \(r.elapsedMs) ms")
        ok(r.elapsedMs <= 34_000, "the budget is max plus four times the first dump (0 s), so one more 12 s dump at most: \(r.elapsedMs) ms")
    }

    @Test("a dump that holds NEEDS A PERSON is unsettled: three identical ones return 4, not 0")
    func needsAPersonIsNotSettled() throws {
        guard let r = try waitList(max: 3, plan: ["0:needs"]) else { return }
        ok(r.rc == 4, "three identical NEEDS A PERSON dumps must not count as a settled list, got status \(r.rc) after \(r.reads) reads")
        ok(r.elapsedMs >= 3_000, "it must keep reading until max: \(r.elapsedMs) ms")
    }

    @Test("NEEDS A PERSON dumps reset the count: three of them, then three identical good reads, settle on the good dump after six reads")
    func settlesOnGoodDumpAfterNeedsAPerson() throws {
        guard let r = try waitList(max: 30, plan: ["0:needs", "0:needs", "0:needs", "0:steady"]) else { return }
        ok(r.rc == 0, "the good reads at the end settle it: status \(r.rc)")
        ok(r.reads == 6, "three identical good reads after the three NEEDS A PERSON ones make six dumps: \(r.reads)")
        ok(r.dumpHolds.contains("pane steady") && !r.dumpHolds.contains("NEEDS A PERSON"), "PN_DUMP must hold the good dump, not the NEEDS A PERSON line: \(r.dumpHolds)")
    }

    @Test("a Searching dump is unsettled: three Searching reads, then three identical good reads, settle after six reads")
    func searchingIsNotSettled() throws {
        guard let r = try waitList(max: 30, plan: ["0:searching", "0:searching", "0:searching", "0:steady"]) else { return }
        ok(r.rc == 0, "the good reads at the end settle it: status \(r.rc)")
        ok(r.reads == 6, "six dumps: \(r.reads)")
        ok(r.dumpHolds.contains("pane steady"), "PN_DUMP must hold the good dump: \(r.dumpHolds)")
    }

    @Test("three identical reads in a row settle at once with status 0")
    func threeIdenticalReadsSettle() throws {
        guard let r = try waitList(max: 20, plan: ["0:steady"]) else { return }
        ok(r.rc == 0, "status \(r.rc)")
        ok(r.reads == 3, "three dumps: \(r.reads)")
        ok(r.elapsedMs < 2_000, "no waiting beyond the polling sleeps: \(r.elapsedMs) ms")
    }

    @Test("a list that changes once and then holds still settles three identical reads after the change")
    func settlesAfterAChange() throws {
        guard let r = try waitList(max: 20, plan: ["0:vary", "0:steady"]) else { return }
        ok(r.rc == 0, "status \(r.rc)")
        ok(r.reads == 4, "one changing read then three identical ones: \(r.reads)")
        ok(r.dumpHolds.contains("pane steady"), "PN_DUMP must hold the settled dump: \(r.dumpHolds)")
    }

    @Test("a list that never settles returns 4 and prints the unsettled report: the header, the last rows and the pane, and that no Searching line shows")
    func unsettledReportKept() throws {
        guard let r = try waitList(max: 2, plan: ["0:vary"]) else { return }
        ok(r.rc == 4, "status \(r.rc)")
        ok(r.output.contains("| unsettled after "), "the unsettled header line is gone: \(r.output.prefix(300))")
        ok(r.output.contains("(no Searching line)"), "the header must say no Searching line shows")
        ok(r.output.contains("| unsettled row: "), "the unsettled row lines are gone")
        ok(r.output.contains("| unsettled pane: "), "the unsettled pane lines are gone")
    }

    @Test("a list that is still Searching when time is up returns 4 and says a Searching line shows")
    func unsettledReportNamesSearching() throws {
        guard let r = try waitList(max: 2, plan: ["0:searching"]) else { return }
        ok(r.rc == 4, "status \(r.rc)")
        ok(r.output.contains("a Searching line shows"), "the header must say a Searching line shows: \(r.output.prefix(300))")
    }
}
