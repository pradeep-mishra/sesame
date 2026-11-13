import AVFoundation
import CoreGraphics
import Foundation

/// One kept frame of a video: its whole second and the picture at the size the encoder takes for a video frame (70 soft tokens).
public struct VideoFrame: Sendable {
    public let second: Int
    public let bitmap: PhotoBitmap
}

/// What one call of `VideoReader.read` returns: the file's length, the frames kept in the step, the windows of its
/// soundtrack that start in the step, where the next step begins (`readTo`, whole seconds) and the words of its name.
public struct VideoStep: Sendable {
    public let duration: Double
    public let frames: [VideoFrame]
    public let windows: [AudioWindow]
    public let readTo: Int
    /// True when nothing is left to read after this step; `readTo` is then the length rounded up.
    public let finished: Bool
    public let nameWords: String
}

/// One picture of a video for the pane.
public struct VideoStill: @unchecked Sendable {
    public let image: CGImage
    public let duration: Double
}

public enum VideoReadError: Error, Equatable {
    /// The path is gone, is not a regular video file any more, or `Rules.admit` no longer takes it.
    case notAdmitted
    /// Its size, modified time or inode differ from `expecting`, before or after the read.
    case changed
    /// The bytes could not be got: the process may not open the file. The caller leaves it to be tried again.
    case cannotOpen
    /// The bytes were read and the system decoder takes no picture and no sound from them.
    case unreadable
}

/// Video file to frames and sound windows (design section 4, D4 and D13 of plan 5): the bytes come from `FileGate`, one
/// copy is staged in the helper's scratch folder for the decoder and removed when the call returns. A frame is taken every
/// `frameSeconds` at exactly that second and kept when its 8 x 8 hash differs from the last kept frame's by more than
/// `shotBits` bits. The soundtrack is cut to a 16 kHz WAV, also staged and removed, and read by `AudioReader`.
public enum VideoReader {
    public static let frameSeconds = 3
    /// One call reads the frames and windows that start in this many seconds.
    public static let stepSeconds = 180
    public static let shotBits = 6

    private static let bitmapBudget = 70
    private static let rate = 16_000
    /// The picture is decoded no larger than this, whatever the clip: the encoder takes far fewer pixels.
    private static let decodeSide = 1024
    private static let hashMargin = 3.0

    public static func read(
        path: String, expecting: FileIdentity, fromSecond: Int, scratch: Scratch, shouldStop: () -> Bool
    ) throws -> VideoStep {
        try opened(path, expecting, scratch) { asset, media in
            let from = max(0, fromSecond)
            let limit = from + stepSeconds
            var frames: [VideoFrame] = []
            if media.hasVideo {
                let generator = generator(for: asset, maxSide: decodeSide)
                var tried = 0
                var decoded = 0
                var lastHash: UInt64?
                var second = from
                while Double(second) < min(Double(limit), media.duration) {
                    if shouldStop() { throw MediaStopped() }
                    tried += 1
                    if let image = try? generator.copyCGImage(at: time(Double(second)), actualTime: nil),
                       let bitmap = bitmap(of: image) {
                        decoded += 1
                        let hash = shotHash(bitmap)
                        if lastHash.map({ ($0 ^ hash).nonzeroBitCount > shotBits }) ?? true {
                            frames.append(VideoFrame(second: second, bitmap: bitmap))
                            lastHash = hash
                        }
                    }
                    second += frameSeconds
                }
                if tried > 0 && decoded == 0 { throw VideoReadError.unreadable }
            }
            var windows: [AudioWindow] = []
            if media.hasAudio, Double(from) < media.duration {
                if shouldStop() { throw MediaStopped() }
                windows = try soundtrack(of: asset, from: from, duration: media.duration, scratch: scratch, shouldStop: shouldStop)
            }
            let finished = Double(limit) >= media.duration
            return VideoStep(
                duration: media.duration, frames: frames, windows: windows,
                readTo: finished ? Int(media.duration.rounded(.up)) : limit, finished: finished,
                nameWords: PhotoReader.nameWords(for: path))
        }
    }

