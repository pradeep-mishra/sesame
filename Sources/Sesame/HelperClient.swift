import Foundation
import SesameEngine

/// How a helper process ended. `planned` is an exit with status 0 after the app ended its stdin (a clean stop or a
/// shutdown); `idle` is an exit with status 0 that nobody asked for (the helper's own idle timeout), which is no
/// death; everything else is `unplanned`, with the exit status (a signal's number for a kill, -1 for a helper that
/// could not be started).
enum HelperExit: Equatable, Sendable {
    case planned
    case idle
    case unplanned(status: Int32)
}

/// Receives every event either helper prints, decoded, in the order that helper printed them. Called on any thread.
protocol HelperClientDelegate: AnyObject {
    func helperClient(_ client: HelperClient, didReceive event: HelperEvent)
}

/// The one place the app talks to the helpers (design sections 1 to 3). Every method returns at once: the command
/// is queued and written by the client, and the answer comes through the delegate. A helper is started by the work
/// that needs it and by nothing else; when it has exited, the next command starts a new one (the restart with its
/// attempt marker is plan 2). Model paths reach a helper only as `--text-model` and `--mm-model`.
final class HelperClient: @unchecked Sendable {
    private let encode: Channel
    private let index: Channel
    private let bench: BenchRun
    private let lock = NSLock()
    private weak var listener: HelperClientDelegate?
    private var exitListener: (@Sendable (String, HelperExit) -> Void)?
    private var encodeExitListener: (@Sendable (HelperExit) -> Void)?

    var delegate: HelperClientDelegate? {
        get { lock.lock(); defer { lock.unlock() }; return listener }
        set { lock.lock(); listener = newValue; lock.unlock() }
    }

    /// Called once per exit of an `encode` or `index` process ("encode" or "index"), after the process is gone, on any
    /// thread. The one-shot bench is not reported. The client restarts nothing itself: the next command does.
    var onExit: (@Sendable (String, HelperExit) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return exitListener }
        set { lock.lock(); exitListener = newValue; lock.unlock() }
    }

    /// Called, besides `onExit`, once per exit of the `encode` process only, on any thread. A second observer, so the
    /// embedder learns of an encode death without taking `onExit` from whoever watches the `index` helper.
    var onEncodeExit: (@Sendable (HelperExit) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return encodeExitListener }
        set { lock.lock(); encodeExitListener = newValue; lock.unlock() }
    }

    /// Seconds a speed bench may run before it is terminated; the supervisor then stops waiting for it.
    static let benchTimeout: TimeInterval = 240

    init(helper: URL, textModel: URL, mmModel: URL, benchTimeout: TimeInterval = HelperClient.benchTimeout) {
        encode = Channel(mode: "encode", helper: helper, flags: ["--text-model", textModel.path])
        index = Channel(mode: "index", helper: helper, flags: ["--text-model", textModel.path, "--mm-model", mmModel.path])
        bench = BenchRun(
            helper: helper, flags: ["--text-model", textModel.path, "--mm-model", mmModel.path], timeout: benchTimeout)
        let forward: @Sendable (String) -> Void = { [weak self] line in self?.received(line) }
        encode.onLine = forward
        index.onLine = forward
        encode.onExit = { [weak self] exit in
            self?.onExit?("encode", exit)
            self?.onEncodeExit?(exit)
        }
        index.onExit = { [weak self] exit in self?.onExit?("index", exit) }
    }

    /// Every open asks `encode` to warm up (starting it); a running `index` is told the panel opened.
    func panelDidOpen() {
        encode.send(.prewarm, starting: true)
        index.send(.panel(open: true), starting: false)
    }

    /// Only a running `index` hears of it; a close is no work for either helper.
    func panelDidClose() {
        index.send(.panel(open: false), starting: false)
    }

    func embed(id: Int, text: String, role: EmbedRole) {
        encode.send(.embed(id: id, text: text, role: role), starting: true)
    }

    /// The Start hook: the whole list of settings.json folders that are reading, replacing the previous one.
    /// Read now, not later, so a settings change made right after the call is never mixed into this line.
    func sendFolders() {
        _ = queueFolders()
    }

    /// `sendFolders()` that says whether a line was queued (false when settings.json cannot be read).
    func queueFolders() -> Bool {
        guard let settings = try? SettingsFile().read() else { return false }
        let folders = settings.folders.filter(\.reading).map {
            HelperFolder(path: $0.path, code: false)
        }
        index.send(.folders(folders), starting: true)
        return true
    }

    /// A clean stop: ends the stdin of a running `index` and nothing else. The helper finishes its unit, puts its
    /// attempt markers back and exits 0, which `onExit` reports as planned. No line, no start, `encode` untouched.
    func stopIndex() {
        index.stop()
    }

    /// Ends both helpers' stdin and terminates a running bench, kills one still alive after `timeout`, and calls
    /// `completion` once all three are gone (at once when none runs). Starts nothing, and no command starts a helper
    /// or a bench afterwards.
    func shutdown(timeout: TimeInterval, completion: @escaping @Sendable () -> Void) {
        let group = DispatchGroup()
        for channel in [encode, index] {
            group.enter()
            channel.shutdown(timeout: timeout) { group.leave() }
        }
        group.enter()
        bench.shutdown(timeout: timeout) { group.leave() }
        group.notify(queue: .global()) { completion() }
    }

    func reset() {
        index.send(.reset, starting: true)
    }

    func preview(ticket: Int, file: String, passage: Int?, query: String) {
        index.send(.preview(ticket: ticket, file: file, passage: passage, query: query), starting: true, dropWhileStopping: true)
    }

    /// The one-shot `index bench`: the seconds per file by kind, or why there are none. Every call is answered once,
    /// on any thread; calls made while a bench runs share that run. The process is not kept: it ends with its line.
    func runBench(completion: @escaping (Result<[String: Double], Error>) -> Void) {
        bench.run(completion)
    }

    /// A line that is not a known event is dropped.
    private func received(_ line: String) {
        guard let event = try? HelperProtocol.event(from: line) else { return }
        delegate?.helperClient(self, didReceive: event)
    }
}

