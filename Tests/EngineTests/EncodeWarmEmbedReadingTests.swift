import Foundation
import Testing

// plan-1-t30, tester step. U18 (one warm query embed fits inside 500 ms) and U11 (the encode helper's footprint).
// Written from the t30 entry, the "Reading tests" paragraph of the plan's Conventions and design sections 8 and 9
// only; no product source read.
//
// The test starts the bundled RELEASE helper at dist/Sesame.app/Contents/MacOS/SesameHelper (never the debug
// build; the Run builds release and bundles just before it), sends 21 distinct embeds one after another, drops
// the first (it includes the model load) and reads the other 20 `ms` fields of the replies. Queries are distinct
// on purpose: a repeat would be served from the 256-entry cache and read as a near-zero figure.
//
// Prints:
//   READING U18 warm_embed_ms=<min>/<median>/<max>
//   READING U11 footprint_mb=<n>          (`footprint -p <pid>` on the helper pid, after the 21st reply)
// and checks the median and the maximum against the 500 ms bar of U18 with `Reading.check`. U11 has no bar here:
// its figure goes to the report (the A/B of the no-logits patch compares two runs of it).

private let barMs = 500.0

private let queries: [String] = {
    // The kit's distinct20 set (a dog on the beach first), hand-written, plus one more: 21 distinct texts.
    let file = KitPaths.projectRoot.appendingPathComponent("scripts/kit-lib/queries-distinct20.txt")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    let fromFile = text.split(separator: "\n")
        .filter { !$0.hasPrefix("#") }
        .map { String($0.split(separator: "\t", omittingEmptySubsequences: false)[0]) }
    return fromFile + ["a lighthouse on a rocky coast"]
}()

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return .nan }
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

extension EncodeHelperTests {
@Suite("EncodeWarmEmbedReadingTests", .serialized)
struct EncodeWarmEmbedReadingTests {

    @Test func twentyWarmEmbedsFitU18AndTheFootprintIsReadForU11() throws {
        #expect(queries.count == 21 && Set(queries).count == 21, "the reading needs 21 distinct queries, got \(queries.count)")
        let helperURL = KitPaths.bundledHelper
        try #require(FileManager.default.isExecutableFile(atPath: helperURL.path),
                     "bundled helper missing: \(helperURL.path) (swift build -c release, then scripts/bundle.sh)")
        let model = try #require(KitPaths.textModel(),
            "model file missing: $KIT_ROOT/cache/\(KitPaths.textModelName) (seed the cache: scripts/kit-mirror.sh seed --real)")
        let helper = try HelperProcess(executable: helperURL, arguments: ["encode", "--text-model", model.path])
        defer { helper.stop() }

        var ms: [Double] = []
        for (index, text) in queries.enumerated() {
            let id = index + 1
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let answer = helper.roundTrip("{\"cmd\":\"embed\",\"id\":\(id),\"text\":\"\(escaped)\",\"role\":\"query\"}")
            guard let reply = answer.reply else {
                Issue.record("embed \(id) of 21 got no JSON reply: \(String(describing: answer.raw)), stderr: \(helper.errors)")
                break
            }
            let problem = reply.vectorProblem(expectedID: id)
            #expect(problem == nil, "embed \(id): \(problem ?? "")")
            if index > 0, let measured = reply.ms { ms.append(Double(measured)) }
        }

        #expect(ms.count == 20, "expected 20 warm replies with an ms, got \(ms.count)")
        let low = ms.min() ?? .nan
        let middle = median(ms)
        let high = ms.max() ?? .nan
        print("READING U18 warm_embed_ms=\(Reading.format(low))/\(Reading.format(middle))/\(Reading.format(high))")

        let footprint = Tools.footprintMB(pid: helper.pid)
        #expect(footprint != nil, "footprint -p \(helper.pid) gave no phys_footprint (helper running: \(helper.isRunning))")
        print("READING U11 footprint_mb=\((footprint ?? .nan).rounded())")

        Reading.check(name: "U18 warm_embed_ms_median", value: middle, bar: barMs)
        Reading.check(name: "U18 warm_embed_ms_max", value: high, bar: barMs)
    }
}
}
