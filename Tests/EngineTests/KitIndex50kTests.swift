import Foundation
import Testing

// plan-6-t9, tester step, part A: the recipe `index50k`, the real-indexer 50,000-row index. Written from the entry plan-6-t9 (part A) of
// plan-6-tasks.md, D14 and verify.md K22. Nothing here indexes anything: the build is the real model and hours, so its logic is proved with a
// stub helper that writes a file and a stub `kit-index.sh rows`; the cache logic runs on cache folders written by hand.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - `kit-run.sh prep index50k [--restore-only]`. Its first output line is `LONG: this build takes hours` (not with --restore-only, which never
//     builds); the usage text says it too.
//   - The cache is `cache/index50k-real-<V>/` (V = run/version) holding index.sqlite* and a text file `meta` of lines `saved_version <V>`,
//     `vector_source <text>`, `rows <n>`, `built <date>`. The stand-in's `cache/index50k-<V>/` (busy50k_seed) is never read or written.
//   - A cache is fresh when its saved_version is this run's and its vector_source names both model files of models.tsv (the kit cannot know the
//     product's revision and vector version; the first reading of S2.9 says whether the app accepts the index). Fresh: `restored from cache <dir>`
//     (the index copied into the throwaway home after a reset, no helper run, repeatable). Stale: `stale: <why>`, never reused; rebuilt, or with
//     --restore-only exit 4. No cache: built, or with --restore-only exit 4 `no cache`.
//   - The build runs `kit-launch.sh helper index --folders golden filler --code-folders home/Developer/api-client` with no --fake-embedder, repeats until
//     `kit-index.sh wait done` or three runs add no row, and fewer than 50,000 rows (the `rows` line of `kit-index.sh rows`) is exit 4 with no cache
//     written. The finished index is kept with `kit-index.sh meta vector_source` in the meta file; a stale cache is replaced only by a whole new one.
//   - `kit-index.sh meta <name>` prints a fact of the meta table (both shapes the design allows) or exits 1.
// Red before the kit part: `prep index50k` prints `not built yet`, exit 1; `kit-index.sh meta` is usage.

private let kitRun = KC.scripts + "/kit-run.sh"
private let kitIndex = KC.scripts + "/kit-index.sh"
private let names = "embeddinggemma-2-Q8_0.gguf,mmproj-embeddinggemma-2-Q8_0.gguf"

private func state(_ kit: String, version: String = "v1") throws {
    try KC.write(kit + "/run/id", "S2\n")
    try KC.write(kit + "/run/version", version + "\n")
}

private func cache(_ kit: String, dirVersion: String = "v1", saved: String = "v1", source: String = names + " rev3 vec2") throws -> String {
    let dir = kit + "/cache/index50k-real-" + dirVersion
    try KC.write(dir + "/index.sqlite", "hand-written index\n")
    try KC.write(dir + "/meta", "saved_version \(saved)\nvector_source \(source)\nrows 50123\nbuilt 2026-01-01 00:00:00\n")
    return dir
}

