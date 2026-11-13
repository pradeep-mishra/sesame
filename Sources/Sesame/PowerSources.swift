import Darwin
import Foundation
import IOKit.ps

/// Reads the power source once through IOKit. No process is started.
enum PowerSourceReader {
    /// True when the Mac runs on battery power; false on power, on a desktop and when the source cannot be read.
    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

/// The real `PowerSource`: IOKit's power source notification on the main run loop.
@MainActor final class IOKitPowerSource: PowerSource {
    var onBattery: Bool { PowerSourceReader.onBattery() }

    var onChange: (() -> Void)? {
        didSet { onChange == nil ? removeSource() : addSource() }
    }

    nonisolated(unsafe) private var source: CFRunLoopSource?

    private func addSource() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let object = Unmanaged<IOKitPowerSource>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { object.onChange?() }
        }
        guard let created = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
    }

    private func removeSource() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = nil
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}

/// The real `LowPowerSource`: `ProcessInfo` and its power state notification.
@MainActor final class ProcessLowPowerSource: LowPowerSource {
    var isOn: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    var onChange: (() -> Void)? {
        didSet { onChange == nil ? removeObserver() : addObserver() }
    }

    nonisolated(unsafe) private var token: NSObjectProtocol?

    private func addObserver() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    private func removeObserver() {
        guard let token else { return }
        NotificationCenter.default.removeObserver(token)
        self.token = nil
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

/// The real `CPUSource`: whole-system busy ticks from `host_processor_info`, minus the CPU time of the app and its
/// child processes (`libproc`), both measured between two calls. The first call has no interval and gives 0.
@MainActor final class HostCPUSampler: CPUSource {
    private var previousTicks: [UInt32]?
    private var previousOwn: [Int32: Double] = [:]
    private let ticksPerSecond = Double(sysconf(_SC_CLK_TCK))
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func sample() -> Double {
        guard let ticks = Self.cpuTicks() else { return 0 }
        let own = ownSeconds()
        defer { previousTicks = ticks; previousOwn = own }
        guard let previous = previousTicks, previous.count == ticks.count else { return 0 }

        // Per core: user, system, idle, nice. Wrapping subtraction survives a counter that wrapped.
        var busy = 0.0, total = 0.0
        for core in stride(from: 0, to: ticks.count, by: 4) {
            var all = 0.0
            for state in 0..<4 { all += Double(ticks[core + state] &- previous[core + state]) }
            let idle = Double(ticks[core + Int(CPU_STATE_IDLE)] &- previous[core + Int(CPU_STATE_IDLE)])
            busy += all - idle
            total += all
        }
        var ownDelta = 0.0
        for (pid, seconds) in own { ownDelta += max(0, seconds - (previousOwn[pid] ?? 0)) }
        return CPUSampler.apart(system: (busy: busy, total: total), own: ownDelta * ticksPerSecond)
    }

    /// Cumulative ticks, four per core (the `CPU_STATE_*` order), or nil when the host call fails.
    private static func cpuTicks() -> [UInt32]? {
        var cores: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { UInt32(bitPattern: info[$0]) }
    }

    /// CPU seconds used so far by each of the app's own processes (the app and its children).
    private func ownSeconds() -> [Int32: Double] {
        let appPID = ProcessInfo.processInfo.processIdentifier
        let own = CPUSampler.ownPIDs(appPID: appPID, parentOf: Self.parentTable())
        var seconds: [Int32: Double] = [:]
        for pid in own {
            var usage = rusage_info_current()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
            }
            guard status == 0 else { continue }
            let machTime = Double(usage.ri_user_time) + Double(usage.ri_system_time)
            seconds[pid] = machTime * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        }
        return seconds
    }

    /// Every process id and its parent, from `libproc`.
    private static func parentTable() -> [Int32: Int32] {
        let first = proc_listallpids(nil, 0)
        guard first > 0 else { return [:] }
        // The first call answers in pids or in bytes depending on the OS; either way `first + 64` slots are enough.
        var pids = [Int32](repeating: 0, count: Int(first) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard filled > 0 else { return [:] }
        var parentOf: [Int32: Int32] = [:]
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { continue }
            parentOf[pid] = Int32(bitPattern: bsd.pbi_ppid)
        }
        return parentOf
    }
}
