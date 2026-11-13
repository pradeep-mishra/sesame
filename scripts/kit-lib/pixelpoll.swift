// The kit's pixel-poll tool: polls what is on screen without the accessibility tree, and stamps
// the moment with the same monotonic clock the app's probe file uses (uptime nanoseconds).
//
//   pixelpoll screen-trusted                     Screen Recording for this terminal
//   pixelpoll windows <owner>                    "<x> <y> <w> <h> <layer> <title>" per on-screen window
//   pixelpoll wait-window <owner> [--min-w N] [--gone] [--timeout-ms N] [--interval-ms N]
//                                                prints "appeared ns=<n>" or "gone ns=<n>"
//   pixelpoll window-id (--owner <name> | --pid <n>) [--largest] [--min-w N] [--min-h N]
//                                                prints the window number of ONE on-screen window (the
//                                                front-most one, or with --largest the largest), so a
//                                                picture can be taken of that window alone; exit 1 when
//                                                there is none. Only ordinary and floating windows (layer 0 to
//                                                3: Sesame's panel is a floating panel, layer 3; the menu bar,
//                                                status items, alerts and pop-ups sit above that) of at least
//                                                100 x 50 points count unless --min-w/--min-h say more.
//   pixelpoll now                                prints the uptime nanoseconds now (the probe file's clock)
//   pixelpoll watch-windows <owner> [--min-w N] [--interval-ms N] [--duration-ms N]
//                                                one line per change of "has a window at least N points
//                                                wide": "start present|absent ns=<n>", then
//                                                "appeared ns=<n>" and "gone ns=<n>" (the window-list poll of
//                                                S2.9; no accessibility tree, no picture)
//   pixelpoll watch-list (--owner <name> | --window-id N) [--min-w N] [--left F] [--top F] [--duration-ms N]
//                                                the pixel poll of S2.10 to S2.12 (guess K27): a ScreenCaptureKit
//                                                stream of ONE window by window id (never the screen, never the
//                                                accessibility tree). The list area is the part of the window
//                                                right of the left edge (0 to F of the width, default 0.45) and
//                                                below the top (default 0.18 of the height). Prints
//                                                "ready ns=<n> ..." after the first frame, then one
//                                                "frame ns=<n> bands=<b> hash=<h>" per frame whose list area
//                                                changed. A band is a run of rows that differ from the area's
//                                                background; the caller decides how many bands mean rows.
//   pixelpoll bands-selftest                     the band counter on drawn pictures with 0, 1 and 5 bands: it
//                                                must count them and tell the pictures apart (exit 1 if not)
//
// Exit codes: 0 done; 1 error or not granted; 2 usage; 4 timeout (the run is invalid, rerun).
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func usage() -> Never {
    fail("""
    usage: pixelpoll screen-trusted
           pixelpoll windows <owner>
           pixelpoll wait-window <owner> [--min-w N] [--gone] [--timeout-ms N] [--interval-ms N]
           pixelpoll window-id (--owner <name> | --pid <n>) [--largest] [--min-w N] [--min-h N]
           pixelpoll now
           pixelpoll watch-windows <owner> [--min-w N] [--interval-ms N] [--duration-ms N]
           pixelpoll watch-list (--owner <name> | --window-id N) [--min-w N] [--left F] [--top F] [--duration-ms N]
           pixelpoll bands-selftest
    """, 2)
}

func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

struct Window {
    let id: Int
    let pid: Int
    let rect: CGRect
    let layer: Int
    let title: String
}

// The on-screen windows, front-most first (the order CGWindowList gives), of one owner name or one pid.
func windows(of owner: String? = nil, pid: Int? = nil) -> [Window] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    var found: [Window] = []
    for info in list {
        if let owner = owner, (info[kCGWindowOwnerName as String] as? String) != owner { continue }
        if let pid = pid, (info[kCGWindowOwnerPID as String] as? Int) != pid { continue }
        guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds)
        else { continue }
        found.append(Window(
            id: info[kCGWindowNumber as String] as? Int ?? 0,
            pid: info[kCGWindowOwnerPID as String] as? Int ?? 0,
            rect: rect,
            layer: info[kCGWindowLayer as String] as? Int ?? 0,
            title: info[kCGWindowName as String] as? String ?? ""))
    }
    return found
}


