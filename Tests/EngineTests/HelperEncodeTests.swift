import Foundation
import Testing

// plan-1-t30, tester step. Written from the t30 entry, the Helper protocol table of the plan's Conventions and
// design sections 2, 7 and 8 only; no product source read.
//
// These tests start the helper the way the app does: `SesameHelper encode --text-model <path>` (the flag is fixed in
// the Conventions), send JSON lines on its stdin and read JSON lines on its stdout. The helper is the debug build
// that `swift test` builds next to the test bundle (the test target depends on it), so `swift test --filter
// HelperEncodeTests` needs no bundle. The release bundle is read by EncodeWarmEmbedReadingTests.
// "No model path was given" means the helper is started without `--text-model` (the kit's `--no-model`).
//
// What is asserted comes from the entry, from the protocol table (hand-written below) or from the reference
// vectors (read only, made by mlx-vlm, never by Sesame). Nothing is taken from the code under test.
//
// Cache observation: the entry says a repeat of a recent query "is served from the cache" and the table gives no
// field for it, so it is observed from outside as time: a repeat answers in far less time than an embed (under half
// the median time of the 257 first-time answers), with the same vector. The 257th distinct query must still answer.
// A 256-entry cache evicts the oldest entry, so the very first query, asked again after 257 distinct ones, is slow.

private let referenceFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Reference/vectors.json")

private func embedLine(id: Int, text: String, role: String = "query", extra: String = "") -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"cmd\":\"embed\",\"id\":\(id),\"text\":\"\(escaped)\",\"role\":\"\(role)\"\(extra)}"
}

private func cosine(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for index in 0..<min(a.count, b.count) {
        dot += a[index] * b[index]; na += a[index] * a[index]; nb += b[index] * b[index]
    }
    return dot / (na.squareRoot() * nb.squareRoot())
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return .nan }
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

private func startEncode(withModel: Bool) throws -> HelperProcess {
    let helper = try #require(KitPaths.debugHelper(), "debug SesameHelper not found next to the test bundle or in .build/debug")
    var arguments = ["encode"]
    if withModel {
        let model = try #require(KitPaths.textModel(),
            "model file missing: $KIT_ROOT/cache/\(KitPaths.textModelName) (seed the cache: scripts/kit-mirror.sh seed --real)")
        arguments += ["--text-model", model.path]
    }
    return try HelperProcess(executable: helper, arguments: arguments)
}

// One helper at a time (one model in memory at a time).
extension EncodeHelperTests {
@Suite("HelperEncodeTests", .serialized)
struct HelperEncodeTests {

    // MARK: the kit's line file

