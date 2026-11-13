import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t36, tester step. Written from the t36 entry and the Conventions' Probe paragraph only; no product source
// read. The `Probe.sink` seam records events instead of writing a file, so these tests check that each call site
// fires: `QueryBox` emits `key` once per keystroke with that keystroke's ticket; `SearchPipeline` emits `keyword`
// then `ranked` for the ticket; `Panel` emits `shown` when it is shown (the t10 call, now covered by a test).
//
// SUITE PLACEMENT. `Probe.sink` is a global and so is SESAME_PROBE_FILE, so this suite is nested inside
// `ModelDownloadTests` with the other probe suites and runs one at a time with them. Side effect: `swift test
// --filter ModelDownloadTests` also runs these tests.
//
// API SHAPES these tests pin, besides those of QueryBoxTests.swift and SearchPipelineTests.swift (which this file
// reuses):
//   1. `Probe.sink` is a settable static that takes a closure called with the event name and the ticket of each
//      `Probe.emit(event, ticket)`, `Probe.sink = { event, ticket in ... }`, and is cleared with `Probe.sink = nil`.
//      It may be called on any thread.
//   2. `Panel()` makes the one preallocated panel; `show()` shows it and `hide()` hides it (the t10 names). `shown`
//      carries ticket 0 (the kit's `kit-launch.sh probe` prints `shown 0 <ns>`).
//   3. The pipeline emits `keyword` and `ranked` with the ticket the list belongs to; for a ticket that is stale when
//      its ranking finishes there is no `ranked` event.

private final class PCRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ event: String, _ ticket: Int) { lock.lock(); list.append("\(event):\(ticket)"); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return list }
    func only(ticket: Int) -> [String] { events.filter { $0.hasSuffix(":\(ticket)") } }
}

private final class PCTickets: @unchecked Sendable {
    private let lock = NSLock()
    private var next: Int
    init(start: Int) { next = start }
    func take() -> Int { lock.lock(); defer { lock.unlock() }; next += 1; return next - 1 }
}

// The sink installed for the length of one body, always cleared afterwards, and SESAME_PROBE_FILE made unset so
// nothing else can write.
@MainActor
private func pcRecording(_ body: (PCRecorder) async throws -> Void) async throws {
    let previous = getenv("SESAME_PROBE_FILE").map { String(cString: $0) }
    unsetenv("SESAME_PROBE_FILE")
    let recorder = PCRecorder()
    // @Sendable, so the closure belongs to no actor and may be called from whatever thread emits
    Probe.sink = { @Sendable event, ticket in recorder.add(event, ticket) }
    defer {
        Probe.sink = nil
        if let previous { setenv("SESAME_PROBE_FILE", previous, 1) }
    }
    try await body(recorder)
}

extension ModelDownloadTests {
    @Suite("ProbeCallTests", .serialized)
    struct ProbeCallTests {

        // MARK: the sink seam itself

        @MainActor
        @Test func theSinkRecordsEachEmitAndStopsWhenCleared() async throws {
            try await pcRecording { recorder in
                Probe.emit("hotkey", 0)
                Probe.emit("ranked", 12)
                #expect(recorder.events == ["hotkey:0", "ranked:12"], "recorded: \(recorder.events)")
                Probe.sink = nil
                Probe.emit("key", 3)
                #expect(recorder.events == ["hotkey:0", "ranked:12"], "an event reached a cleared sink")
            }
        }

        // MARK: QueryBox: key, once per keystroke, with that keystroke's ticket

        @MainActor
        @Test func theQueryBoxEmitsOneKeyEventPerKeystrokeWithThatKeystrokesTicket() async throws {
            try await pcRecording { recorder in
                let tickets = PCTickets(start: 900)
                let box = QueryBox(nextTicket: { tickets.take() })
                let seen = PCRecorder()
                box.onChange = { text, ticket in seen.add(text, ticket) }

                box.type("dog")
                #expect(recorder.events == ["key:900", "key:901", "key:902"], "recorded: \(recorder.events)")
                // the ticket on the key event is the ticket the change carries
                #expect(seen.events == ["d:900", "do:901", "dog:902"], "changes: \(seen.events)")

                box.type("s")
                #expect(recorder.events == ["key:900", "key:901", "key:902", "key:903"])
            }
        }

