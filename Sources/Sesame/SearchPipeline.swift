import Darwin
import Foundation
import SesameEngine

/// One file in a keyword or ranked list: the path and the passage that matched. `SesameEngine.Hit` has no public
/// initializer, so the app keeps its own value for both lists.
struct SearchHit: Equatable, Sendable {
    let path: String
    let passageID: Int64
}

/// Typed text to the lists the panel shows (design section 3, "Searching"). `submit` returns at once. For its ticket
/// it hands out the keyword list (the exact-word match, a few ms), then embeds the text as a query and hands out the
/// ranked list, but only while the ticket is still the newest. Both lists may arrive on any thread. The matrix that
/// `Search` loads is released 60 s after the last search, when a timer calls `tick()`.
final class SearchPipeline: @unchecked Sendable {
    private static let idleSeconds = 60.0
    /// The matrix is rebuilt for new passages at most this often (design section 3: the helper says `changed` per file).
    private static let reloadSeconds = 2.0

    private let search: Search
    private let embedder: any Embedder
    private let visible: @Sendable () -> Visible
    private let now: @Sendable () -> Double
    /// The keyword match runs here and never waits behind an embedding; the ranking runs on `rankQueue`.
    private let keywordQueue = DispatchQueue(label: "sesame.search.keyword", qos: .userInteractive)
    private let rankQueue = DispatchQueue(label: "sesame.search.rank", qos: .userInteractive)

    private let lock = NSLock()
    private var lastSubmit: Double?
    private var newestSubmitted = Int.min
    /// The index helper committed since the matrix was loaded. Only `indexChanged()` sets it; a reload, a release or a
    /// fresh load clears it.
    private var stale = false
    private var lastReloadAt: Double?
    private var reloads = 0
    private var keywordHandler: (@Sendable (Int, [SearchHit]) -> Void)?
    private var rankedHandler: (@Sendable (Int, [SearchHit]) -> Void)?
    private var failedHandler: (@Sendable (Int) -> Void)?

    init(
        search: Search, reader: IndexReader, embedder: any Embedder,
        visible: @escaping @Sendable () -> Visible, now: @escaping @Sendable () -> Double
    ) {
        self.search = search
        self.embedder = embedder
        self.visible = visible
        self.now = now
    }

    var onKeyword: (@Sendable (Int, [SearchHit]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return keywordHandler }
        set { lock.lock(); keywordHandler = newValue; lock.unlock() }
    }

    var onRanked: (@Sendable (Int, [SearchHit]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return rankedHandler }
        set { lock.lock(); rankedHandler = newValue; lock.unlock() }
    }