    /// The picture at whole second `second`, never an earlier frame, its longest side at most `maxSide`. A second at or past
    /// the end gives the last frame.
    public static func frame(
        path: String, expecting: FileIdentity, second: Int, maxSide: Int, scratch: Scratch, shouldStop: () -> Bool
    ) throws -> VideoStill {
        try opened(path, expecting, scratch) { asset, media in
            guard media.hasVideo else { throw VideoReadError.unreadable }
            if shouldStop() { throw MediaStopped() }
            let at = min(Double(max(0, second)), max(0, media.duration - 0.05))
            do {
                let image = try generator(for: asset, maxSide: max(1, maxSide)).copyCGImage(at: time(at), actualTime: nil)
                return VideoStill(image: image, duration: media.duration)
            } catch { throw VideoReadError.unreadable }
        }
    }

    // MARK: the file

    private struct Media: Sendable {
        /// The picture's length when there is a picture, else the sound's.
        let duration: Double
        let hasVideo: Bool
        let hasAudio: Bool
    }

    /// Admission, identity before and after, `FileGate` for the bytes, one staged copy opened with the system decoder and
    /// removed on every way out. Gives `body` the asset and what is in it.
    private static func opened<T>(
        _ path: String, _ expecting: FileIdentity, _ scratch: Scratch, _ body: (AVURLAsset, Media) throws -> T
    ) throws -> T {
        guard let admitted = Rules.admit(path: path), admitted.kind == "video" else { throw VideoReadError.notAdmitted }
        guard FileIdentity.of(path: path) == expecting else { throw VideoReadError.changed }
        let data: Data
        do { data = try FileGate.read(admitted) } catch { throw VideoReadError.cannotOpen }
        guard FileIdentity.of(path: path) == expecting else { throw VideoReadError.changed }
        let copy: String
        do {
            copy = try scratch.write(data, name: UUID().uuidString + "." + (path as NSString).pathExtension.lowercased())
        } catch { throw VideoReadError.cannotOpen }
        defer { scratch.remove(path: copy) }
        let asset = AVURLAsset(url: URL(fileURLWithPath: copy))
        guard let media = blocking({ try await probe(asset) }) else { throw VideoReadError.unreadable }
        return try body(asset, media)
    }

    private static func probe(_ asset: AVURLAsset) async throws -> Media {
        guard try await asset.load(.isReadable) else { throw VideoReadError.unreadable }
        let whole = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard !video.isEmpty || !audio.isEmpty else { throw VideoReadError.unreadable }
        var duration = whole
        if let track = video.first {
            let end = try await track.load(.timeRange).end.seconds
            if end.isFinite, end > 0 { duration = end }
        }
        guard duration.isFinite, duration > 0 else { throw VideoReadError.unreadable }
        return Media(duration: duration, hasVideo: !video.isEmpty, hasAudio: !audio.isEmpty)
    }

    /// A value AVFoundation has not marked `Sendable` (a track), handed from the loading task to the one waiting for it.
    private struct Handoff<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private final class Outcome<T: Sendable>: @unchecked Sendable {
        var result: T?
    }

