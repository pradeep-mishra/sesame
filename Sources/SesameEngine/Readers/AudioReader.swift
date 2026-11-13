import AVFoundation
import Foundation

/// One window of a recording as the audio encoder takes it: 16 kHz mono samples, `end - start` seconds of them.
public struct AudioWindow: Sendable {
    /// Whole seconds from the start of the file.
    public let start: Int
    public let end: Int
    public let samples: [Float]
}

/// What one call of `AudioReader.read` returns: the file's length, the windows that start in the step, where the next
/// step begins (`readTo`, whole seconds) and the words of the file's own name and folder.
public struct AudioStep: Sendable {
    public let duration: Double
    public let windows: [AudioWindow]
    public let readTo: Int
    /// True when nothing is left to read after this step; `readTo` is then the length rounded up.
    public let finished: Bool
    public let nameWords: String
}

public enum AudioReadError: Error, Equatable {
    /// The path is gone, is not a regular audio file any more, or `Rules.admit` no longer takes it.
    case notAdmitted
    /// Its size, modified time or inode differ from `expecting`, before or after the read.
    case changed
    /// The bytes could not be got: the process may not open the file. The caller leaves it to be tried again.
    case cannotOpen
    /// The bytes were read and the system decoder takes no audio from them.
    case unreadable
}

/// `shouldStop` said so: the call ended between two decoding steps and returned nothing.
public struct MediaStopped: Error, Equatable {
    public init() {}
}

/// Audio file to 30 second windows (design section 4, D4 and D5 of plan 5): the bytes come from `FileGate`, one copy is
/// staged in the helper's scratch folder for the decoder and removed when the call returns. A window starts at the first
/// sound at or after the previous start plus 25 s, so silence is skipped and "Opens at" is where the sound begins.
public enum AudioReader {
    public static let windowSeconds = 30
    public static let strideSeconds = 25
    /// One call reads the windows that start in this many seconds (at most 20).
    public static let stepSeconds = 500
    /// A 0.5 s frame at or above this RMS is sound: about -54 dBFS.
    public static let silenceRMS: Float = 0.002

    private static let rate = 16_000
    private static let frameSamples = rate / 2

    public static func read(
        path: String, expecting: FileIdentity, fromSecond: Int, scratch: Scratch, shouldStop: () -> Bool
    ) throws -> AudioStep {
        try opened(path, expecting, scratch) { file, duration in
            let from = max(0, fromSecond)
            let limit = from + stepSeconds
            let total = Int(duration.rounded(.up))
            var windows: [AudioWindow] = []
            var next = from
            if Double(from) < duration {
                let samples = try decode(file, from: from, to: min(duration, Double(limit + windowSeconds)), shouldStop)
                let levels = frameLevels(samples)
                let scanEnd = min(Double(limit), duration)
                while let start = sound(in: levels, from: from, notBefore: next, before: scanEnd) {
                    windows.append(window(samples, from: from, start: start, total: total))
                    next = start + strideSeconds
                }
            }
            let finished = Double(limit) >= duration || Double(next) >= duration
            return AudioStep(
                duration: duration, windows: windows, readTo: finished ? total : max(limit, next), finished: finished,
                nameWords: PhotoReader.nameWords(for: path))
        }
    }

    /// The window the index stored at `start`, decoded again for the pane: no search for a sound, the start is the stored
    /// one. nil when `start` is at or after the end of the file.
    public static func window(
        path: String, expecting: FileIdentity, start: Int, scratch: Scratch, shouldStop: () -> Bool
    ) throws -> AudioWindow? {
        try opened(path, expecting, scratch) { file, duration in
            guard start >= 0, Double(start) < duration else { return nil }
            let samples = try decode(file, from: start, to: min(duration, Double(start + windowSeconds)), shouldStop)
            return window(samples, from: start, start: start, total: Int(duration.rounded(.up)))
        }
    }

    // MARK: windows

    /// The window of `samples` (which begin at second `from`) that starts at second `start`, exactly `end - start` seconds of samples.
    private static func window(_ samples: [Float], from: Int, start: Int, total: Int) -> AudioWindow {
        let end = min(start + windowSeconds, total)
        let wanted = (end - start) * rate
        let low = min((start - from) * rate, samples.count)
        var slice = Array(samples[low..<min(low + wanted, samples.count)])
        if slice.count < wanted { slice += [Float](repeating: 0, count: wanted - slice.count) }
        return AudioWindow(start: start, end: end, samples: slice)
    }

    /// RMS of each 0.5 s frame (the last may be shorter).
    private static func frameLevels(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count, by: frameSamples).map { low in
            let frame = samples[low..<min(low + frameSamples, samples.count)]
            return (frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        }
    }

