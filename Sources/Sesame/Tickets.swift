import Foundation

/// What Enter does at the moment it is pressed (design section 3, "Searching").
enum EnterDecision: Equatable {
    /// Open the selected file of this ticket's ranked list.
    case open(ticket: Int)
    case nothing
    /// The ranked list did not come in time: the panel shows "Still ranking".
    case stillRanking
}

/// Which ranked list Enter may open: only the list of the text in the box right now. Every keystroke makes its
/// ticket the current one, so a list of any older ticket neither ends a wait nor is ever opened. Enter waits for
/// the current ticket's list for at most `wait` seconds, then does nothing and `stillRankingShown` turns on.
@MainActor
final class TicketGate {
    static let enterWait: Double = 2

    private struct Waiter {
        let ticket: Int
        let resume: CheckedContinuation<EnterDecision, Never>
    }

    private let wait: Double
    private var current: Int?
    private var text = ""
    /// How many files the current ticket's ranked list holds; nil until it is in.
    private var currentCount: Int?
    private var waiters: [UUID: Waiter] = [:]

    /// True from the moment Enter gave up until the next keystroke or until the current ticket's list arrives.
    private(set) var stillRankingShown = false

    init(wait: Double = TicketGate.enterWait) {
        self.wait = wait
    }

    /// The box now holds `text`, and `ticket` is its keystroke. An Enter still waiting was for the old text: it ends
    /// with nothing opened.
    func boxChanged(text: String, ticket: Int) {
        current = ticket
        self.text = text
        currentCount = nil
        stillRankingShown = false
        finishWaiters(with: .nothing, where: { _ in true })
    }

    func rankedListArrived(ticket: Int, count: Int) {
        guard ticket == current else { return }
        currentCount = count
        stillRankingShown = false
        finishWaiters(with: count > 0 ? .open(ticket: ticket) : .nothing, where: { $0 == ticket })
    }

    func pressEnter() async -> EnterDecision {
        guard let ticket = current, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        if let count = currentCount { return count > 0 ? .open(ticket: ticket) : .nothing }
        let id = UUID()
        let limit = wait
        return await withCheckedContinuation { continuation in
            waiters[id] = Waiter(ticket: ticket, resume: continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                self?.timedOut(id)
            }
        }
    }

    private func timedOut(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        stillRankingShown = true
        waiter.resume.resume(returning: .stillRanking)
    }

    private func finishWaiters(with decision: EnterDecision, where matches: (Int) -> Bool) {
        for (id, waiter) in waiters where matches(waiter.ticket) {
            waiters[id] = nil
            waiter.resume.resume(returning: decision)
        }
    }
}
