import Darwin
import Foundation
import SesameEngine

/// This process's physical memory footprint (what Activity Monitor shows as Memory), in bytes.
enum FootprintReader {
    /// 0 when the system will not say.
    static func current() -> UInt64 {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }
}

/// Watches the footprint while the helper reads a unit of files (design section 8). At or above `capBytes` it writes
/// what the trip means for each file of the unit in one committed write, then calls `exit`, so the supervisor
/// restarts the helper: the first trip on a file marks it for a solo read and spends no try; a trip during the solo
/// read leaves the hint `hint:memory` and the try the read spent.
final class Watchdog: @unchecked Sendable {
    /// 0.85 GB, the design's table.
    static let capBytes: UInt64 = 850_000_000

    private let store: IndexStore
    private let interval: TimeInterval
    private let footprint: @Sendable () -> UInt64
    private let exit: @Sendable () -> Void
    /// Held while a sample runs and while the unit changes, so a unit that has ended is never tripped on.
    private let lock = NSLock()
    private var unit: [IndexStore.PendingPhoto] = []
    private let wake = NSCondition()
    private var running = false
    private var stopping = false
    private var finished: DispatchSemaphore?

    init(
        store: IndexStore, interval: TimeInterval = 0.25, footprint: @escaping @Sendable () -> UInt64,
        exit: @escaping @Sendable () -> Void
    ) {
        self.store = store
        self.interval = interval
        self.footprint = footprint
        self.exit = exit
    }

    /// The unit being read now, as `pendingPhotos` returned it; an empty list when no unit is being read.
    func watch(_ files: [IndexStore.PendingPhoto]) {
        lock.lock()
        unit = files
        lock.unlock()
    }

    /// One check: at or above the cap, with a unit being read, writes the trip and calls `exit`.
    func sample() {
        lock.lock()
        defer { lock.unlock() }
        guard footprint() >= Self.capBytes, !unit.isEmpty else { return }
        do { try store.recordMemoryTrip(unit) } catch {
            // Without the write the death still counts as a try on each file, which is the plain crash rule.
            try? FileHandle.standardError.write(contentsOf: Data("SesameHelper index: could not record the memory trip: \(error)\n".utf8))
        }
        exit()
    }

    /// Samples every `interval` seconds on a thread of its own.
    func start() {
        wake.lock()
        defer { wake.unlock() }
        guard !running else { return }
        running = true
        stopping = false
        let done = DispatchSemaphore(value: 0)
        finished = done
        let thread = Thread { [self] in
            while true {
                wake.lock()
                if !stopping { wake.wait(until: Date(timeIntervalSinceNow: interval)) }
                let stop = stopping
                wake.unlock()
                if stop { break }
                sample()
            }
            done.signal()
        }
        thread.name = "SesameHelper.Watchdog"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Returns once the sampler thread is done.
    func stop() {
        wake.lock()
        guard running, let done = finished else {
            wake.unlock()
            return
        }
        stopping = true
        wake.broadcast()
        wake.unlock()
        done.wait()
        wake.lock()
        running = false
        finished = nil
        wake.unlock()
    }
}