// ---- the list-area reading (pixel poll) -----------------------------------------------------

struct ListReading {
    var bands: Int
    var hash: UInt64
}

// Reads the list area of a BGRA picture: the area is x in [0, left * width), y in [top * height, height). Pixels are
// sampled every second pixel. The background is the most common brightness; a sampled row is "ink" when enough of
// its pixels differ from the background; a band is a run of ink rows (a gap of one sampled row is bridged, a run
// under three sampled rows is a divider line and does not count). The hash is of every sampled brightness, so any
// change of the area changes it.
func readList(base: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, left: Double, top: Double) -> ListReading {
    let step = 2
    let x1 = max(step, Int(Double(width) * left))
    let y0 = min(height - 1, Int(Double(height) * top))
    var luma: [UInt8] = []
    var rows = 0
    var cols = 0
    var y = y0
    while y < height {
        var x = 0
        cols = 0
        while x < x1 {
            let o = y * bytesPerRow + x * 4
            let b = Int(base[o]), g = Int(base[o + 1]), r = Int(base[o + 2])
            luma.append(UInt8((299 * r + 587 * g + 114 * b) / 1000))
            x += step
            cols += 1
        }
        y += step
        rows += 1
    }
    var hist = [Int](repeating: 0, count: 64)
    var hash: UInt64 = 0xcbf29ce484222325
    for v in luma {
        hist[Int(v >> 2)] += 1
        hash = (hash ^ UInt64(v >> 3)) &* 0x100000001b3
    }
    let mode = hist.indices.max { hist[$0] < hist[$1] } ?? 0
    let bg = mode * 4 + 2
    let need = max(2, cols / 150)
    var ink = [Bool](repeating: false, count: rows)
    for r in 0..<rows {
        var n = 0
        for c in 0..<cols where abs(Int(luma[r * cols + c]) - bg) > 24 { n += 1 }
        ink[r] = n >= need
    }
    var bands = 0
    var run = 0
    var gap = 0
    for r in 0..<rows {
        if ink[r] { run += gap + 1; gap = 0 } else if run > 0 {
            gap += 1
            if gap > 1 { if run >= 3 { bands += 1 }; run = 0; gap = 0 }
        }
    }
    if run >= 3 { bands += 1 }
    return ListReading(bands: bands, hash: hash)
}

// A drawn picture for the selftest: grey background, <count> bands of "text" (every third pixel dark) in the list area.
func drawnPicture(width: Int, height: Int, bands count: Int) -> [UInt8] {
    var buffer = [UInt8](repeating: 245, count: width * height * 4)
    for i in 0..<count {
        let y0 = 140 + i * 60
        for y in y0..<(y0 + 24) {
            for x in 20..<200 where x % 3 != 0 {
                let o = (y * width + x) * 4
                buffer[o] = 40; buffer[o + 1] = 40; buffer[o + 2] = 40
            }
        }
    }
    return buffer
}

func bandsSelftest() -> Never {
    var seen: [Int] = []
    var hashes: [UInt64] = []
    for k in [0, 1, 5] {
        let buffer = drawnPicture(width: 800, height: 600, bands: k)
        let reading = buffer.withUnsafeBufferPointer {
            readList(base: $0.baseAddress!, width: 800, height: 600, bytesPerRow: 800 * 4, left: 0.45, top: 0.18)
        }
        seen.append(reading.bands)
        hashes.append(reading.hash)
    }
    let right = seen == [0, 1, 5] && Set(hashes).count == 3
    print("bands-selftest drawn 0/1/5 counted \(seen[0])/\(seen[1])/\(seen[2]), pictures told apart: \(Set(hashes).count == 3)")
    exit(right ? 0 : 1)
}

// ---- the window-list poll ------------------------------------------------------------------------

