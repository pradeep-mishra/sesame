import Foundation
import SesameEngine

/// Notices a model file that was replaced, truncated or flipped (design sections 2 and 7). At `start()`, and
/// whenever a 5 s poll sees the size, modified time or inode of a file under `models/` change, it hashes
/// every file again. (No vnode watch on the folder: opening it is a `file-open-parse` hit of check-static
/// outside the allowlist, and the poll alone meets the 15 s bound.) a file under its real name that is not whole is deleted
/// through `SesameFolder`, `onMessage` gets the one fixed message, and `ModelDownload` fetches it again. A
/// whole file is left alone, whatever its time or inode. When that fetch fails (its own second try included)
/// the watcher fetches nothing more until `retry()`, and `onFailure` gets the failure text once. When a fetch ends with
/// the model whole, `onFetched` is called, so the app can see the model become whole with no window open.
/// What `ModelRecovery` needs of the watcher: whether it waits for a Retry, and the Retry itself.
protocol ModelWatching: AnyObject {
    var needsRetry: Bool { get }
    func retry()
}

final class ModelWatcher: ModelWatching, @unchecked Sendable {
    static let pollInterval: TimeInterval = 5
    static let damagedMessage = "The model file was damaged, so it was deleted. Downloading it again."

    private enum Event { case look, retry }

    private struct Stamp: Equatable {
        let size: Int
        let modified: Date
        let inode: Int
    }

    private let files: [ModelFile]
    private let onMessage: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let onFetched: @Sendable () -> Void

    /// Covers everything below; the worker task never holds it across an await.
    private let lock = NSLock()
    private var worker: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var events: AsyncStream<Event>.Continuation?
    private var finished: DispatchSemaphore?
    private var waitingForRetry = false

    init(
        files: [ModelFile] = ModelFiles.all, onMessage: @escaping @Sendable (String) -> Void = { _ in },
        onFailure: @escaping @Sendable (String) -> Void = { _ in },
        onFetched: @escaping @Sendable () -> Void = {}
    ) {
        self.files = files
        self.onMessage = onMessage
        self.onFailure = onFailure
        self.onFetched = onFetched
    }

    /// True from the moment the watcher gives up on a fetch until `retry()` is called.
    var needsRetry: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waitingForRetry
    }

    /// Returns at once; the launch re-hash and the watch run in the background.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard worker == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let done = DispatchSemaphore(value: 0)
        events = continuation
        finished = done
        poller = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000)) } catch { return }
                continuation.yield(.look)
            }
        }
        worker = Task.detached(priority: .utility) { [self] in
            defer { done.signal() }
            await run(stream)
        }
    }

    /// Starts one new fetch of whatever is not whole, and clears `needsRetry`.
    func retry() {
        lock.lock()
        defer { lock.unlock() }
        waitingForRetry = false
        events?.yield(.retry)
    }

    /// Ends the watch and cancels a fetch it started; waits (at most 5 s) for the worker to finish, so that
    /// afterwards no file is written or deleted.
    func stop() {
        lock.lock()
        let (task, ticker, continuation, done) = (worker, poller, events, finished)
        (worker, poller, events, finished) = (nil, nil, nil, nil)
        lock.unlock()
        continuation?.finish()
        ticker?.cancel()
        task?.cancel()
        _ = done?.wait(timeout: .now() + 5)
    }

    // MARK: the worker

    private func run(_ stream: AsyncStream<Event>) async {
        var stamps = currentStamps()
        await rehash(&stamps)
        for await event in stream {
            if Task.isCancelled { return }
            switch event {
            case .look:
                guard !needsRetry else { continue }
                if currentStamps() != stamps { await rehash(&stamps) }
            case .retry:
                await fetch(&stamps)
            }
        }
    }

    /// Hashes every file under its real name; deletes each that is not whole, then fetches once.
    private func rehash(_ stamps: inout [String: Stamp]) async {
        stamps = currentStamps()   // taken before the hash, so a change during it is seen next time
        var damaged = false
        for file in files where stamps[file.name] != nil {
            if Task.isCancelled { return }
            if ModelFiles.isPresent(file, at: SesameFolder.modelsURL.appendingPathComponent(file.name)) { continue }
            if Task.isCancelled { return }
            guard (try? SesameFolder.delete(file.name, in: .models)) != nil else { continue }
            onMessage(Self.damagedMessage)
            damaged = true
        }
        if damaged { await fetch(&stamps) }
    }

    private func fetch(_ stamps: inout [String: Stamp]) async {
        let whole = await ModelDownload(files: files).start()
        if Task.isCancelled { return }
        stamps = currentStamps()
        if !whole {
            lock.withLock { waitingForRetry = true }
            onFailure(SetupModel.downloadFailedMessage)
        } else {
            onFetched()
        }
    }

    private func currentStamps() -> [String: Stamp] {
        var result: [String: Stamp] = [:]
        for file in files {
            let path = SesameFolder.modelsURL.appendingPathComponent(file.name).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? Int,
                  let modified = attributes[.modificationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? Int else { continue }
            result[file.name] = Stamp(size: size, modified: modified, inode: inode)
        }
        return result
    }
}