    @Test func theKitLineFileHoldsTheOneEmbedLineOfTheEntry() throws {
        let file = KitPaths.projectRoot.appendingPathComponent("scripts/kit-lib/helper-lines/embed-dog.jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == "{\"cmd\":\"embed\",\"id\":1,\"text\":\"a dog on the beach\",\"role\":\"query\"}\n")
    }

    // MARK: the vector reply

    @Test func theDogLineGetsAVectorReplyOf768UnitNumbersWithItsMs() throws {
        let line = try String(contentsOf: KitPaths.projectRoot
            .appendingPathComponent("scripts/kit-lib/helper-lines/embed-dog.jsonl"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let helper = try startEncode(withModel: true)
        defer { helper.stop() }
        let answer = helper.roundTrip(line)
        let reply = try #require(answer.reply, "no JSON reply to the dog line; got \(String(describing: answer.raw)), stderr: \(helper.errors)")
        #expect(reply.vectorProblem(expectedID: 1) == nil, "\(reply.vectorProblem(expectedID: 1) ?? "")")
    }

    @Test func theDogVectorMatchesTheReferenceVectorOfTheSameQueryWithin0999() throws {
        // The reference "query" entry is the vector of "payment declined error" with the model-card query prompt.
        let data = try #require(try? Data(contentsOf: referenceFile), "reference vectors missing: \(referenceFile.path)")
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let table = try #require(top["vectors"] as? [String: [Double]])
        let reference = try #require(table["query"], "reference has no `query` vector")
        let helper = try startEncode(withModel: true)
        defer { helper.stop() }
        let answer = helper.roundTrip(embedLine(id: 3, text: "payment declined error"))
        let reply = try #require(answer.reply, "no JSON reply; got \(String(describing: answer.raw)), stderr: \(helper.errors)")
        #expect(reply.vectorProblem(expectedID: 3) == nil, "\(reply.vectorProblem(expectedID: 3) ?? "")")
        let vec = try #require(reply.vec)
        let score = cosine(vec, reference)
        #expect(score >= 0.999, "cosine against the reference is \(score)")
    }

    @Test func theSameQueryTwiceGivesTheSameVectorAndDifferentQueriesDiffer() throws {
        let helper = try startEncode(withModel: true)
        defer { helper.stop() }
        let first = try #require(helper.roundTrip(embedLine(id: 1, text: "a dog on the beach")).reply)
        let again = try #require(helper.roundTrip(embedLine(id: 2, text: "a dog on the beach")).reply)
        let other = try #require(helper.roundTrip(embedLine(id: 3, text: "the invoice for the third quarter")).reply)
        #expect(first.vectorProblem(expectedID: 1) == nil, "\(first.vectorProblem(expectedID: 1) ?? "")")
        #expect(again.vectorProblem(expectedID: 2) == nil, "\(again.vectorProblem(expectedID: 2) ?? "")")
        #expect(other.vectorProblem(expectedID: 3) == nil, "\(other.vectorProblem(expectedID: 3) ?? "")")
        let a = first.vec ?? [], b = again.vec ?? [], c = other.vec ?? []
        let widest = zip(a, b).map { abs($0 - $1) }.max() ?? .infinity
        #expect(a.count == 768 && widest <= 1e-6, "the same text twice differs by \(widest)")
        #expect(cosine(a, c) < 0.95, "a dog and an invoice have cosine \(cosine(a, c))")
    }

    @Test func theRoleIsHonouredAndAnUnknownExtraFieldIsTolerated() throws {
        let helper = try startEncode(withModel: true)
        defer { helper.stop() }
        let query = try #require(helper.roundTrip(embedLine(id: 11, text: "meeting notes", role: "query")).reply)
        let document = try #require(helper.roundTrip(
            embedLine(id: 12, text: "meeting notes", role: "document", extra: ",\"note\":{\"x\":[1,2]},\"flag\":true")).reply)
        #expect(query.vectorProblem(expectedID: 11) == nil, "\(query.vectorProblem(expectedID: 11) ?? "")")
        #expect(document.vectorProblem(expectedID: 12) == nil, "\(document.vectorProblem(expectedID: 12) ?? "")")
        let score = cosine(query.vec ?? [], document.vec ?? [])
        #expect(score < 0.9999, "query and document of one text have cosine \(score): the role is ignored")
    }

    @Test func aPrewarmLineThenAnEmbedStillAnswersTheEmbed() throws {
        let helper = try startEncode(withModel: true)
        defer { helper.stop() }
        helper.send("{\"cmd\":\"prewarm\"}")
        let answer = helper.roundTrip(embedLine(id: 21, text: "a snow covered mountain"))
        let reply = try #require(answer.reply, "no JSON reply after prewarm; got \(String(describing: answer.raw)), stderr: \(helper.errors)")
        #expect(reply.vectorProblem(expectedID: 21) == nil, "\(reply.vectorProblem(expectedID: 21) ?? "")")
    }

    // MARK: answers every query

    @Test func everyQuerySentAtOnceIsAnsweredOnceWithItsOwnId() throws {
        let helper = try startEncode(withModel: true)
        defer { helper.stop() }
        let texts = ["a birthday cake with candles", "a city skyline at night", "a sailboat at sunset", "ERR_CONNECTION_RESET",
                     "INV-2026-04417", "Q3-board-deck.pdf", "zq-lantern-4471", "PNR-XJ29KD", "a red sports car",
                     "a field of sunflowers", "tacos on a street food stand", "an elephant in the grassland"]
        let ids = texts.indices.map { 100 + $0 }
        for (index, text) in texts.enumerated() { helper.send(embedLine(id: ids[index], text: text)) }
        var seen: [Int: HelperReply] = [:]
        for _ in texts {
            guard let got = helper.nextLine(timeout: 120) else { break }
            guard let reply = HelperReply(got.text), let id = reply.id else {
                Issue.record("a reply line is not a JSON object with an id: \(got.text.prefix(200))")
                continue
            }
            #expect(seen[id] == nil, "id \(id) was answered twice")
            seen[id] = reply
        }
        #expect(Set(seen.keys) == Set(ids), "answered ids \(seen.keys.sorted()), expected \(ids)")
        for id in ids {
            if let reply = seen[id] { #expect(reply.vectorProblem(expectedID: id) == nil, "id \(id): \(reply.vectorProblem(expectedID: id) ?? "")") }
        }
    }

    // MARK: the 256-entry vector cache

    @Test func the257thDistinctQueryStillAnswersAndARepeatOfARecentOneIsServedFromTheCache() throws {
        let helper = try startEncode(withModel: true)
        defer { helper.stop() }
        func text(_ number: Int) -> String { "cache probe query number \(number) about subject \(number * 7919 % 1009)" }
        var firstVectors: [Int: [Double]] = [:]
        var missSeconds: [Double] = []
        for number in 1...257 {
            let answer = helper.roundTrip(embedLine(id: number, text: text(number)))
            guard let reply = answer.reply else {
                Issue.record("query \(number) of 257 got no JSON reply: \(String(describing: answer.raw)), stderr: \(helper.errors)")
                return
            }
            #expect(reply.vectorProblem(expectedID: number) == nil, "query \(number): \(reply.vectorProblem(expectedID: number) ?? "")")
            firstVectors[number] = reply.vec
            missSeconds.append(answer.seconds)
        }
        let missMedian = median(missSeconds)
        #expect(missMedian.isFinite && missMedian > 0)
        // Repeats of the newest, a middle one and the oldest one still held (entries 2 to 257 fit in 256).
        for number in [257, 130, 2] {
            let answer = helper.roundTrip(embedLine(id: 1000 + number, text: text(number)))
            let reply = try #require(answer.reply, "repeat of query \(number) got no reply")
            #expect(reply.vectorProblem(expectedID: 1000 + number) == nil, "repeat \(number): \(reply.vectorProblem(expectedID: 1000 + number) ?? "")")
            let widest = zip(reply.vec ?? [], firstVectors[number] ?? []).map { abs($0 - $1) }.max() ?? .infinity
            #expect(widest <= 1e-6, "repeat of query \(number) differs by \(widest)")
            #expect(answer.seconds < 0.5 * missMedian,
                    "repeat of query \(number) took \(answer.seconds * 1000) ms, an embed takes a median of \(missMedian * 1000) ms: not served from the cache")
        }
        // The first query was pushed out by the 257th: asking it again is an embed, not a cache hit.
        let evicted = helper.roundTrip(embedLine(id: 2001, text: text(1)))
        let reply = try #require(evicted.reply, "repeat of query 1 got no reply")
        #expect(reply.vectorProblem(expectedID: 2001) == nil, "\(reply.vectorProblem(expectedID: 2001) ?? "")")
        #expect(evicted.seconds >= 0.5 * missMedian,
                "query 1 answered in \(evicted.seconds * 1000) ms after 257 others, median embed \(missMedian * 1000) ms: the cache holds more than 256")
    }