func watchWindows(owner: String, minWidth: Double, intervalMs: Int, durationMs: Int) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    let deadline = durationMs > 0 ? nowNs() + UInt64(durationMs) * 1_000_000 : UInt64.max
    var last: Bool?
    while nowNs() < deadline {
        let present = windows(of: owner).contains { $0.rect.size.width >= minWidth }
        let stamp = nowNs()
        if last == nil {
            print("start \(present ? "present" : "absent") ns=\(stamp)")
        } else if present != last {
            print("\(present ? "appeared" : "gone") ns=\(stamp)")
        }
        fflush(stdout)
        last = present
        usleep(UInt32(intervalMs) * 1000)
    }
    exit(0)
}

// ---- the list poll ---------------------------------------------------------------------------------

final class ListOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let left: Double
    let top: Double
    var lastHash: UInt64?

    init(left: Double, top: Double) {
        self.left = left
        self.top = top
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let stamp = nowNs()
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let reading = readList(
            base: base.assumingMemoryBound(to: UInt8.self), width: width, height: height,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), left: left, top: top)
        if lastHash == nil {
            print("ready ns=\(stamp) width=\(width) height=\(height) bands=\(reading.bands) hash=\(reading.hash)")
        } else if reading.hash != lastHash {
            print("frame ns=\(stamp) bands=\(reading.bands) hash=\(reading.hash)")
        }
        fflush(stdout)
        lastHash = reading.hash
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("stopped: \(error.localizedDescription)")
        fflush(stdout)
        exit(1)
    }
}

func watchList(windowId: Int, left: Double, top: Double, durationMs: Int) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    _ = NSApplication.shared   // ScreenCaptureKit needs the window server connection a command line tool does not open by itself
    let semaphore = DispatchSemaphore(value: 0)
    var found: SCWindow?
    var failure: String?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
        if let error = error { failure = error.localizedDescription }
        found = content?.windows.first { Int($0.windowID) == windowId }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 10) == .timedOut { fail("ScreenCaptureKit gave no answer within 10 s") }
    guard let window = found else {
        fail(failure.map { "could not list windows: \($0)" } ?? "no on-screen window \(windowId)")
    }
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width) * 2
    config.height = Int(window.frame.height) * 2
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    config.showsCursor = false
    config.queueDepth = 6
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let output = ListOutput(left: left, top: top)
    let stream = SCStream(filter: filter, configuration: config, delegate: output)
    do {
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "pixelpoll.list"))
    } catch {
        fail("could not add the stream output: \(error.localizedDescription)")
    }
    stream.startCapture { error in
        if let error = error {
            print("stopped: could not start the capture: \(error.localizedDescription)")
            fflush(stdout)
            exit(1)
        }
    }
    if durationMs > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(durationMs)) { exit(0) }
    }
    RunLoop.main.run()
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "screen-trusted":
    if CGPreflightScreenCaptureAccess() {
        print("granted")
    } else {
        print("not granted")
        exit(1)
    }

case "windows":
    guard args.count == 2 else { usage() }
    for window in windows(of: args[1]) {
        let r = window.rect
        print("\(Int(r.origin.x)) \(Int(r.origin.y)) \(Int(r.size.width)) \(Int(r.size.height)) \(window.layer) \(window.title)")
    }

case "window-id":
    var owner: String?
    var pid: Int?
    var largest = false
    var minW = 100.0
    var minH = 50.0
    var index = 1
    while index < args.count {
        switch args[index] {
        case "--owner":
            guard index + 1 < args.count else { usage() }
            owner = args[index + 1]; index += 2
        case "--pid":
            guard index + 1 < args.count, let n = Int(args[index + 1]) else { usage() }
            pid = n; index += 2
        case "--largest":
            largest = true; index += 1
        case "--min-w":
            guard index + 1 < args.count, let n = Double(args[index + 1]) else { usage() }
            minW = n; index += 2
        case "--min-h":
            guard index + 1 < args.count, let n = Double(args[index + 1]) else { usage() }
            minH = n; index += 2
        default:
            usage()
        }
    }
    guard (owner == nil) != (pid == nil) else { usage() }
    let candidates = windows(of: owner, pid: pid).filter {
        $0.layer >= 0 && $0.layer <= 3 && $0.rect.size.width >= minW && $0.rect.size.height >= minH && $0.id != 0
    }
    let pick = largest
        ? candidates.max { $0.rect.size.width * $0.rect.size.height < $1.rect.size.width * $1.rect.size.height }
        : candidates.first
    guard let window = pick else { exit(1) }
    print(window.id)

