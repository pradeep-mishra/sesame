import Darwin
import Foundation
import SesameEngine

/// The `encode` mode: one JSON command per stdin line, one reply per `embed`, until stdin ends or 60 s pass with
/// no request. The model loads on the first `prewarm` or `embed`; a start with no `--text-model` refuses every embed.
/// It holds no network code.
func runEncode(arguments: [String]) -> Never {
    signal(SIGPIPE, SIG_IGN)
    var textModel: String?
    var index = 0
    while index < arguments.count {
        if arguments[index] == "--text-model", index + 1 < arguments.count {
            textModel = arguments[index + 1]
            index += 1
        }
        index += 1
    }
    var encoder = Encoder(textModelPath: textModel)
    let input = StdinLines()
    while true {
        switch input.next(waitingAtMost: Encoder.idleSeconds) {
        case .timeout, .end:
            encoder.finish()
        case let .line(text):
            if !encoder.handle(line: text) { encoder.finish() }
        }
    }
}

private struct Encoder {
    static let idleSeconds = 60.0
    static let cacheSize = 256

    private struct Key: Hashable {
        let text: String
        let isQuery: Bool
    }

    private let embedder: LlamaEmbedder?
    private var loadError: String?
    private var cache: [Key: [Float]] = [:]
    private var recent: [Key] = []

    init(textModelPath: String?) {
        embedder = textModelPath.map { LlamaEmbedder(textModel: URL(fileURLWithPath: $0)) }
    }

    /// Frees the model first: llama.cpp's Metal backend aborts at process exit if a model is still loaded.
    func finish() -> Never {
        embedder?.unload()
        exit(0)
    }

    /// False when stdout is gone.
    mutating func handle(line: String) -> Bool {
        guard let command = try? HelperProtocol.command(from: line) else {
            writeError("SesameHelper encode: ignored a line that is not a command")
            return true
        }
        switch command {
        case .prewarm:
            _ = loaded()
            return true
        case let .embed(id, text, role):
            return reply(for: embed(id: id, text: text, role: role))
        default:
            return true
        }
    }

    private func loaded() -> LlamaEmbedder? {
        guard let embedder else { return nil }
        if embedder.isLoaded { return embedder }
        do {
            try embedder.load()
            return embedder
        } catch {
            writeError("SesameHelper encode: \(error)")
            return nil
        }
    }

    private mutating func embed(id: Int, text: String, role: EmbedRole) -> HelperEvent {
        guard embedder != nil else { return .refused(id: id, reason: "no model path was given") }
        let key = Key(text: text, isQuery: role == .query)
        if let hit = cache[key] {
            recent.removeAll { $0 == key }
            recent.append(key)
            return .vector(id: id, ms: 0, vec: hit)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        guard let embedder = loaded() else { return .refused(id: id, reason: "the model could not be loaded") }
        guard let vec = try? embedder.embed(text, role: role) else {
            return .refused(id: id, reason: "the text could not be embedded")
        }
        let ms = Int((Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000).rounded())
        cache[key] = vec
        recent.append(key)
        if recent.count > Self.cacheSize { cache[recent.removeFirst()] = nil }
        return .vector(id: id, ms: ms, vec: vec)
    }

    private func reply(for event: HelperEvent) -> Bool {
        guard let text = try? HelperProtocol.line(for: event) else { return true }
        return writeAll(fd: STDOUT_FILENO, Array((text + "\n").utf8))
    }
}

private func writeError(_ message: String) {
    _ = writeAll(fd: STDERR_FILENO, Array((message + "\n").utf8))
}

private func writeAll(fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += written
    }
    return true
}

/// Lines from stdin, waiting at most a given time for each.
private final class StdinLines {
    enum Result {
        case line(String)
        case timeout
        case end
    }

    private var buffer: [UInt8] = []
    private var ended = false

    func next(waitingAtMost seconds: Double) -> Result {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let text = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return .line(text)
            }
            if ended {
                guard !buffer.isEmpty else { return .end }
                defer { buffer.removeAll() }
                return .line(String(decoding: buffer, as: UTF8.self))
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timeout }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(min((deadline - now) / 1_000_000 + 1, 1000))
            let ready = poll(&descriptor, 1, waitMs)
            if ready < 0, errno != EINTR { return .end }
            guard ready > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(STDIN_FILENO, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[..<count])
            } else if count == 0 || errno != EINTR {
                ended = true
            }
        }
    }
}
