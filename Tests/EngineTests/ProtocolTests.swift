import Foundation
import Testing
import SesameEngine

// plan-1-t29, tester step. Written from the Helper protocol table of plan-1-tasks.md (Conventions) and the t29
// entry only; no product source read. plan-2-t16 adds the `bench` line (the one line plan 2 adds to the table,
// plan-2-tasks.md Conventions): `HelperEvent.bench(speeds:)`, a `speeds` object of numbers by kind.
//
// Every expected JSON text below is written by hand from the table. The tests compare JSON by meaning (the text is
// parsed first, so key order and spacing do not matter), but a `null` must be present as a key, a boolean must be a
// JSON boolean (not 0 or 1) and a number must be a JSON number (not a string).
//
// API SHAPES these tests pin (the table fixes the lines, not the Swift names; `EmbedRole` is the t23 type with
// `.query` and `.document`). All `public` in SesameEngine, because this file uses `import SesameEngine`, not
// `@testable`. If a shape is wrong, ask for a test change rather than guess.
//   enum HelperCommand: Equatable, Sendable {                      // app to helper, field `cmd`
//       case prewarm
//       case embed(id: Int, text: String, role: EmbedRole)
//       case panel(open: Bool)
//       case folders([HelperFolder])
//       case reset
//       case preview(ticket: Int, file: String, passage: Int?, query: String)
//   }
//   struct HelperFolder: Equatable, Sendable { init(path: String, code: Bool) }
//   enum HelperEvent: Equatable, Sendable {                        // helper to app, field `event`
//       case vector(id: Int, ms: Int, vec: [Float])
//       case refused(id: Int, reason: String)
//       case unit(size: Int)
//       case preview(PreviewReply)
//       case changed
//       case walked
//       case bench(speeds: [String: Double])                          // plan-2-t16: seconds per file, by kind
//   }
//   enum PreviewStatus: Equatable, Sendable { case ok, changed, gone }
//   struct PreviewReply: Equatable, Sendable {
//       init(ticket: Int, status: PreviewStatus, png: String?, name: String, kind: String, size: Int?, mtime: Int?)
//   }
//   enum HelperProtocol {                                           // the encoder and the decoder
//       static func line(for command: HelperCommand) throws -> String     // one line, no newline in it
//       static func line(for event: HelperEvent) throws -> String
//       static func command(from line: String) throws -> HelperCommand    // throws for a line that is not one object
//       static func event(from line: String) throws -> HelperEvent
//   }

// MARK: JSON compared by meaning

private func parsed(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

// A tagged rendering: null, booleans, numbers and strings stay apart, object keys are sorted.
private func canonical(_ value: Any) -> String {
    if value is NSNull { return "null" }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return "bool:\(number.boolValue)" }
        return "num:" + String(format: "%.17g", number.doubleValue)
    }
    if let text = value as? String { return "str:" + String(reflecting: text) }
    if let list = value as? [Any] { return "[" + list.map(canonical).joined(separator: ",") + "]" }
    if let object = value as? [String: Any] {
        return "{" + object.keys.sorted().map { "\($0)=" + canonical(object[$0]!) }.joined(separator: ",") + "}"
    }
    return "?\(value)"
}

private func sameJSON(_ line: String, _ expected: String) throws -> Bool {
    try canonical(parsed(line)) == canonical(parsed(expected))
}

// `{"a":1}` becomes `{"a":1,"zzz":{"nested":[1,null,"x"]}}`: a field the table does not know.
private func withExtraField(_ json: String) -> String {
    String(json.dropLast()) + ",\"zzz\":{\"nested\":[1,null,\"x\"]}}"
}

// MARK: data built by hand

// 768 numbers that a Float holds exactly (k / 16), so the JSON text carries no rounding doubt.
private let vectorNumbers: [Float] = (0..<768).map { Float(($0 * 7) % 33 - 16) / 16 }
private let vectorText: String = vectorNumbers.map { String(Double($0)) }.joined(separator: ",")

private struct CommandCase: Sendable, CustomTestStringConvertible {
    let name: String
    let command: HelperCommand
    let json: String
    var testDescription: String { name }
}

private struct EventCase: Sendable, CustomTestStringConvertible {
    let name: String
    let event: HelperEvent
    let json: String
    var testDescription: String { name }
}