case "wait-window":
    guard args.count >= 2 else { usage() }
    let owner = args[1]
    var minWidth = 1.0
    var gone = false
    var timeoutMs = 10_000
    var intervalMs = 1
    var index = 2
    while index < args.count {
        switch args[index] {
        case "--min-w":
            guard index + 1 < args.count, let n = Double(args[index + 1]) else { usage() }
            minWidth = n; index += 2
        case "--gone":
            gone = true; index += 1
        case "--timeout-ms":
            guard index + 1 < args.count, let n = Int(args[index + 1]), n > 0 else { usage() }
            timeoutMs = n; index += 2
        case "--interval-ms":
            guard index + 1 < args.count, let n = Int(args[index + 1]), n > 0 else { usage() }
            intervalMs = n; index += 2
        default:
            usage()
        }
    }
    let deadline = nowNs() + UInt64(timeoutMs) * 1_000_000
    while nowNs() < deadline {
        let present = windows(of: owner).contains { $0.rect.size.width >= minWidth }
        let stamp = nowNs()
        if present != gone {
            print("\(gone ? "gone" : "appeared") ns=\(stamp)")
            exit(0)
        }
        usleep(UInt32(intervalMs) * 1000)
    }
    print("timeout")
    exit(4)

case "now":
    guard args.count == 1 else { usage() }
    print(nowNs())

case "bands-selftest":
    guard args.count == 1 else { usage() }
    bandsSelftest()

case "watch-windows":
    guard args.count >= 2 else { usage() }
    var minWidth = 1.0
    var intervalMs = 1
    var durationMs = 0
    var index = 2
    while index < args.count {
        switch args[index] {
        case "--min-w":
            guard index + 1 < args.count, let n = Double(args[index + 1]) else { usage() }
            minWidth = n; index += 2
        case "--interval-ms":
            guard index + 1 < args.count, let n = Int(args[index + 1]), n > 0 else { usage() }
            intervalMs = n; index += 2
        case "--duration-ms":
            guard index + 1 < args.count, let n = Int(args[index + 1]), n > 0 else { usage() }
            durationMs = n; index += 2
        default:
            usage()
        }
    }
    watchWindows(owner: args[1], minWidth: minWidth, intervalMs: intervalMs, durationMs: durationMs)

case "watch-list":
    var owner: String?
    var windowId: Int?
    var minW = 100.0
    var left = 0.45
    var top = 0.18
    var durationMs = 0
    var index = 1
    while index < args.count {
        switch args[index] {
        case "--owner":
            guard index + 1 < args.count else { usage() }
            owner = args[index + 1]; index += 2
        case "--window-id":
            guard index + 1 < args.count, let n = Int(args[index + 1]) else { usage() }
            windowId = n; index += 2
        case "--min-w":
            guard index + 1 < args.count, let n = Double(args[index + 1]) else { usage() }
            minW = n; index += 2
        case "--left":
            guard index + 1 < args.count, let n = Double(args[index + 1]), n > 0, n <= 1 else { usage() }
            left = n; index += 2
        case "--top":
            guard index + 1 < args.count, let n = Double(args[index + 1]), n >= 0, n < 1 else { usage() }
            top = n; index += 2
        case "--duration-ms":
            guard index + 1 < args.count, let n = Int(args[index + 1]), n > 0 else { usage() }
            durationMs = n; index += 2
        default:
            usage()
        }
    }
    guard (owner == nil) != (windowId == nil) else { usage() }
    var target = windowId
    if let owner = owner {
        let pick = windows(of: owner).filter { $0.layer >= 0 && $0.layer <= 3 && $0.rect.size.width >= minW && $0.id != 0 }
            .max { $0.rect.size.width * $0.rect.size.height < $1.rect.size.width * $1.rect.size.height }
        guard let window = pick else { fail("no on-screen window of \(owner)") }
        target = window.id
    }
    watchList(windowId: target!, left: left, top: top, durationMs: durationMs)

default:
    usage()
}