    // MARK: no model

    @Test func aRequestWithNoModelPathGetsARefusedReplyAndNoVector() throws {
        let helper = try startEncode(withModel: false)
        defer { helper.stop() }
        for id in [7, 8] {
            let answer = helper.roundTrip(embedLine(id: id, text: "a dog on the beach"), timeout: 30)
            let reply = try #require(answer.reply, "no JSON reply with no model; got \(String(describing: answer.raw)), stderr: \(helper.errors)")
            #expect(reply.event == "refused", "event is \(String(describing: reply.event)), expected refused")
            #expect(reply.id == id, "id is \(String(describing: reply.id)), expected \(id)")
            #expect(!(reply.reason ?? "").isEmpty, "refused has no reason")
            #expect(reply.object["vec"] == nil, "a refused reply holds a vector")
        }
        let extra = helper.nextLine(timeout: 2)
        #expect(extra == nil, "an extra line came after the refusals: \(String(describing: extra?.text.prefix(200)))")
    }

    // MARK: no network

    @Test func theHelperHoldsNoNetworkConnectionWhileItAnswers() throws {
        let helper = try startEncode(withModel: true)
        defer { helper.stop() }
        let reply = try #require(helper.roundTrip(embedLine(id: 1, text: "a dog on the beach")).reply)
        #expect(reply.vectorProblem(expectedID: 1) == nil, "\(reply.vectorProblem(expectedID: 1) ?? "")")
        let listing = try #require(Tools.capture("/usr/sbin/lsof", ["-a", "-n", "-P", "-i", "-p", String(helper.pid)]),
                                   "lsof could not run")
        #expect(listing.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the helper holds a network connection:\n\(listing.output)")
    }

    // MARK: idle exit

    @Test func theHelperExitsByItselfSixtySecondsAfterItsLastRequest() throws {
        let helper = try startEncode(withModel: true)
        defer { helper.stop() }
        _ = try #require(helper.roundTrip(embedLine(id: 1, text: "a dog on the beach")).reply)
        // Not 60 s after the start: a later request moves the exit 60 s on.
        Thread.sleep(forTimeInterval: 20)
        #expect(helper.isRunning, "the helper exited within 20 s of a request")
        let last = helper.roundTrip(embedLine(id: 2, text: "a sailboat at sunset"))
        let lastReply = try #require(last.reply, "no reply to the second request")
        #expect(lastReply.vectorProblem(expectedID: 2) == nil, "\(lastReply.vectorProblem(expectedID: 2) ?? "")")
        let repliedAt = Date()
        Thread.sleep(forTimeInterval: 30)
        #expect(helper.isRunning, "the helper exited about 30 s after its last request, before 60 s")
        let exit = helper.waitForExit(timeout: 60)
        let gone = try #require(exit, "the helper was still running 90 s after its last request")
        let after = gone.at.timeIntervalSince(repliedAt)
        #expect(gone.status == 0, "idle exit status \(gone.status), expected 0")
        #expect(after >= 55 && after <= 75, "the helper exited \(after) s after its last request, expected 60 s (55 to 75)")
    }
}
}
