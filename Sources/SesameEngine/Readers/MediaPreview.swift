import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Speech

/// The one seam to speech recognition (design section 3, "Preview"): the words of the one window the pane shows. A live
/// value asks Apple's recognizer on this Mac only; a test passes a recording fake.
public protocol SpeechService: Sendable {
    /// Whether this Mac can recognize the system language with no network. When false, `transcribe` is never called.
    var supportsOnDevice: Bool { get }

    /// The words in `samples` (16 kHz mono Float32), or nil for none. Blocks until the words are known, `isCancelled` says so, or
    /// the service gives up. `request` is the one `LiveSpeech.makeRequest()` built; the service adds the audio to it.
    func transcribe(samples: [Float], request: SFSpeechAudioBufferRecognitionRequest, isCancelled: @escaping @Sendable () -> Bool) -> String?
}

/// Apple's on-device recognizer. It asks macOS for Speech Recognition authorization once per run; with no authorization it
/// gives no words. Nothing it hears is stored or logged, and no request ever leaves the Mac.
public final class LiveSpeech: SpeechService, @unchecked Sendable {
    /// The longest a window is given to be recognized.
    private static let limit: TimeInterval = 20

    /// Whether this run has already put the authorization question to macOS.
    private static let asked = Once()

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        /// True the first time only.
        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            defer { used = true }
            return !used
        }
    }

    public init() {}

    /// The only place a recognition request is made: on this Mac, never a server.
    public static func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return request
    }

    public var supportsOnDevice: Bool {
        SFSpeechRecognizer()?.supportsOnDeviceRecognition ?? false
    }

    public func transcribe(samples: [Float], request: SFSpeechAudioBufferRecognitionRequest, isCancelled: @escaping @Sendable () -> Bool) -> String? {
        guard !samples.isEmpty, Self.authorized(), request.requiresOnDeviceRecognition,
              let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let target = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // The helper's main thread is its stdin loop: results are delivered on a queue of their own.
        recognizer.queue = OperationQueue()
        let heard = Heard()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal { heard.finish(result.bestTranscription.formattedString) }
            else if error != nil { heard.finish(nil) }
        }
        request.append(buffer)
        request.endAudio()
        let deadline = Date().addingTimeInterval(Self.limit)
        while !heard.wait(0.1) {
            if isCancelled() || Date() > deadline {
                task.cancel()
                return nil
            }
        }
        let words = heard.words?.trimmingCharacters(in: .whitespacesAndNewlines)
        return words?.isEmpty == false ? words : nil
    }

    private final class Heard: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var text: String?

        var words: String? {
            lock.lock()
            defer { lock.unlock() }
            return text
        }

        func finish(_ words: String?) {
            lock.lock()
            text = words
            lock.unlock()
            done.signal()
        }

        func wait(_ seconds: TimeInterval) -> Bool { done.wait(timeout: .now() + seconds) == .success }
    }

    /// Speech Recognition authorization, asked for once: the first window of a run asks, every later one only reads the answer.
    private static func authorized() -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined, asked.first() {
            let answered = DispatchSemaphore(value: 0)
            SFSpeechRecognizer.requestAuthorization { _ in answered.signal() }
            _ = answered.wait(timeout: .now() + 120)
        }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}

private func pngData(_ image: CGImage) -> Data? {
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return out as Data
}

private func canvas(width: Int, height: Int) -> CGContext? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// The waveform of one window: a bar for each second, as tall as that second is loud (its RMS), left to right from the window's
/// start, on a plain card. A window shorter than 30 s fills only the left part, so a bar keeps its place on the 30 s scale.
enum AudioPreview {
    static let seconds = 30
    private static let rate = 16_000
    private static let barWidth = 18
    private static let gap = 4
    private static let margin = 40
    private static let height = 360
    private static let minimumBar = 4

    static func png(samples: [Float]) -> Data? {
        let slot = barWidth + gap
        let width = 2 * margin + seconds * slot - gap
        guard let context = canvas(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let count = min(seconds, samples.count / rate)
        let levels: [Float] = (0..<count).map { second in
            let slice = samples[(second * rate)..<((second + 1) * rate)]
            return (slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(rate)).squareRoot()
        }
        let loudest = max(levels.max() ?? 0, 1e-9)
        let room = Double(height - 2 * margin)
        context.setFillColor(CGColor(red: 0.35, green: 0.67, blue: 1, alpha: 1))
        for (second, level) in levels.enumerated() {
            let tall = max(Double(minimumBar), room * Double(level / loudest))
            context.fill(CGRect(x: Double(margin + second * slot), y: (Double(height) - tall) / 2, width: Double(barWidth), height: tall))
        }
        return context.makeImage().flatMap(pngData)
    }
}

/// One frame of a video with a timeline strip under it across the whole width: the left edge is the start, the right edge the end,
/// and one marker stands where the frame is.
enum VideoPreview {
    static func png(frame: CGImage, second: Int, duration: Double) -> Data? {
        let width = frame.width, strip = max(12, width / 50)
        guard duration > 0, let context = canvas(width: width, height: frame.height + strip) else { return nil }
        context.draw(frame, in: CGRect(x: 0, y: strip, width: width, height: frame.height))
        context.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: strip))
        let marker = max(4, width / 80)
        let centre = Double(width) * min(1, max(0, Double(second) / duration))
        let left = min(max(0, centre - Double(marker) / 2), Double(width - marker))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: left, y: 0, width: Double(marker), height: Double(strip)))
        return context.makeImage().flatMap(pngData)
    }
}