/// The fake app: every kit script the recipe calls is logged; the helper writes an index file; `rows` and `meta` answer from env.
private let harness = #"""
export KIT_HELPER_EXE="$KIT_ROOT/fake-helper"
: > "$KIT_HELPER_EXE"; chmod +x "$KIT_HELPER_EXE"
LOG="$KIT_ROOT/fake-calls.log"; : > "$LOG"
log() { printf '%s\n' "$*" >> "$LOG"; }
helper_has_index_mode() { return 0; }
models_check() { return 0; }
usage() { echo "usage: kit-run.sh prep ..." >&2; }
index50k_app() { log "app"; echo "index50k app part"; }
kq() {
  local script; script="$(basename "$1")"; shift
  case "$script" in
    kit-reset.sh) log "reset $*"; rm -rf "$KIT_ROOT/home"; mkdir -p "$KIT_ROOT/home"; mkdir -p "$KIT_ROOT/run"; echo S2 > "$KIT_ROOT/run/id"; echo v1 > "$KIT_ROOT/run/version" ;;
    kit-fixtures.sh) log "build $*" ;;
    kit-launch.sh)
      case "$1" in
        helper)
          log "helper $*"
          d="$KIT_ROOT/home/Library/Application Support/Sesame"; mkdir -p "$d"
          echo "fake index of run $(grep -c '^helper' "$LOG")" > "$d/index.sqlite" ;;
        *) log "launch $*" ;;
      esac ;;
    kit-index.sh)
      case "$1" in
        rows) log "index rows"; printf 'files 10\npassages %s\nrows %s\n' "$((FAKE_ROWS - 10))" "$FAKE_ROWS" ;;
        meta) log "index meta $2"; echo "$FAKE_VSRC" ;;
        wait) log "index wait $*"; [ "${FAKE_NOT_DONE:-0}" = 1 ] && return 1; return 0 ;;
      esac ;;
    *) log "unexpected $script $*"; return 99 ;;
  esac
}
"""#

private func recipe(_ kit: String, _ call: String, env: [String: String] = [:]) throws -> (KC.Ran, [String]) {
    let r = try KC.bash(harness + "\nrecipe_state\n\(call); echo \"RC $?\"", kit: kit, env: env)
    return (r, KC.lines(KC.read(kit + "/fake-calls.log") ?? ""))
}

@Suite("KitIndex50kTests")
struct KitIndex50kTests {
    // MARK: the cache: stale and restore, on hand-written folders

    @Test("a cache for another saved version is `stale`, exit 4 on the restore-only path, and nothing is reset or copied")
    func staleVersion() throws {
        let kit = try KC.kitRoot()
        try state(kit, version: "v2")
        _ = try cache(kit, dirVersion: "v2", saved: "v1")
        let r = try KC.run(kitRun, ["prep", "index50k", "--restore-only"], env: ["KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1"])
        #expect(r.status == 4, "exit \(r.status): \(r.output)")
        #expect(r.output.contains("stale") && r.output.contains("v1"), "no `stale` line naming the old version: \(r.output)")
        #expect(!FileManager.default.fileExists(atPath: kit + "/home"), "a stale cache was restored or a reset ran")
    }

    @Test("a cache whose vector_source does not name both model files is `stale`, exit 4 on the restore-only path")
    func staleSource() throws {
        let kit = try KC.kitRoot()
        try state(kit)
        _ = try cache(kit, source: "embeddinggemma-3-Q8_0.gguf,mmproj-embeddinggemma-3-Q8_0.gguf rev1 vec1")
        let r = try KC.run(kitRun, ["prep", "index50k", "--restore-only"], env: ["KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1"])
        #expect(r.status == 4, "exit \(r.status): \(r.output)")
        #expect(r.output.contains("stale") && r.output.contains("vector_source"), "no `stale` line naming the vector_source: \(r.output)")
        #expect(!FileManager.default.fileExists(atPath: kit + "/home"), "a stale cache was restored")
        // a cache that names only one of the two files is stale too
        try KC.write(kit + "/cache/index50k-real-v1/meta", "saved_version v1\nvector_source embeddinggemma-2-Q8_0.gguf rev3\nrows 1\n")
        let one = try KC.run(kitRun, ["prep", "index50k", "--restore-only"], env: ["KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1"])
        #expect(one.status == 4 && one.output.contains("stale"), "a cache naming one model file: exit \(one.status): \(one.output)")
    }

    @Test("a cache with no meta file, or no vector_source line, is stale")
    func noMeta() throws {
        let kit = try KC.kitRoot()
        try state(kit)
        let dir = try cache(kit)
        try FileManager.default.removeItem(atPath: dir + "/meta")
        let r = try KC.run(kitRun, ["prep", "index50k", "--restore-only"], env: ["KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1"])
        #expect(r.status == 4 && r.output.contains("stale"), "no meta: exit \(r.status): \(r.output)")
    }

    @Test("no cache at all is exit 4 `no cache` on the restore-only path, and the stand-in's cache/index50k-<V> is never read")
    func noCacheAndStandIn() throws {
        let kit = try KC.kitRoot()
        try state(kit)
        try KC.write(kit + "/cache/index50k-v1/index.sqlite", "the busy50k stand-in's fake-vector index\n")
        let r = try KC.run(kitRun, ["prep", "index50k", "--restore-only"], env: ["KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1"])
        #expect(r.status == 4 && r.output.contains("no cache"), "exit \(r.status): \(r.output)")
        #expect(!r.output.contains("restored"), "the stand-in's index was restored: \(r.output)")
        #expect(!FileManager.default.fileExists(atPath: kit + "/home"), "something was restored")
    }

    @Test("a fresh cache is restored without indexing: `restored from cache`, a reset first, the index copied into the throwaway home, no helper run; repeatable")
    func restore() throws {
        let kit = try KC.kitRoot()
        try state(kit)
        _ = try cache(kit)
        for pass in 1...2 {
            let (r, calls) = try recipe(kit, "recipe_index50k --restore-only")
            #expect(r.output.contains("restored from cache"), "pass \(pass): \(r.output)")
            #expect(r.output.contains("RC 0"), "pass \(pass): \(r.output)")
            #expect(!calls.contains { $0.hasPrefix("helper") }, "pass \(pass): the helper ran: \(calls)")
            let reset = calls.firstIndex { $0.hasPrefix("reset ") }, app = calls.firstIndex(of: "app")
            #expect(reset != nil && app != nil && reset! < app!, "pass \(pass): reset then app expected: \(calls)")
            #expect(KC.read(kit + "/home/Library/Application Support/Sesame/index.sqlite") == "hand-written index\n", "pass \(pass): the cached index was not copied into the home")
            #expect(KC.read(kit + "/cache/index50k-real-v1/index.sqlite") == "hand-written index\n", "pass \(pass): the cache changed")
        }
    }

    @Test("the first output line of a build is `LONG: this build takes hours`; --restore-only never prints it")
    func longLabel() throws {
        let kit = try KC.kitRoot()
        try state(kit)
        _ = try cache(kit)
        let (build, _) = try recipe(kit, "recipe_index50k")
        #expect(KC.lines(build.output).first == "LONG: this build takes hours", "first line: \(KC.lines(build.output).first ?? "none")")
        let (only, _) = try recipe(kit, "recipe_index50k --restore-only")
        #expect(!only.output.contains("LONG:"), "--restore-only printed the LONG label")
        let usage = try KC.run(kitRun, ["nonsense"], env: ["KIT_ROOT": kit])
        #expect(usage.output.contains("prep index50k") && usage.output.contains("LONG"), "the usage text does not label index50k as long: \(usage.output)")
    }

    // MARK: the build, with stub helper

    @Test("the build runs the real helper (no --fake-embedder) on golden, filler and api-client, and keeps an index of at least 50,000 rows with its meta record")
    func buildKeepsTheCache() throws {
        let kit = try KC.kitRoot()
        try state(kit)
        let (r, calls) = try recipe(kit, "recipe_index50k", env: ["FAKE_ROWS": "50001", "FAKE_VSRC": names + " rev3 vec2"])
        #expect(r.output.contains("RC 0"), "exit: \(r.output)")
        let helper = calls.filter { $0.hasPrefix("helper") }
        #expect(!helper.isEmpty, "the helper never ran: \(calls)")
        for h in helper {
            #expect(h.contains("index") && h.contains("--folders golden filler") && h.contains("--read-folders home/Developer/api-client") && !h.contains("--code-folders"), "helper call: \(h)")
            #expect(!h.contains("--fake-embedder"), "the build used the fake embedder: \(h)")
        }
        let dir = kit + "/cache/index50k-real-v1"
        #expect(KC.read(dir + "/index.sqlite")?.hasPrefix("fake index") == true, "no index in the cache")
        let meta = KC.read(dir + "/meta") ?? ""
        #expect(meta.contains("saved_version v1") && meta.contains("vector_source \(names) rev3 vec2") && meta.contains("rows 50001"), "meta: \(meta)")
        #expect(!FileManager.default.fileExists(atPath: dir + ".new"), "the .new folder was left behind")
        #expect(!FileManager.default.fileExists(atPath: kit + "/cache/index50k-v1"), "the stand-in's cache name was written")
        let restored = calls.firstIndex { $0.hasPrefix("reset ") && calls.firstIndex(of: "app") != nil }
        #expect(restored != nil, "no restore after the build: \(calls)")
    }

    @Test("fewer than 50,000 rows is exit 4 `fewer than 50,000`, never a pass, and no cache is written")
    func tooSmall() throws {
        let kit = try KC.kitRoot()
        try state(kit)
        let (r, calls) = try recipe(kit, "recipe_index50k", env: ["FAKE_ROWS": "49999", "FAKE_VSRC": names])
        #expect(r.output.contains("RC 4"), "exit: \(r.output)")
        #expect(r.output.contains("fewer than 50,000"), "no reason: \(r.output)")
        #expect(!FileManager.default.fileExists(atPath: kit + "/cache/index50k-real-v1"), "a cache was written for a short index")
        #expect(!calls.contains("app"), "the app part ran after a short index")
    }

    @Test("a helper run that leaves work is run again, and three runs that add no row are exit 4")
    func helperLoop() throws {
        let kit = try KC.kitRoot()
        try state(kit)
        let (r, calls) = try recipe(kit, "recipe_index50k", env: ["FAKE_ROWS": "40000", "FAKE_NOT_DONE": "1", "FAKE_VSRC": names])
        #expect(r.output.contains("RC 4") && r.output.contains("no row in 3 runs"), "exit: \(r.output)")
        #expect(calls.filter { $0.hasPrefix("helper") }.count == 4, "the helper ran \(calls.filter { $0.hasPrefix("helper") }.count) times, expected 1 + 3 stuck runs")
    }

    @Test("a stale cache is refused and rebuilt, never reused: the old index is replaced by the new one only when the build is whole")
    func staleIsRebuilt() throws {
        let kit = try KC.kitRoot()
        try state(kit)
        _ = try cache(kit, saved: "v0")
        let (r, calls) = try recipe(kit, "recipe_index50k", env: ["FAKE_ROWS": "50500", "FAKE_VSRC": names + " rev4"])
        #expect(r.output.contains("stale") && r.output.contains("RC 0"), "exit: \(r.output)")
        #expect(calls.contains { $0.hasPrefix("helper") }, "no rebuild: \(calls)")
        let meta = KC.read(kit + "/cache/index50k-real-v1/meta") ?? ""
        #expect(meta.contains("saved_version v1") && meta.contains("rev4"), "the cache still holds the old meta: \(meta)")
        // a failed rebuild keeps the stale cache untouched (it is replaced only by a whole one)
        let kit2 = try KC.kitRoot()
        try state(kit2)
        _ = try cache(kit2, saved: "v0")
        let (bad, _) = try recipe(kit2, "recipe_index50k", env: ["FAKE_ROWS": "100", "FAKE_VSRC": names])
        #expect(bad.output.contains("RC 4"), "exit: \(bad.output)")
        #expect((KC.read(kit2 + "/cache/index50k-real-v1/meta") ?? "").contains("saved_version v0"), "a failed rebuild changed the old cache")
    }

    // MARK: kit-index.sh meta

    private func sqlite(_ db: String, _ sql: String) throws {
        let r = try KC.run("/usr/bin/sqlite3", [db, sql])
        #expect(r.status == 0, "sqlite3 failed: \(r.output)")
    }

    @Test("kit-index.sh meta <name> prints a meta fact in either table shape and exits 1 for one that is not there")
    func metaMode() throws {
        for shape in ["keyvalue", "columns"] {
            let kit = try KC.kitRoot()
            let dir = kit + "/home/Library/Application Support/Sesame"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if shape == "keyvalue" {
                try sqlite(dir + "/index.sqlite", "create table meta(key text, value text); insert into meta values('vector_source','gemma rev9 v2'),('schema','7');")
            } else {
                try sqlite(dir + "/index.sqlite", "create table meta(schema text, vector_source text); insert into meta values('7','gemma rev9 v2');")
            }
            let got = try KC.run(kitIndex, ["meta", "vector_source"], env: ["KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1"])
            #expect(got.status == 0 && got.output.trimmingCharacters(in: .whitespacesAndNewlines) == "gemma rev9 v2", "\(shape): exit \(got.status): \(got.output)")
            let miss = try KC.run(kitIndex, ["meta", "walk_done_at"], env: ["KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1"])
            #expect(miss.status == 1, "\(shape): a missing fact exited \(miss.status): \(miss.output)")
        }
    }

    @Test("the stand-in recipe is unchanged: busy50k still seeds cache/index50k-<V> with --fake-embedder, and index50k never does")
    func standInStays() {
        let text = KC.read(KC.lib + "/recipes.sh") ?? ""
        let seed = KC.shellFunction("busy50k_seed", in: text) ?? ""
        #expect(seed.contains("cache/index50k-$R_VERSION") && seed.contains("--fake-embedder"), "busy50k_seed changed")
        for name in ["index50k_build", "index50k_restore", "index50k_app", "recipe_index50k", "index50k_cache_state"] {
            let fn = KC.shellFunction(name, in: text) ?? ""
            #expect(!fn.isEmpty, "recipes.sh has no \(name)")
            #expect(!fn.contains("--fake-embedder") && !fn.contains("cache/index50k-$R_VERSION"), "\(name) touches the stand-in")
        }
        #expect(!text.contains("not built yet: recipe $r"), "the `not built yet` stub is still there")
    }
}