private let commandCases: [CommandCase] = [
    CommandCase(name: "prewarm", command: .prewarm, json: #"{"cmd":"prewarm"}"#),
    CommandCase(name: "embed query", command: .embed(id: 7, text: "a dog on the beach", role: .query),
                json: #"{"cmd":"embed","id":7,"text":"a dog on the beach","role":"query"}"#),
    CommandCase(name: "embed document", command: .embed(id: 8, text: "title: none", role: .document),
                json: #"{"cmd":"embed","id":8,"text":"title: none","role":"document"}"#),
    CommandCase(name: "embed text with a quote, a newline and non-ASCII",
                command: .embed(id: 9, text: "line one\nline \"two\" café 犬", role: .query),
                json: #"{"cmd":"embed","id":9,"text":"line one\nline \"two\" café 犬","role":"query"}"#),
    CommandCase(name: "panel open", command: .panel(open: true), json: #"{"cmd":"panel","open":true}"#),
    CommandCase(name: "panel closed", command: .panel(open: false), json: #"{"cmd":"panel","open":false}"#),
    CommandCase(name: "folders with two entries",
                command: .folders([HelperFolder(path: "/Users/me/Pictures", code: false),
                                   HelperFolder(path: "/Users/me/Developer/app", code: true)]),
                json: #"{"cmd":"folders","folders":[{"path":"/Users/me/Pictures","code":false},{"path":"/Users/me/Developer/app","code":true}]}"#),
    CommandCase(name: "folders with one entry",
                command: .folders([HelperFolder(path: "/Users/me/Pictures", code: false)]),
                json: #"{"cmd":"folders","folders":[{"path":"/Users/me/Pictures","code":false}]}"#),
    CommandCase(name: "folders with the empty list", command: .folders([]),
                json: #"{"cmd":"folders","folders":[]}"#),
    CommandCase(name: "reset", command: .reset, json: #"{"cmd":"reset"}"#),
    CommandCase(name: "preview with passage null",
                command: .preview(ticket: 12, file: "/Users/me/Pictures/beach-dog.jpg", passage: nil,
                                  query: "a dog on the beach"),
                json: #"{"cmd":"preview","ticket":12,"file":"/Users/me/Pictures/beach-dog.jpg","passage":null,"query":"a dog on the beach"}"#),
    CommandCase(name: "preview with a passage id",
                command: .preview(ticket: 13, file: "/Users/me/Pictures/beach-dog.jpg", passage: 345,
                                  query: "a dog on the beach"),
                json: #"{"cmd":"preview","ticket":13,"file":"/Users/me/Pictures/beach-dog.jpg","passage":345,"query":"a dog on the beach"}"#),
]

private let previewPath = "/var/folders/ab/cdef/T/Sesame-4242/p1.png"

private let eventCases: [EventCase] = [
    EventCase(name: "changed", event: .changed, json: #"{"event":"changed"}"#),
    EventCase(name: "walked", event: .walked, json: #"{"event":"walked"}"#),
    EventCase(name: "unit size 4", event: .unit(size: 4), json: #"{"event":"unit","size":4}"#),
    EventCase(name: "unit size 16", event: .unit(size: 16), json: #"{"event":"unit","size":16}"#),
    EventCase(name: "vector with ms and 768 numbers", event: .vector(id: 7, ms: 23, vec: vectorNumbers),
              json: #"{"event":"vector","id":7,"ms":23,"vec":["# + vectorText + #"]}"#),
    EventCase(name: "refused", event: .refused(id: 7, reason: "no model path was given"),
              json: #"{"event":"refused","id":7,"reason":"no model path was given"}"#),
    // plan-2-t16: the one line plan 2 adds, `bench`, written by hand from the Conventions of plan-2-tasks.md.
    EventCase(name: "bench with a photo speed", event: .bench(speeds: ["photo": 0.31]),
              json: #"{"event":"bench","speeds":{"photo":0.31}}"#),
    EventCase(name: "preview reply ok",
              event: .preview(PreviewReply(ticket: 12, status: .ok, png: previewPath, name: "beach-dog.jpg",
                                           kind: "photo", size: 48213, mtime: 1_760_000_000)),
              json: #"{"event":"preview","ticket":12,"status":"ok","png":""# + previewPath
                  + #"","name":"beach-dog.jpg","kind":"photo","size":48213,"mtime":1760000000}"#),
    EventCase(name: "preview reply changed",
              event: .preview(PreviewReply(ticket: 14, status: .changed, png: previewPath, name: "beach-dog.jpg",
                                           kind: "photo", size: 51000, mtime: 1_760_000_500)),
              json: #"{"event":"preview","ticket":14,"status":"changed","png":""# + previewPath
                  + #"","name":"beach-dog.jpg","kind":"photo","size":51000,"mtime":1760000500}"#),
    EventCase(name: "preview reply gone (png, size and mtime null)",
              event: .preview(PreviewReply(ticket: 15, status: .gone, png: nil, name: "beach-dog.jpg",
                                           kind: "photo", size: nil, mtime: nil)),
              json: #"{"event":"preview","ticket":15,"status":"gone","png":null,"name":"beach-dog.jpg","kind":"photo","size":null,"mtime":null}"#),
]

// Lines that are not one JSON object per line. Both decoders must refuse every one.
private let badLines: [String] = [
    "",
    "   ",
    "not json",
    "prewarm",
    "42",
    "null",
    "true",
    #""prewarm""#,
    "[1,2,3]",
    #"[{"cmd":"reset"}]"#,
    #"{"cmd":"prewarm""#,                      // cut off
    #"{"cmd":"reset"} trailing"#,              // text after the object
    #"{"cmd":"reset"}{"cmd":"reset"}"#,        // two objects on one line
    "{\"cmd\":\"reset\"}\n{\"cmd\":\"reset\"}", // two lines
    #"{"event":"changed"}{"event":"walked"}"#,
    "{\"event\":\"changed\"}\n{\"event\":\"walked\"}",
]

// plan-2-t16: `bench` lines that must be refused: no `speeds` object, or a value in it that is not a number.
private let badBenchLines: [String] = [
    #"{"event":"bench"}"#,
    #"{"event":"bench","speed":{"photo":0.31}}"#,           // the key is `speeds`
    #"{"event":"bench","speeds":null}"#,
    #"{"event":"bench","speeds":"0.31"}"#,
    #"{"event":"bench","speeds":0.31}"#,
    #"{"event":"bench","speeds":[0.31]}"#,
    #"{"event":"bench","speeds":{"photo":"0.31"}}"#,
    #"{"event":"bench","speeds":{"photo":null}}"#,
    #"{"event":"bench","speeds":{"photo":true}}"#,
    #"{"event":"bench","speeds":{"photo":[0.31]}}"#,
    #"{"event":"bench","speeds":{"photo":{"seconds":0.31}}}"#,
]

// MARK: the table, as code

@Suite("ProtocolTests")
struct ProtocolTests {

    // MARK: commands, app to helper

    @Test(arguments: commandCases)
    fileprivate func aCommandEncodesToTheTableLine(_ item: CommandCase) throws {
        let line = try HelperProtocol.line(for: item.command)
        #expect(!line.contains("\n"), "a line must not hold a newline: \(line)")
        #expect(try sameJSON(line, item.json), "\(item.name): got \(line), want \(item.json)")
    }

    @Test(arguments: commandCases)
    fileprivate func aCommandDecodesFromTheTableLine(_ item: CommandCase) throws {
        #expect(try HelperProtocol.command(from: item.json) == item.command)
    }

    @Test(arguments: commandCases)
    fileprivate func aCommandRoundTripsThroughTheEncoderAndTheDecoder(_ item: CommandCase) throws {
        let line = try HelperProtocol.line(for: item.command)
        #expect(try HelperProtocol.command(from: line) == item.command)
    }

    @Test(arguments: commandCases)
    fileprivate func aCommandWithAnUnknownExtraFieldIsStillRead(_ item: CommandCase) throws {
        #expect(try HelperProtocol.command(from: withExtraField(item.json)) == item.command)
    }

    @Test(arguments: badLines)
    fileprivate func aCommandLineThatIsNotOneObjectIsRefused(_ line: String) {
        #expect(throws: (any Error).self) { try HelperProtocol.command(from: line) }
    }

    // MARK: events, helper to app

    @Test(arguments: eventCases)
    fileprivate func anEventEncodesToTheTableLine(_ item: EventCase) throws {
        let line = try HelperProtocol.line(for: item.event)
        #expect(!line.contains("\n"), "a line must not hold a newline")
        #expect(try sameJSON(line, item.json), "\(item.name): got \(line.prefix(300)), want \(item.json.prefix(300))")
    }

    @Test(arguments: eventCases)
    fileprivate func anEventDecodesFromTheTableLine(_ item: EventCase) throws {
        #expect(try HelperProtocol.event(from: item.json) == item.event)
    }

    @Test(arguments: eventCases)
    fileprivate func anEventRoundTripsThroughTheEncoderAndTheDecoder(_ item: EventCase) throws {
        let line = try HelperProtocol.line(for: item.event)
        #expect(try HelperProtocol.event(from: line) == item.event)
    }

    @Test(arguments: eventCases)
    fileprivate func anEventWithAnUnknownExtraFieldIsStillRead(_ item: EventCase) throws {
        #expect(try HelperProtocol.event(from: withExtraField(item.json)) == item.event)
    }

    @Test(arguments: badLines)
    fileprivate func anEventLineThatIsNotOneObjectIsRefused(_ line: String) {
        #expect(throws: (any Error).self) { try HelperProtocol.event(from: line) }
    }

    // MARK: the bench line (plan-2-t16)

    @Test(arguments: badBenchLines)
    fileprivate func aBenchLineWithNoSpeedsObjectOrANonNumberValueIsRefused(_ line: String) {
        #expect(throws: (any Error).self) { try HelperProtocol.event(from: line) }
    }

    @Test func theBenchEventEncodesWithAJSONNumberUnderTheEventAndSpeedsKeys() throws {
        let line = try HelperProtocol.line(for: .bench(speeds: ["photo": 0.31]))
        let object = try #require(try parsed(line) as? [String: Any])
        #expect(object["event"] as? String == "bench")
        let speeds = try #require(object["speeds"] as? [String: Any])
        #expect(Set(speeds.keys) == ["photo"])
        let photo = try #require(speeds["photo"] as? NSNumber)
        #expect(CFGetTypeID(photo) != CFBooleanGetTypeID())
        #expect(photo.doubleValue == 0.31)
    }

    // MARK: the vector line in particular

    @Test func theVectorLineKeepsAll768NumbersInOrder() throws {
        let line = try HelperProtocol.line(for: .vector(id: 1, ms: 5, vec: vectorNumbers))
        let object = try #require(try parsed(line) as? [String: Any])
        let numbers = try #require(object["vec"] as? [NSNumber])
        #expect(numbers.count == 768)
        #expect(numbers.map { Float(truncating: $0) } == vectorNumbers)
        #expect(object["event"] as? String == "vector")
        #expect((object["ms"] as? NSNumber)?.intValue == 5)
    }

    // MARK: plan-5-t4, `PreviewReply.seconds`
    //
    // Written from the entry plan-5-t4 of plan-5-tasks.md: `seconds: Int?` is the spot in whole seconds, absent for photo, PDF and document
    // replies and encoded only when set; every earlier line is byte for byte unchanged and `seconds` round-trips. The sealed cases above are
    // not amended. SHAPES PINNED that the entry did not fix: `seconds` is the last label of the initialiser after `text` (these cases never
    // pass `marks:` with it); the wire key is `seconds`, a JSON number, written for 0 as well (0 is "set": a changed file shows its start);
    // a line is written by the same encoder every time, with its keys in one order, so the line of a reply with `seconds` is the line
    // without it plus the one key.

    private static let earlierReplies: [(name: String, plain: PreviewReply, withSeconds: PreviewReply)] = [
        ("photo",
         PreviewReply(ticket: 31, status: .ok, png: previewPath, name: "beach-dog.jpg", kind: "photo", size: 48213, mtime: 1_760_000_000),
         PreviewReply(ticket: 31, status: .ok, png: previewPath, name: "beach-dog.jpg", kind: "photo", size: 48213, mtime: 1_760_000_000, seconds: 130)),
        ("pdf",
         PreviewReply(ticket: 32, status: .ok, png: previewPath, name: "lease.pdf", kind: "pdf", size: 9001, mtime: 1_760_000_100,
                      page: 7, pageCount: 12, locator: "Page 7 of 12"),
         PreviewReply(ticket: 32, status: .ok, png: previewPath, name: "lease.pdf", kind: "pdf", size: 9001, mtime: 1_760_000_100,
                      page: 7, pageCount: 12, locator: "Page 7 of 12", seconds: 130)),
        ("document",
         PreviewReply(ticket: 33, status: .ok, png: nil, name: "tenancy.docx", kind: "doc", size: 9001, mtime: 1_760_000_200,
                      text: "One cat is allowed with written landlord consent"),
         PreviewReply(ticket: 33, status: .ok, png: nil, name: "tenancy.docx", kind: "doc", size: 9001, mtime: 1_760_000_200,
                      text: "One cat is allowed with written landlord consent", seconds: 130)),
        ("gone",
         PreviewReply(ticket: 34, status: .gone, png: nil, name: "beach-dog.jpg", kind: "photo", size: nil, mtime: nil),
         PreviewReply(ticket: 34, status: .gone, png: nil, name: "beach-dog.jpg", kind: "photo", size: nil, mtime: nil, seconds: 130)),
    ]

    private static func audioReply(seconds: Int?) -> PreviewReply {
        guard let seconds else {
            return PreviewReply(ticket: 41, status: .ok, png: previewPath, name: "sleep-interview.m4a", kind: "audio", size: 5_123_456,
                                mtime: 1_760_000_300, locator: "Opens at 02:10", text: "the words of the sentence")
        }
        return PreviewReply(ticket: 41, status: .ok, png: previewPath, name: "sleep-interview.m4a", kind: "audio", size: 5_123_456,
                            mtime: 1_760_000_300, locator: "Opens at 02:10", text: "the words of the sentence", seconds: seconds)
    }

    private static func previewLine(_ reply: PreviewReply) throws -> String { try HelperProtocol.line(for: .preview(reply)) }

    private static func decodedReply(_ line: String) throws -> PreviewReply {
        guard case let .preview(reply) = try HelperProtocol.event(from: line) else { throw ProtocolSecondsError("not a preview event: \(line)") }
        return reply
    }

    @Test func aReplyWithNoSecondsEncodesNoSecondsKeyWhateverTheKindOfTheEarlierReply() throws {
        for item in Self.earlierReplies {
            let line = try Self.previewLine(item.plain)
            #expect(!line.contains("seconds"), "\(item.name): a reply with no seconds has the word `seconds` in its line: \(line)")
            let object = try #require(try parsed(line) as? [String: Any])
            #expect(object["seconds"] == nil, "\(item.name): the key `seconds` is present (as \(String(describing: object["seconds"]))) in a line of a reply with none")
        }
        let audioLine = try Self.previewLine(Self.audioReply(seconds: nil))
        #expect(!audioLine.contains("seconds"), "an audio reply with no seconds has the word `seconds` in its line: \(audioLine)")
    }

    @Test func aReplyWithSecondsIsTheEarlierLineByteForBytePlusTheOneKey() throws {
        for item in Self.earlierReplies {
            let plain = try Self.previewLine(item.plain)
            let set = try Self.previewLine(item.withSeconds)
            let afterComma = set.replacingOccurrences(of: ",\"seconds\":130", with: "")
            let beforeComma = set.replacingOccurrences(of: "\"seconds\":130,", with: "")
            #expect(set.contains("\"seconds\":130"), "\(item.name): the line holds no `\"seconds\":130`: \(set)")
            #expect(afterComma == plain || beforeComma == plain,
                    "\(item.name): the line with seconds is not the earlier line plus one key (an earlier byte moved or changed).\nearlier: \(plain)\nwith seconds: \(set)")
            let object = try #require(try parsed(set) as? [String: Any])
            var without = object
            without["seconds"] = nil
            let earlier = try #require(try parsed(plain) as? [String: Any])
            #expect(canonical(without) == canonical(earlier), "\(item.name): the other keys differ once `seconds` is removed")
        }
    }

    @Test func secondsIsAJSONNumberAndZeroIsWrittenToo() throws {
        for value in [130, 0, 4500] {
            let line = try Self.previewLine(Self.audioReply(seconds: value))
            let object = try #require(try parsed(line) as? [String: Any])
            let number = try #require(object["seconds"] as? NSNumber, "seconds \(value): the key is missing or not a number in \(line)")
            #expect(CFGetTypeID(number) != CFBooleanGetTypeID(), "seconds \(value) is written as a boolean")
            #expect(number.intValue == value && number.doubleValue == Double(value), "seconds \(value) is written as \(number)")
            #expect(object["event"] as? String == "preview")
            #expect(object["kind"] as? String == "audio")
        }
    }

    @Test func secondsRoundTripsThroughTheEncoderAndTheDecoder() throws {
        for value in [130, 0, 4500] {
            let reply = Self.audioReply(seconds: value)
            let back = try Self.decodedReply(Self.previewLine(reply))
            #expect(back == reply, "seconds \(value): the decoded reply differs from the one encoded")
            #expect(back.seconds == value, "seconds \(value) came back as \(String(describing: back.seconds))")
        }
        let none = Self.audioReply(seconds: nil)
        let back = try Self.decodedReply(Self.previewLine(none))
        #expect(back == none && back.seconds == nil, "a reply with no seconds came back with \(String(describing: back.seconds))")
        for item in Self.earlierReplies {
            let decoded = try Self.decodedReply(Self.previewLine(item.plain))
            #expect(decoded == item.plain && decoded.seconds == nil, "\(item.name): an earlier reply decodes with seconds \(String(describing: decoded.seconds))")
        }
    }

    @Test func anEarlierLineWithTheKeyAppendedDecodesToTheSameReplyWithSeconds() throws {
        for item in Self.earlierReplies {
            let plain = try Self.previewLine(item.plain)
            let appended = String(plain.dropLast()) + ",\"seconds\":130}"
            let decoded = try Self.decodedReply(appended)
            #expect(decoded == item.withSeconds, "\(item.name): the hand-appended line decodes to a different reply (seconds \(String(describing: decoded.seconds)))")
            #expect(decoded.seconds == 130)
            #expect(try Self.decodedReply(plain).seconds == nil, "\(item.name): the earlier line decodes with seconds")
        }
    }
}

private struct ProtocolSecondsError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: plan-6-t7, `PreviewReply.line` and `PreviewReply.firstLine`
//
// Written from the entry plan-6-t7 of plan-6-tasks.md (Tests, `ProtocolTests` extended) and Decision D12: `PreviewReply` gains `line: Int?`
// (the match line's number in the file) and `firstLine: Int?` (the number of the first line shown), each encoded only when set, so every
// earlier reply line is byte for byte unchanged, and both round-trip. The sealed cases above are not amended. SHAPES PINNED that the entry
// did not fix: the wire keys are `line` and `firstLine`, JSON numbers; `line` and `firstLine` are the last two labels of the initialiser,
// in that order, after `seconds` (so a reply that sets `seconds` and `line` passes `seconds:` first); a line is written by the same encoder
// every time, so the line of a reply with the new keys is the line without them plus those keys (checked wherever the encoder puts them).

private struct ProtocolLineError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func plLine(_ reply: PreviewReply) throws -> String { try HelperProtocol.line(for: .preview(reply)) }

private func plDecoded(_ line: String) throws -> PreviewReply {
    guard case let .preview(reply) = try HelperProtocol.event(from: line) else { throw ProtocolLineError("not a preview event: \(line)") }
    return reply
}

/// `line` with the one member `"key":value` taken out, wherever the encoder put it (after a comma, or first with one after it).
private func plWithout(_ line: String, key: String, value: Int) -> String {
    let member = "\"\(key)\":\(value)"
    if line.contains("," + member) { return line.replacingOccurrences(of: "," + member, with: "") }
    return line.replacingOccurrences(of: member + ",", with: "")
}

private let plCodeText = "func retryWithBackoff() {\n    return\n}"

private let plEarlier: [(name: String, plain: PreviewReply, withLine: PreviewReply, withFirst: PreviewReply, withBoth: PreviewReply)] = [
    ("photo",
     PreviewReply(ticket: 51, status: .ok, png: previewPath, name: "beach-dog.jpg", kind: "photo", size: 48213, mtime: 1_760_000_000),
     PreviewReply(ticket: 51, status: .ok, png: previewPath, name: "beach-dog.jpg", kind: "photo", size: 48213, mtime: 1_760_000_000, line: 12),
     PreviewReply(ticket: 51, status: .ok, png: previewPath, name: "beach-dog.jpg", kind: "photo", size: 48213, mtime: 1_760_000_000, firstLine: 5),
     PreviewReply(ticket: 51, status: .ok, png: previewPath, name: "beach-dog.jpg", kind: "photo", size: 48213, mtime: 1_760_000_000, line: 12, firstLine: 5)),
    ("pdf",
     PreviewReply(ticket: 52, status: .ok, png: previewPath, name: "lease.pdf", kind: "pdf", size: 9001, mtime: 1_760_000_100,
                  page: 7, pageCount: 12, locator: "Page 7 of 12"),
     PreviewReply(ticket: 52, status: .ok, png: previewPath, name: "lease.pdf", kind: "pdf", size: 9001, mtime: 1_760_000_100,
                  page: 7, pageCount: 12, locator: "Page 7 of 12", line: 12),
     PreviewReply(ticket: 52, status: .ok, png: previewPath, name: "lease.pdf", kind: "pdf", size: 9001, mtime: 1_760_000_100,
                  page: 7, pageCount: 12, locator: "Page 7 of 12", firstLine: 5),
     PreviewReply(ticket: 52, status: .ok, png: previewPath, name: "lease.pdf", kind: "pdf", size: 9001, mtime: 1_760_000_100,
                  page: 7, pageCount: 12, locator: "Page 7 of 12", line: 12, firstLine: 5)),
    ("doc",
     PreviewReply(ticket: 53, status: .changed, png: nil, name: "tenancy.docx", kind: "doc", size: 9001, mtime: 1_760_000_200,
                  text: "One cat is allowed", marks: [4, 7]),
     PreviewReply(ticket: 53, status: .changed, png: nil, name: "tenancy.docx", kind: "doc", size: 9001, mtime: 1_760_000_200,
                  text: "One cat is allowed", marks: [4, 7], line: 12),
     PreviewReply(ticket: 53, status: .changed, png: nil, name: "tenancy.docx", kind: "doc", size: 9001, mtime: 1_760_000_200,
                  text: "One cat is allowed", marks: [4, 7], firstLine: 5),
     PreviewReply(ticket: 53, status: .changed, png: nil, name: "tenancy.docx", kind: "doc", size: 9001, mtime: 1_760_000_200,
                  text: "One cat is allowed", marks: [4, 7], line: 12, firstLine: 5)),
    ("audio",
     PreviewReply(ticket: 54, status: .ok, png: previewPath, name: "sleep.m4a", kind: "audio", size: 5_123_456, mtime: 1_760_000_300,
                  locator: "Opens at 02:10", text: "the words", seconds: 130),
     PreviewReply(ticket: 54, status: .ok, png: previewPath, name: "sleep.m4a", kind: "audio", size: 5_123_456, mtime: 1_760_000_300,
                  locator: "Opens at 02:10", text: "the words", seconds: 130, line: 12),
     PreviewReply(ticket: 54, status: .ok, png: previewPath, name: "sleep.m4a", kind: "audio", size: 5_123_456, mtime: 1_760_000_300,
                  locator: "Opens at 02:10", text: "the words", seconds: 130, firstLine: 5),
     PreviewReply(ticket: 54, status: .ok, png: previewPath, name: "sleep.m4a", kind: "audio", size: 5_123_456, mtime: 1_760_000_300,
                  locator: "Opens at 02:10", text: "the words", seconds: 130, line: 12, firstLine: 5)),
    ("gone",
     PreviewReply(ticket: 55, status: .gone, png: nil, name: "beach-dog.jpg", kind: "photo", size: nil, mtime: nil),
     PreviewReply(ticket: 55, status: .gone, png: nil, name: "beach-dog.jpg", kind: "photo", size: nil, mtime: nil, line: 12),
     PreviewReply(ticket: 55, status: .gone, png: nil, name: "beach-dog.jpg", kind: "photo", size: nil, mtime: nil, firstLine: 5),
     PreviewReply(ticket: 55, status: .gone, png: nil, name: "beach-dog.jpg", kind: "photo", size: nil, mtime: nil, line: 12, firstLine: 5)),
]

private func plCodeReply(line: Int?, firstLine: Int?, status: PreviewStatus = .ok) -> PreviewReply {
    PreviewReply(ticket: 61, status: status, png: nil, name: "retry.swift", kind: "code", size: 412, mtime: 1_760_000_400,
                 locator: "Lines 3 to 5", text: plCodeText, marks: [0, 25], line: line, firstLine: firstLine)
}

@Suite("ProtocolCodeLineTests")
struct ProtocolCodeLineTests {

    @Test func aReplyWithNoLineAndNoFirstLineEncodesNeitherKeyWhateverTheKindOfTheEarlierReply() throws {
        for item in plEarlier {
            let line = try plLine(item.plain)
            let object = try #require(try parsed(line) as? [String: Any])
            #expect(object["line"] == nil && object["firstLine"] == nil, "\(item.name): the keys `line` or `firstLine` are present in a line of a reply with none: \(line)")
            #expect(!line.contains("\"line\"") && !line.contains("\"firstLine\""), "\(item.name): a new key is in the line: \(line)")
        }
        let none = try plLine(plCodeReply(line: nil, firstLine: nil))
        let object = try #require(try parsed(none) as? [String: Any])
        #expect(object["line"] == nil && object["firstLine"] == nil, "a code reply with neither: \(none)")
    }

    @Test func eachNewKeyIsEncodedOnlyWhenItIsSet() throws {
        let onlyLine = try plLine(plCodeReply(line: 12, firstLine: nil))
        let a = try #require(try parsed(onlyLine) as? [String: Any])
        #expect((a["line"] as? NSNumber)?.intValue == 12 && a["firstLine"] == nil, "only `line` set: \(onlyLine)")
        let onlyFirst = try plLine(plCodeReply(line: nil, firstLine: 5))
        let b = try #require(try parsed(onlyFirst) as? [String: Any])
        #expect((b["firstLine"] as? NSNumber)?.intValue == 5 && b["line"] == nil, "only `firstLine` set: \(onlyFirst)")
        #expect(!onlyLine.contains("\"firstLine\":null") && !onlyFirst.contains("\"line\":null"), "a key that is not set is written as null: \(onlyLine) / \(onlyFirst)")
    }

    @Test func aLineWithTheNewKeysIsTheEarlierLinePlusThoseKeysByteForByte() throws {
        for item in plEarlier {
            let plain = try plLine(item.plain)
            let withLine = try plLine(item.withLine)
            #expect(withLine.contains("\"line\":12"), "\(item.name): the line holds no `\"line\":12`: \(withLine)")
            #expect(plWithout(withLine, key: "line", value: 12) == plain, "\(item.name): with `line` the line is not the earlier line plus one key.\nearlier: \(plain)\nwith line: \(withLine)")
            let withFirst = try plLine(item.withFirst)
            #expect(withFirst.contains("\"firstLine\":5"), "\(item.name): the line holds no `\"firstLine\":5`: \(withFirst)")
            #expect(plWithout(withFirst, key: "firstLine", value: 5) == plain, "\(item.name): with `firstLine` the line is not the earlier line plus one key.\nearlier: \(plain)\nwith firstLine: \(withFirst)")
            let withBoth = try plLine(item.withBoth)
            let stripped = plWithout(plWithout(withBoth, key: "line", value: 12), key: "firstLine", value: 5)
            #expect(stripped == plain, "\(item.name): with both keys the line is not the earlier line plus two keys.\nearlier: \(plain)\nwith both: \(withBoth)")
        }
    }

    @Test func lineAndFirstLineAreJSONNumbersAndSurviveTheEncoderAndTheDecoder() throws {
        for (line, first) in [(12, 5), (1, 1), (1_000_000, 999_990), (40, 12)] {
            let reply = plCodeReply(line: line, firstLine: first)
            let encoded = try plLine(reply)
            let object = try #require(try parsed(encoded) as? [String: Any])
            let lineNumber = try #require(object["line"] as? NSNumber, "line \(line): the key is missing or not a number in \(encoded)")
            let firstNumber = try #require(object["firstLine"] as? NSNumber, "firstLine \(first): the key is missing or not a number in \(encoded)")
            #expect(CFGetTypeID(lineNumber) != CFBooleanGetTypeID() && CFGetTypeID(firstNumber) != CFBooleanGetTypeID())
            #expect(lineNumber.intValue == line && firstNumber.intValue == first, "line \(line), firstLine \(first): written as \(lineNumber), \(firstNumber)")
            let back = try plDecoded(encoded)
            #expect(back == reply, "line \(line), firstLine \(first): the decoded reply differs from the one encoded")
            #expect(back.line == line && back.firstLine == first, "came back as \(String(describing: back.line)), \(String(describing: back.firstLine))")
        }
        for (line, first) in [(12, nil), (nil, 5)] as [(Int?, Int?)] {
            let reply = plCodeReply(line: line, firstLine: first)
            let back = try plDecoded(try plLine(reply))
            #expect(back == reply && back.line == line && back.firstLine == first, "line \(String(describing: line)), firstLine \(String(describing: first)) came back as \(String(describing: back.line)), \(String(describing: back.firstLine))")
        }
        let none = plCodeReply(line: nil, firstLine: nil)
        let back = try plDecoded(try plLine(none))
        #expect(back == none && back.line == nil && back.firstLine == nil, "a reply with neither came back with \(String(describing: back.line)), \(String(describing: back.firstLine))")
        for item in plEarlier {
            let decoded = try plDecoded(try plLine(item.plain))
            #expect(decoded == item.plain && decoded.line == nil && decoded.firstLine == nil, "\(item.name): an earlier reply decodes with a line number")
            let both = try plDecoded(try plLine(item.withBoth))
            #expect(both == item.withBoth && both.line == 12 && both.firstLine == 5, "\(item.name): the reply with both does not survive the encoder and the decoder")
        }
    }

    @Test func aCodeReplyKeepsItsTextMarksAndLocatorBesideTheNewKeys() throws {
        let reply = plCodeReply(line: 4, firstLine: 3)
        let encoded = try plLine(reply)
        #expect(!encoded.contains("\n"), "a line must not hold a newline: \(encoded)")
        let object = try #require(try parsed(encoded) as? [String: Any])
        #expect(object["kind"] as? String == "code" && object["locator"] as? String == "Lines 3 to 5" && object["text"] as? String == plCodeText)
        #expect((object["marks"] as? [NSNumber])?.map { $0.intValue } == [0, 25], "marks are \(String(describing: object["marks"]))")
        #expect(object["page"] == nil && object["pageCount"] == nil && object["seconds"] == nil, "a code line holds a key of another kind: \(encoded)")
        #expect(try plDecoded(encoded) == reply)
    }

    @Test func anEarlierLineWithTheKeysAppendedInEitherOrderDecodesToTheSameReplyWithThem() throws {
        for item in plEarlier {
            let plain = try plLine(item.plain)
            let appended = String(plain.dropLast()) + ",\"line\":12,\"firstLine\":5}"
            let swapped = String(plain.dropLast()) + ",\"firstLine\":5,\"line\":12}"
            for (label, text) in [("line then firstLine", appended), ("firstLine then line", swapped)] {
                let decoded = try plDecoded(text)
                #expect(decoded == item.withBoth, "\(item.name), \(label): the hand-appended line decodes to a different reply (line \(String(describing: decoded.line)), firstLine \(String(describing: decoded.firstLine)))")
            }
            let one = try plDecoded(String(plain.dropLast()) + ",\"line\":12}")
            #expect(one == item.withLine && one.firstLine == nil, "\(item.name): a line with only `line` decodes wrongly")
            let other = try plDecoded(String(plain.dropLast()) + ",\"firstLine\":5}")
            #expect(other == item.withFirst && other.line == nil, "\(item.name): a line with only `firstLine` decodes wrongly")
            #expect(try plDecoded(plain).line == nil, "\(item.name): the earlier line decodes with a line number")
        }
    }
}
