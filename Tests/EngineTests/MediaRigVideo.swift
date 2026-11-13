import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

// MARK: plan-5-t3, video clips (AVAssetWriter, no product code)

// plan-5-t3, tester step. What the video rig makes, and why it is not a clip of plain colours:
//   - A SHOT is a picture drawn by this file: a background colour (one of the eight `shades`) with a pattern of "lit" cells on an 8 x 8 grid, a lit
//     cell being the shade at 55 percent. The pattern of a shot is a row (1 to 63) of the 64 x 64 Hadamard matrix, so any two different rows differ
//     in exactly 32 of the 64 cells and exactly 32 cells are lit. Reason: the entry keeps "one frame per shot (8 x 8 hash)" and a clip of plain
//     colours has a flat picture whose 8 x 8 hash is the same for every colour, so a hash-based reader could not tell its shots apart; a pattern
//     differs from the next shot's by 32 bits whatever the hash (mean or gradient) and the shade stays the dominant colour (mean = 0.775 of it).
//   - The expected values are the test's own: a shot's start second, its shade index, the 0.775 factor. The product never makes them.
//   - The independent readers are `ffprobe` (duration, streams) and `ffmpeg` (one frame at a second), used by the rig sanity test and by setup checks.
//   - A clip is written at 5 frames a second (a shot starts on a frame boundary, so a frame at a whole second is exactly the first frame of a shot that
//     starts at that second) with a soundtrack when asked: a WAV the test wrote, encoded to AAC by the writer.

extension MediaRig {
    /// The eight shades of a shot (r, g, b), written by hand.
    static let shades: [(r: Double, g: Double, b: Double)] = [
        (220, 40, 40), (40, 190, 60), (50, 80, 225), (225, 215, 40), (210, 50, 200), (40, 200, 215), (235, 130, 30), (200, 200, 200),
    ]

    /// A lit cell is this share of the shade.
    static let litShare = 0.55

    /// The mean of a picture over its pixels, as a share of the shade: half the cells are lit.
    static let meanShare = 1.0 - 0.5 * (1.0 - litShare)

    struct VideoShot {
        let seconds: Double
        /// 0 to 7, the index into `shades`.
        let shade: Int
        /// 1 to 63, the Hadamard row that lights the cells.
        let row: Int
        /// Cells (0 to 63) whose lit state is toggled after the row is applied: a shot that is almost the same picture as another.
        var flips: [Int] = []
    }

    struct VideoMade {
        let path: String
        let seconds: Double
        let width: Int
        let height: Int
    }

    /// Shots of the given lengths: shot k has shade (first + k) mod 8 and Hadamard row 1 + (k mod 63).
    static func shots(_ durations: [Double], firstShade: Int = 0) -> [VideoShot] {
        durations.enumerated().map { VideoShot(seconds: $0.element, shade: (firstShade + $0.offset) % shades.count, row: 1 + ($0.offset % 63)) }
    }

    /// The second each shot starts at.
    static func shotStarts(_ list: [VideoShot]) -> [Double] {
        var starts: [Double] = []
        var at = 0.0
        for shot in list {
            starts.append(at)
            at += shot.seconds
        }
        return starts
    }

    /// The index of the shot that shows at `second` (a shot owns [its start, the next start)); the last shot owns everything after.
    static func shotIndex(at second: Double, in list: [VideoShot]) -> Int {
        let starts = shotStarts(list)
        var found = 0
        for (index, start) in starts.enumerated() where second >= start { found = index }
        return found
    }

    static func isLit(row: Int, cell: Int, flips: [Int]) -> Bool {
        let base = (row & cell).nonzeroBitCount % 2 == 1
        return flips.contains(cell) ? !base : base
    }