    /// Runs `work` to its end on another thread while this one waits; nil when it throws.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> T? {
        let outcome = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            outcome.result = try? await work()
            done.signal()
        }
        done.wait()
        return outcome.result
    }

    // MARK: pictures

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Zero tolerance before, so the frame of second 42 is never the frame of second 41; a twentieth of a second after.
    private static func generator(for asset: AVURLAsset, maxSide: Int) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        return generator
    }

    /// The picture drawn at the size the encoder wants for 70 soft tokens, as packed RGB.
    private static func bitmap(of image: CGImage) -> PhotoBitmap? {
        guard let target = PhotoReader.targetSize(height: image.height, width: image.width, budget: bitmapBudget) else { return nil }
        let width = target.width, height = target.height
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return PhotoBitmap(width: width, height: height, rgb: rgb)
    }

    /// The 8 x 8 mean hash of a picture: a cell is a 1 when its brightness is more than `hashMargin` above the mean of the cells,
    /// so a flat picture hashes to zero whatever noise the codec left in it.
    private static func shotHash(_ bitmap: PhotoBitmap) -> UInt64 {
        let width = bitmap.width, height = bitmap.height
        var cells = [Double](repeating: 0, count: 64)
        for row in 0..<8 {
            for column in 0..<8 {
                var sum = 0.0
                var count = 0
                for y in (row * height / 8)..<((row + 1) * height / 8) {
                    for x in (column * width / 8)..<((column + 1) * width / 8) {
                        let at = (y * width + x) * 3
                        sum += 0.299 * Double(bitmap.rgb[at]) + 0.587 * Double(bitmap.rgb[at + 1]) + 0.114 * Double(bitmap.rgb[at + 2])
                        count += 1
                    }
                }
                cells[row * 8 + column] = count > 0 ? sum / Double(count) : 0
            }
        }
        let mean = cells.reduce(0, +) / 64
        var hash: UInt64 = 0
        for (index, value) in cells.enumerated() where value > mean + hashMargin { hash |= 1 << UInt64(index) }
        return hash
    }

    // MARK: the soundtrack

    /// The windows of the soundtrack that start in the step beginning at `from`: the sound from there on (the step and one
    /// window more, no further than the end) is cut to a 16 kHz mono WAV in the scratch folder and `AudioReader` finds the
    /// windows in it, so the lattice and the silence rule are its own. A soundtrack that cannot be decoded gives no window.
    private static func soundtrack(
        of asset: AVURLAsset, from: Int, duration: Double, scratch: Scratch, shouldStop: () -> Bool
    ) throws -> [AudioWindow] {
        let length = min(Double(stepSeconds + AudioReader.windowSeconds), duration - Double(from))
        guard length > 0, let loaded = blocking({ Handoff(try await asset.loadTracks(withMediaType: .audio).first) }),
              let track = loaded.value, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: time(Double(from)), duration: time(length))
        guard reader.startReading() else { return [] }
        let wanted = Int((length * Double(rate)).rounded()) * 2
        var pcm = Data()
        var sinceCheck = 0
        while pcm.count < wanted, let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block)
            var chunk = Data(count: count)
            let copied = chunk.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: base) == kCMBlockBufferNoErr
            }
            guard copied else { continue }
            pcm.append(chunk)
            sinceCheck += count
            if sinceCheck >= rate * 2 {
                sinceCheck = 0
                if shouldStop() {
                    reader.cancelReading()
                    throw MediaStopped()
                }
            }
        }
        reader.cancelReading()
        guard pcm.count >= rate * 2 else { return [] }
        let wav: String
        do { wav = try scratch.write(wavFile(pcm.prefix(wanted)), name: UUID().uuidString + ".wav") } catch { return [] }
        defer { scratch.remove(path: wav) }
        guard let identity = FileIdentity.of(path: wav) else { return [] }
        let step: AudioStep
        do {
            step = try AudioReader.read(path: wav, expecting: identity, fromSecond: 0, scratch: scratch, shouldStop: shouldStop)
        } catch is MediaStopped {
            throw MediaStopped()
        } catch { return [] }
        return step.windows.filter { $0.start < stepSeconds }.map {
            AudioWindow(start: $0.start + from, end: $0.end + from, samples: $0.samples)
        }
    }

    /// A 16-bit mono WAV file of `pcm` at 16 kHz.
    private static func wavFile(_ pcm: Data) -> Data {
        var file = Data()
        func number<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
        file.append(contentsOf: Array("RIFF".utf8))
        number(UInt32(36 + pcm.count))
        file.append(contentsOf: Array("WAVEfmt ".utf8))
        number(UInt32(16))
        number(UInt16(1))
        number(UInt16(1))
        number(UInt32(rate))
        number(UInt32(rate * 2))
        number(UInt16(2))
        number(UInt16(16))
        file.append(contentsOf: Array("data".utf8))
        number(UInt32(pcm.count))
        file.append(pcm)
        return file
    }
}