    /// The whole second of the first sound frame that starts at or after second `next` and before `scanEnd`.
    private static func sound(in levels: [Float], from: Int, notBefore next: Int, before scanEnd: Double) -> Int? {
        var index = (next - from) * 2
        while index < levels.count, Double(from) + Double(index) / 2 < scanEnd {
            if levels[index] >= silenceRMS { return from + index / 2 }
            index += 1
        }
        return nil
    }

    // MARK: the file

    /// Admission, identity before and after, `FileGate` for the bytes, one staged copy opened with the system decoder and
    /// removed on every way out. Gives `body` the file and its length in seconds.
    private static func opened<T>(
        _ path: String, _ expecting: FileIdentity, _ scratch: Scratch, _ body: (AVAudioFile, Double) throws -> T
    ) throws -> T {
        guard let admitted = Rules.admit(path: path), admitted.kind == "audio" else { throw AudioReadError.notAdmitted }
        guard FileIdentity.of(path: path) == expecting else { throw AudioReadError.changed }
        let data: Data
        do { data = try FileGate.read(admitted) } catch { throw AudioReadError.cannotOpen }
        guard FileIdentity.of(path: path) == expecting else { throw AudioReadError.changed }
        let copy: String
        do {
            copy = try scratch.write(data, name: UUID().uuidString + "." + (path as NSString).pathExtension.lowercased())
        } catch { throw AudioReadError.cannotOpen }
        defer { scratch.remove(path: copy) }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: URL(fileURLWithPath: copy)) } catch { throw AudioReadError.unreadable }
        let fileRate = file.processingFormat.sampleRate
        guard fileRate > 0, file.processingFormat.channelCount > 0, file.length >= 0 else { throw AudioReadError.unreadable }
        return try body(file, Double(file.length) / fileRate)
    }

    // MARK: decoding

    /// The samples from second `from` to second `to` as 16 kHz mono: one second of the file is decoded between two stop checks.
    private static func decode(_ file: AVAudioFile, from: Int, to: Double, _ shouldStop: () -> Bool) throws -> [Float] {
        let format = file.processingFormat
        let fileRate = format.sampleRate
        let first = AVAudioFramePosition((Double(from) * fileRate).rounded())
        let last = min(file.length, AVAudioFramePosition((to * fileRate).rounded()))
        guard last > first else { return [] }
        let chunk = AVAudioFrameCount(fileRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw AudioReadError.unreadable }
        var resampler: Resampler?
        if fileRate != Double(rate) { resampler = try Resampler(from: fileRate, to: Double(rate), chunk: chunk) }
        var out: [Float] = []
        out.reserveCapacity(Int((to - Double(from)) * Double(rate)) + rate)
        // setFramePosition raises an uncatchable NSException on damaged files, even for 0; a fresh file already sits at 0.
        if first > 0 { file.framePosition = first }
        var position = first
        while position < last {
            if shouldStop() { throw MediaStopped() }
            let count = AVAudioFrameCount(min(Int64(chunk), last - position))
            do { try file.read(into: buffer, frameCount: count) } catch { throw AudioReadError.unreadable }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let mono = mixDown(channels, channels: Int(format.channelCount), frames: Int(buffer.frameLength))
            position += AVAudioFramePosition(buffer.frameLength)
            if let resampler {
                out += try resampler.convert(mono, last: position >= last)
            } else {
                out += mono
            }
        }
        return out
    }

    private static func mixDown(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channels count: Int, frames: Int) -> [Float] {
        if count == 1 { return Array(UnsafeBufferPointer(start: channels[0], count: frames)) }
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<count {
            let samples = channels[channel]
            for frame in 0..<frames { mono[frame] += samples[frame] }
        }
        let scale = 1 / Float(count)
        for frame in 0..<frames { mono[frame] *= scale }
        return mono
    }

    /// Mono at one rate to mono at another, a chunk at a time, keeping the converter's state between chunks.
    private final class Resampler: @unchecked Sendable {
        private let converter: AVAudioConverter
        private let input: AVAudioPCMBuffer
        private let output: AVAudioPCMBuffer
        private var offered = false
        private var ended = false

        init(from: Double, to: Double, chunk: AVAudioFrameCount) throws {
            guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
                  let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat),
                  let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
                  let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(chunk) * to / from) + 1024)
            else { throw AudioReadError.unreadable }
            self.converter = converter
            self.input = input
            self.output = output
        }

        func convert(_ mono: [Float], last: Bool) throws -> [Float] {
            input.frameLength = AVAudioFrameCount(mono.count)
            if let target = input.floatChannelData?[0] { mono.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: mono.count) } }
            offered = false
            ended = last
            var failure: NSError?
            output.frameLength = 0
            _ = converter.convert(to: output, error: &failure) { [self] _, status in
                if offered {
                    status.pointee = ended ? .endOfStream : .noDataNow
                    return nil
                }
                offered = true
                status.pointee = .haveData
                return input
            }
            if failure != nil { throw AudioReadError.unreadable }
            guard output.frameLength > 0, let samples = output.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        }
    }
}