/// One helper mode: at most one process, written to only from `queue`.
private final class Channel: @unchecked Sendable {
    /// One started process. Touched only on the channel's queue, except `process`, which is read anywhere.
    private final class Run: @unchecked Sendable {
        let process: Process
        var input: FileHandle?
        var stopRequested = false
        var waiters: [@Sendable () -> Void] = []

        init(process: Process, input: FileHandle) {
            self.process = process
            self.input = input
        }

        func closeInput() {
            try? input?.close()
            input = nil
        }
    }

    private let mode: String
    private let helper: URL
    private let flags: [String]
    private let queue: DispatchQueue
    private var run: Run?
    private var closed = false
    var onLine: (@Sendable (String) -> Void)?
    var onExit: (@Sendable (HelperExit) -> Void)?

    init(mode: String, helper: URL, flags: [String]) {
        self.mode = mode
        self.helper = helper
        self.flags = flags
        queue = DispatchQueue(label: "sesame.helper.\(mode)")
    }

    /// `dropWhileStopping`: a command that is no work in itself (a preview) is dropped, and starts nothing, while the
    /// process has been told to end and has not yet exited; a second process would otherwise run beside it.
    func send(_ command: HelperCommand, starting: Bool, dropWhileStopping: Bool = false) {
        guard let line = try? HelperProtocol.line(for: command) else { return }
        let data = Data((line + "\n").utf8)
        queue.async { [self] in
            if dropWhileStopping, let run, run.stopRequested, run.process.isRunning { return }
            if write(data) { return }
            // Not running, or it died before the exit was noticed (a broken pipe): start a new one only for work.
            discard()
            if starting, !closed, launch() { _ = write(data) }
        }
    }

    /// Ends the stdin of the running process; it is told once. Its exit is reported as planned.
    func stop() {
        queue.async { [self] in
            guard let run, !run.stopRequested, run.process.isRunning else { return }
            run.stopRequested = true
            run.closeInput()
        }
    }

    /// Ends the stdin, kills the process after `timeout`, and calls `completion` once it is gone. No later command
    /// starts this helper.
    func shutdown(timeout: TimeInterval, completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            closed = true
            guard let run, run.process.isRunning else { completion(); return }
            run.stopRequested = true
            run.closeInput()
            run.waiters.append(completion)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if run.process.isRunning { kill(run.process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func write(_ data: Data) -> Bool {
        // A process asked to stop has a closed stdin: its descriptor number may already belong to something else.
        guard let run, !run.stopRequested, run.process.isRunning, let input = run.input else { return false }
        let descriptor = input.fileDescriptor
        return data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + done, bytes.count - done)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                done += count
            }
            return true
        }
    }

    private func launch() -> Bool {
        let started = Process()
        started.executableURL = helper
        started.arguments = [mode] + flags
        let stdin = Pipe()
        let stdout = Pipe()
        started.standardInput = stdin
        started.standardOutput = stdout
        // A write to a helper that is gone must fail with EPIPE, never kill the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let lines = LineSplitter { [weak self] line in self?.onLine?(line) }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                lines.finish()
            } else {
                lines.feed(chunk)
            }
        }
        let current = Run(process: started, input: stdin.fileHandleForWriting)
        started.terminationHandler = { [weak self] _ in
            guard let channel = self else { return }
            channel.queue.async { channel.exited(current) }
        }
        do {
            try started.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            FileHandle.standardError.write(Data("Sesame: could not start the \(mode) helper: \(error)\n".utf8))
            onExit?(.unplanned(status: -1))
            return false
        }
        run = current
        return true
    }

    /// The process of `finished` is gone: report it, then release whoever waits for it.
    private func exited(_ finished: Run) {
        let process = finished.process
        let status = process.terminationStatus
        let planned = finished.stopRequested && process.terminationReason == .exit && status == 0
        if run === finished { discard() } else { finished.closeInput() }
        let waiters = finished.waiters
        finished.waiters = []
        let cleanExit = process.terminationReason == .exit && status == 0
        onExit?(planned ? .planned : cleanExit ? .idle : .unplanned(status: status))
        for waiter in waiters { waiter() }
    }

    private func discard() {
        run?.closeInput()
        run = nil
    }
}