        @MainActor
        @Test func deleteBackwardIsAKeystrokeToo() async throws {
            try await pcRecording { recorder in
                let tickets = PCTickets(start: 50)
                let box = QueryBox(nextTicket: { tickets.take() })
                box.type("ab")
                box.deleteBackward()
                #expect(recorder.events == ["key:50", "key:51", "key:52"], "recorded: \(recorder.events)")
                #expect(box.text == "a")
            }
        }

        @MainActor
        @Test func openingThePanelAndMakingTheBoxEmitsNoKeyEvent() async throws {
            try await pcRecording { recorder in
                let tickets = PCTickets(start: 1)
                let box = QueryBox(nextTicket: { tickets.take() })
                #expect(recorder.events.isEmpty, "making the box emitted \(recorder.events)")
                box.type("a")
                box.clear()
                #expect(recorder.events == ["key:1"], "clear() emitted an event: \(recorder.events)")
            }
        }

        // MARK: SearchPipeline: keyword then ranked for the ticket

        @MainActor
        @Test func thePipelineEmitsKeywordThenRankedForTheTicket() async throws {
            try await pcRecording { recorder in
                try await spWithPipeline(text: spDescription) { h in
                    let ticket = h.submit(spDescription)
                    let arrived = await spEventually { h.log.rankedList(ticket) != nil }
                    #expect(arrived, "no ranked list arrived")
                    await spWait(0.2)
                    #expect(recorder.events == ["keyword:\(ticket)", "ranked:\(ticket)"], "recorded: \(recorder.events)")
                }
            }
        }

        @MainActor
        @Test func eachTicketGetsItsOwnKeywordThenRankedPair() async throws {
            try await pcRecording { recorder in
                try await spWithPipeline(text: spDescription) { h in
                    let first = h.submit(spDescription)
                    _ = await spEventually { h.log.rankedList(first) != nil }
                    let second = h.submit(spDescription)
                    _ = await spEventually { h.log.rankedList(second) != nil }
                    await spWait(0.2)
                    #expect(recorder.only(ticket: first) == ["keyword:\(first)", "ranked:\(first)"], "recorded: \(recorder.events)")
                    #expect(recorder.only(ticket: second) == ["keyword:\(second)", "ranked:\(second)"], "recorded: \(recorder.events)")
                    #expect(recorder.events.count == 4, "recorded: \(recorder.events)")
                }
            }
        }

        @MainActor
        @Test func aStaleTicketEmitsNoRankedEvent() async throws {
            try await pcRecording { recorder in
                try await spWithPipeline(text: spDescription) { h in
                    let older = h.pipeline.newTicket()
                    let newer = h.pipeline.newTicket()
                    h.pipeline.submit(text: spDescription, ticket: older)
                    h.pipeline.submit(text: spDescription, ticket: newer)
                    _ = await spEventually { h.log.rankedList(newer) != nil }
                    await spWait(0.4)
                    #expect(!recorder.events.contains("ranked:\(older)"), "a stale ticket was stamped ranked: \(recorder.events)")
                    #expect(recorder.only(ticket: newer) == ["keyword:\(newer)", "ranked:\(newer)"], "recorded: \(recorder.events)")
                }
            }
        }

        // MARK: Panel: shown

        @MainActor
        @Test func thePanelEmitsShownWithTicketZeroEachTimeItIsShown() async throws {
            _ = NSApplication.shared
            try await pcRecording { recorder in
                let panel = Panel()
                #expect(recorder.events.isEmpty, "making the panel emitted \(recorder.events)")

                panel.show()
                #expect(recorder.events == ["shown:0"], "recorded: \(recorder.events)")
                panel.hide()
                #expect(recorder.events == ["shown:0"], "hiding emitted an event: \(recorder.events)")

                panel.show()
                panel.hide()
                #expect(recorder.events == ["shown:0", "shown:0"], "recorded: \(recorder.events)")
            }
        }
    }
}