    /// The embedding of this ticket's text failed (refused, timed out, or the helper died) and no newer text was
    /// submitted since. Called after the keyword list, on any thread.
    var onFailed: (@Sendable (Int) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return failedHandler }
        set { lock.lock(); failedHandler = newValue; lock.unlock() }
    }

    func newTicket() -> Int {
        search.newTicket()
    }

    /// The index helper committed: the next search may reload the matrix. Does no work; callable from any thread.
    func indexChanged() {
        lock.lock()
        stale = true
        lock.unlock()
    }

    /// How many reloads `indexChanged()` caused. The first load and a load after a release are not counted.
    var reloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reloads
    }

    func submit(text: String, ticket: Int) {
        let allowed = visible()
        let at = now()
        lock.lock()
        lastSubmit = at
        newestSubmitted = max(newestSubmitted, ticket)
        let wasStale = stale
        lock.unlock()
        let loaded = wasStale && search.matrixLoaded
        // Stale, loaded, and 2 s since the last reload: drop the matrix so the ranking below loads it fresh. Held
        // back, it stays stale for the next search. Nothing loaded: the fresh load already holds everything written.
        var reload = false
        if wasStale {
            lock.lock()
            if !loaded {
                stale = false
            } else if lastReloadAt.map({ at - $0 >= Self.reloadSeconds }) ?? true {
                stale = false
                lastReloadAt = at
                reloads += 1
                reload = true
            }
            lock.unlock()
        }
        if reload { search.release() }
        let searched = PanelState.cut(text)
        keywordQueue.async { [self] in
            let hits = keywordHits(searched, visible: allowed)
            Probe.emit("keyword", ticket)
            onKeyword?(ticket, hits)
            rankQueue.async { [self] in rank(searched, ticket: ticket, visible: allowed) }
        }
    }

    /// The idle check a timer calls: the matrix goes 60 s after the last search.
    func tick() {
        lock.lock()
        let last = lastSubmit
        lock.unlock()
        guard let last, now() - last >= Self.idleSeconds else { return }
        lock.lock()
        stale = false
        lock.unlock()
        search.release()
    }

    /// The panel's own filter: what `settings.json` says is ticked and switched on, read at each search.
    static func visibleFromSettings() -> Visible {
        let settings = (try? SettingsFile().read()) ?? Settings()
        return Visible(
            folders: settings.folders.filter(\.reading), codeSearchOn: settings.codeSearchOn, kindsOn: settings.kindsOn)
    }

    static func uptimeSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    // MARK: the two lists

    /// Tier 1: `Search.exactHits`, the one definition, so the keyword rows and the front of the ranked list agree.
    private func keywordHits(_ text: String, visible: Visible) -> [SearchHit] {
        search.exactHits(text: text, visible: visible, scope: .plain).map { SearchHit(path: $0.path, passageID: $0.passageID) }
    }

    /// A ticket that a newer submit has passed is not embedded. A failed embedding gives no list; `onFailed` hears of it
    /// once, and only while the ticket is still the newest.
    private func rank(_ text: String, ticket: Int, visible: Visible) {
        lock.lock()
        let passed = ticket < newestSubmitted
        lock.unlock()
        if passed { return }
        guard let vector = try? embedder.embed(text, role: .query) else {
            lock.lock()
            let newest = ticket >= newestSubmitted
            lock.unlock()
            if newest { onFailed?(ticket) }
            return
        }
        guard let hits = search.rank(text: text, vector: vector, ticket: ticket, visible: visible, scope: .plain) else { return }
        Probe.emit("ranked", ticket)
        onRanked?(ticket, hits.map { SearchHit(path: $0.path, passageID: $0.passageID) })
    }
}

// MARK: the embedder bridge

/// Embeds through the `encode` helper: `embed` sends the command through `HelperClient` and waits for the vector
/// event of that id, so it is called off the main thread (the pipeline's rank queue). It is the client's delegate.
final class HelperEmbedder: Embedder, HelperClientDelegate, @unchecked Sendable {
    enum Failure: Error {
        case timedOut
        case refused(String)
        /// The `encode` helper exited without being asked to, or could not be started.
        case helperDied
    }

    private final class Waiter {
        let signal = DispatchSemaphore(value: 0)
        var result: Result<[Float], Failure>?
    }

    private let client: HelperClient
    private let timeout: Double
    private let lock = NSLock()
    private var nextID = 1
    private var waiting: [Int: Waiter] = [:]

    /// `timeout` covers a cold model load.
    init(client: HelperClient, timeout: Double = 20) {
        self.client = client
        self.timeout = timeout
        client.delegate = self
        client.onEncodeExit = { [weak self] exit in
            if exit != .planned { self?.failAll() }
        }
    }

    func embed(_ text: String, role: EmbedRole) throws -> [Float] {
        let waiter = Waiter()
        lock.lock()
        let id = nextID
        nextID += 1
        waiting[id] = waiter
        lock.unlock()
        client.embed(id: id, text: text, role: role)
        _ = waiter.signal.wait(timeout: .now() + timeout)
        lock.lock()
        waiting[id] = nil
        let result = waiter.result
        lock.unlock()
        guard let result else { throw Failure.timedOut }
        return try result.get()
    }

    func helperClient(_ client: HelperClient, didReceive event: HelperEvent) {
        switch event {
        case let .vector(id, _, vec): finish(id, .success(vec))
        case let .refused(id, reason): finish(id, .failure(.refused(reason)))
        default: break
        }
    }

    /// The encode helper is gone: no waiting embed will be answered, so each fails now, not after its timeout.
    private func failAll() {
        lock.lock()
        let all = Array(waiting.values)
        for waiter in all { waiter.result = .failure(.helperDied) }
        lock.unlock()
        for waiter in all { waiter.signal.signal() }
    }

    private func finish(_ id: Int, _ result: Result<[Float], Failure>) {
        lock.lock()
        let waiter = waiting[id]
        waiter?.result = result
        lock.unlock()
        waiter?.signal.signal()
    }
}