    private static func pixelBuffer(width: Int, height: Int, shot: VideoShot) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &made)
        guard status == kCVReturnSuccess, let buffer = made else { throw MrError("CVPixelBufferCreate gave \(status)") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw MrError("a pixel buffer has no memory") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let colour = shades[shot.shade]
        func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
        let full = (b: byte(colour.b), g: byte(colour.g), r: byte(colour.r))
        let dim = (b: byte(colour.b * litShare), g: byte(colour.g * litShare), r: byte(colour.r * litShare))
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let cellRow = min(7, y * 8 / height)
            for x in 0..<width {
                let cell = cellRow * 8 + min(7, x * 8 / width)
                let c = isLit(row: shot.row, cell: cell, flips: shot.flips) ? dim : full
                let offset = y * stride + x * 4
                pixels[offset] = c.b
                pixels[offset + 1] = c.g
                pixels[offset + 2] = c.r
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }

    /// An mp4 (or mov or m4v, by the extension of `path`) of `shots` at `fps` frames a second, H.264, with an AAC soundtrack when
    /// `soundtrack` names a WAV of the test's own (not longer than the picture). The file has its index at the end, so a cut copy is unreadable.
    @discardableResult
    static func writeVideo(_ path: String, width: Int = 320, height: Int = 192, fps: Int = 5, shots list: [VideoShot], soundtrack: String? = nil) throws -> VideoMade {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        let extensionName = url.pathExtension.lowercased()
        let type: AVFileType = extensionName == "mov" ? .mov : (extensionName == "m4v" ? .m4v : .mp4)
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let totalSeconds = list.reduce(0.0) { $0 + $1.seconds }
        let totalFrames = Int((totalSeconds * Double(fps)).rounded())
        var endFrames: [Int] = []
        var running = 0.0
        for shot in list {
            running += shot.seconds
            endFrames.append(Int((running * Double(fps)).rounded()))
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(600_000, width * height * 4), AVVideoMaxKeyFrameIntervalKey: fps * 2],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(videoInput) else { throw MrError("the writer cannot take a video input") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        if let soundtrack {
            let asset = AVURLAsset(url: URL(fileURLWithPath: soundtrack))
            guard let track = asset.tracks(withMediaType: .audio).first else { throw MrError("the soundtrack \(soundtrack) has no audio track") }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { throw MrError("the soundtrack reader cannot take its output") }
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw MrError("the writer cannot take an audio input") }
            writer.add(input)
            audioInput = input
            audioReader = reader
            audioOutput = output
        }
        guard writer.startWriting() else { throw MrError("the video writer did not start: \(writer.error.map { "\($0)" } ?? "unknown")") }
        writer.startSession(atSourceTime: .zero)
        if let audioReader, !audioReader.startReading() { throw MrError("the soundtrack reader did not start: \(audioReader.error.map { "\($0)" } ?? "unknown")") }

        var buffers: [CVPixelBuffer] = []
        for shot in list { buffers.append(try pixelBuffer(width: width, height: height, shot: shot)) }
        var frame = 0
        var shotIndex = 0
        var nextAudio = audioOutput?.copyNextSampleBuffer()
        let deadline = Date().addingTimeInterval(120)
        func appendVideo() throws -> Bool {
            guard frame < totalFrames, videoInput.isReadyForMoreMediaData else { return false }
            while shotIndex < endFrames.count - 1, frame >= endFrames[shotIndex] { shotIndex += 1 }
            guard adaptor.append(buffers[shotIndex], withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else {
                throw MrError("a frame could not be appended: \(writer.error.map { "\($0)" } ?? "unknown")")
            }
            frame += 1
            return true
        }
        func appendAudio() throws -> Bool {
            guard let sample = nextAudio, let audioInput, audioInput.isReadyForMoreMediaData else { return false }
            guard audioInput.append(sample) else { throw MrError("a soundtrack buffer could not be appended: \(writer.error.map { "\($0)" } ?? "unknown")") }
            nextAudio = audioOutput?.copyNextSampleBuffer()
            return true
        }
        while frame < totalFrames || nextAudio != nil {
            if writer.status == .failed { throw MrError("the video writer failed: \(writer.error.map { "\($0)" } ?? "unknown")") }
            if Date() > deadline {
                throw MrError("writeVideo gave up after 120 s at frame \(frame) of \(totalFrames) with \(nextAudio == nil ? "no" : "more") soundtrack left: neither input became ready")
            }
            let videoTime = frame < totalFrames ? Double(frame) / Double(fps) : Double.infinity
            let audioTime = nextAudio.map { CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp($0)) } ?? Double.infinity
            let moved: Bool
            if videoTime <= audioTime {
                moved = try appendVideo() ? true : try appendAudio()
            } else {
                moved = try appendAudio() ? true : try appendVideo()
            }
            if !moved { Thread.sleep(forTimeInterval: 0.001) }
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(totalFrames), timescale: Int32(fps)))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw MrError("the video writer ended \(writer.status.rawValue): \(writer.error.map { "\($0)" } ?? "unknown")") }
        return VideoMade(path: path, seconds: totalSeconds, width: width, height: height)
    }

    // MARK: colours of a picture

    static func meanColor(rgb: [UInt8]) -> (r: Double, g: Double, b: Double) {
        guard rgb.count >= 3 else { return (0, 0, 0) }
        var r = 0.0, g = 0.0, b = 0.0
        var index = 0
        while index + 2 < rgb.count {
            r += Double(rgb[index]); g += Double(rgb[index + 1]); b += Double(rgb[index + 2])
            index += 3
        }
        let count = Double(rgb.count / 3)
        return (r / count, g / count, b / count)
    }

    /// The mean colour of an image, taken on a 32 x 32 copy of it.
    static func meanColor(of image: CGImage) -> (r: Double, g: Double, b: Double)? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(side * side * 3)
        for index in stride(from: 0, to: pixels.count, by: 4) { rgb += [pixels[index], pixels[index + 1], pixels[index + 2]] }
        return meanColor(rgb: rgb)
    }

    /// The shade a picture of that mean colour is closest to (the means of a shot are the shades at `meanShare`).
    static func nearestShade(_ mean: (r: Double, g: Double, b: Double)) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (index, shade) in shades.enumerated() {
            let dr = mean.r - shade.r * meanShare, dg = mean.g - shade.g * meanShare, db = mean.b - shade.b * meanShare
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance { bestDistance = distance; best = index }
        }
        return best
    }

    // MARK: the independent readers (ffprobe, ffmpeg)

    static let ffprobe = "/opt/homebrew/bin/ffprobe"
    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    /// The duration ffprobe reads, or nil when ffprobe cannot read the file.
    static func probeSeconds(_ path: String) -> Double? {
        guard let ran = mrRun(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path], limit: 60),
              ran.status == 0 else { return nil }
        return Double(ran.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The number of video and of audio streams ffprobe finds, or nil when it cannot read the file.
    static func probeStreams(_ path: String) -> (video: Int, audio: Int)? {
        guard let ran = mrRun(ffprobe, ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", path], limit: 60),
              ran.status == 0 else { return nil }
        let kinds = ran.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return (kinds.filter { $0 == "video" }.count, kinds.filter { $0 == "audio" }.count)
    }

    /// The mean colour of the frame ffmpeg decodes at `second` (a 32 x 32 picture), or nil.
    static func ffmpegMean(_ path: String, at second: Double) -> (r: Double, g: Double, b: Double)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-ss", String(second), "-i", path, "-frames:v", "1", "-s", "32x32", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count == 32 * 32 * 3 else { return nil }
        return meanColor(rgb: [UInt8](data))
    }

    /// The files of a clip's cut: the first `bytes` bytes.
    static func cutCopy(of path: String, to cut: String, fraction: Double) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        try data.prefix(Int(Double(data.count) * fraction)).write(to: URL(fileURLWithPath: cut))
    }
}