enum BenchError: Error, CustomStringConvertible {
    case couldNotStart(String)
    case exited(Int32)
    case noBenchLine
    /// It ran for the whole timeout and was terminated.
    case timedOut
    /// The app is quitting: no bench starts, and one that runs is terminated. Not a failure of the bench.
    case quitting

    var description: String {
        switch self {
        case let .couldNotStart(reason): return "the speed measurement could not start: \(reason)"
        case let .exited(status): return "the speed measurement ended with status \(status)"
        case .noBenchLine: return "the speed measurement printed no result"
        case .timedOut: return "the speed measurement took too long"
        case .quitting: return "the speed measurement was stopped because the app is quitting"
        }
    }
}

/// The one-shot `index bench` process: at most one at a time, started by `run`, gone when its output ends.
private final class BenchRun: @unchecked Sendable {
    private let helper: URL
    private let flags: [String]
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var waiting: [(Result<[String: Double], Error>) -> Void] = []
    /// The running bench process, and whether `shutdown` has been called (no bench starts after it).
    private var process: Process?
    private var closed = false
    /// The timeout ended the process that runs now.
    private var timedOut = false
    private var shutdownWaiters: [@Sendable () -> Void] = []

    init(helper: URL, flags: [String], timeout: TimeInterval) {
        self.helper = helper
        self.flags = flags
        self.timeout = timeout
    }

    func run(_ completion: @escaping (Result<[String: Double], Error>) -> Void) {
        lock.lock()
        if closed {
            lock.unlock()
            completion(.failure(BenchError.quitting))
            return
        }
        waiting.append(completion)
        let starting = waiting.count == 1
        lock.unlock()
        guard starting else { return }
        DispatchQueue.global().async { [self] in finish(measure()) }
    }

    /// Terminates a running bench, kills it when it is still there after `timeout`, and calls `completion` once it is
    /// gone (at once when none runs). No bench starts afterwards.
    func shutdown(timeout: TimeInterval, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        closed = true
        guard let running = process else {
            lock.unlock()
            completion()
            return
        }
        shutdownWaiters.append(completion)
        lock.unlock()
        running.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }

    private func finish(_ result: Result<[String: Double], Error>) {
        lock.lock()
        let done = waiting
        waiting = []
        lock.unlock()
        for completion in done { completion(result) }
    }

    /// A bench that has run the whole timeout is terminated (killed 2 s later when it ignores that), so the read below
    /// ends. A bench ended by `shutdown` is the app quitting, not a failure and not a timeout.
    private func expire(_ process: Process) {
        lock.lock()
        let running = self.process === process && process.isRunning
        if running { timedOut = true }
        lock.unlock()
        guard running else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Blocks until the helper has ended. Its stdout is read to the end, so the exit and the line are both known.
    private func measure() -> Result<[String: Double], Error> {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["index", "bench"] + flags
        let stdout = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        lock.lock()
        if closed {
            lock.unlock()
            return .failure(BenchError.quitting)
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            return .failure(BenchError.couldNotStart("\(error)"))
        }
        self.process = process
        timedOut = false
        lock.unlock()
        let expiry = DispatchWorkItem { [self] in expire(process) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        expiry.cancel()
        lock.lock()
        self.process = nil
        let expired = timedOut
        let quitting = closed
        let waiters = shutdownWaiters
        shutdownWaiters = []
        lock.unlock()
        defer { for waiter in waiters { waiter() } }
        if expired { return .failure(BenchError.timedOut) }
        if quitting, process.terminationStatus != 0 { return .failure(BenchError.quitting) }
        guard process.terminationStatus == 0 else { return .failure(BenchError.exited(process.terminationStatus)) }
        let text = String(decoding: output, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            if case let .bench(speeds)? = try? HelperProtocol.event(from: String(line)) { return .success(speeds) }
        }
        return .failure(BenchError.noBenchLine)
    }
}

/// Cuts a byte stream into lines, however the reads fall: a 10 KB vector line may arrive in pieces and two
/// events may arrive in one read.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let deliver: @Sendable (String) -> Void

    init(deliver: @escaping @Sendable (String) -> Void) {
        self.deliver = deliver
    }

    func feed(_ chunk: Data) {
        lock.lock()
        pending.append(chunk)
        var lines: [Data] = []
        while let end = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<end])
            pending.removeSubrange(pending.startIndex...end)
        }
        lock.unlock()
        for line in lines { emit(line) }
    }

    /// A last line with no newline at the end of the stream.
    func finish() {
        lock.lock()
        let rest = pending
        pending = Data()
        lock.unlock()
        emit(rest)
    }

    private func emit(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { deliver(line) }
    }
}
