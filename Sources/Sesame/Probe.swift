import Darwin
import Foundation

/// The timing probe. `Probe.emit(event, ticket)` appends one JSON line
/// `{"event":"hotkey|shown|key|keyword|ranked","ticket":n,"ns":<monotonic ns>}` to the file named by
/// `SESAME_PROBE_FILE`, read at each call with no fallback, and writes nothing when it is unset.
/// A test sets `Probe.sink` to record events instead of writing a file.
enum Probe {
    nonisolated(unsafe) static var sink: (@Sendable (String, Int) -> Void)?

    static func emit(_ event: String, _ ticket: Int) {
        if let sink {
            sink(event, ticket)
            return
        }
        guard let path = ProcessInfo.processInfo.environment["SESAME_PROBE_FILE"] else { return }
        let ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let line = "{\"event\":\"\(event)\",\"ticket\":\(ticket),\"ns\":\(ns)}\n"
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = write(fd, bytes, bytes.count)
    }
}
