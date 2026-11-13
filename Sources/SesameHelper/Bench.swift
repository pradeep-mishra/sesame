import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Darwin
import Foundation
import ImageIO
import SesameEngine

/// `index bench`: times the real pipeline of every kind that is read (photo, PDF, document, audio, video: read, and with
/// the model files the load, the encoder and the swap between models) on sample files it makes itself, then prints one
/// `bench` line, seconds per file of each kind, and exits 0. The samples are made by code into the helper's scratch
/// folder, `$TMPDIR/Sesame-<pid>`, opened only through the readers and `FileGate`, and removed at exit. It touches no picked
/// folder and writes no index and no settings (design sections 2 and 3). Each kind is timed alone, so its number holds
/// the model loads its files need, counted once for the batch.
enum Bench {
    private static let timed = ["photo": 25, "pdf": 4, "doc": 10, "audio": 3, "video": 3]
    private static let kinds = ["photo", "pdf", "doc", "audio", "video"]

    private struct Failed: Error, CustomStringConvertible {
        let description: String
    }

    private struct Pieces {
        var texts: [String] = []
        var images: [PhotoBitmap] = []
        var windows: [[Float]] = []

        mutating func add(_ other: Pieces) {
            texts += other.texts
            images += other.images
            windows += other.windows
        }
    }

    static func run(textModel: String?, mmModel: String?) -> Never {
        signal(SIGPIPE, SIG_IGN)
        pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
        let scratch = Scratch()
        let fake = EmbedderChoice.make(textModel: nil) as? FakeEmbedder
        let models = textModel.flatMap { text in mmModel.map { (text: URL(fileURLWithPath: text), mm: URL(fileURLWithPath: $0)) } }

        var speeds: [String: Double] = [:]
        for kind in kinds {
            do {
                speeds[kind] = try measure(kind, scratch: scratch, fake: fake, models: models)
            } catch {
                fail("\(kind): \(error)", scratch)
            }
        }
        guard let line = try? HelperProtocol.line(for: .bench(speeds: speeds)),
              (try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))) != nil else {
            fail("could not print the bench line", scratch)
        }
        scratch.removeAll()
        exit(0)
    }

    private static func measure(
        _ kind: String, scratch: Scratch, fake: FakeEmbedder?, models: (text: URL, mm: URL)?
    ) throws -> Double {
        let wantBitmap = fake == nil && models != nil
        var paths: [String] = []
        for index in 0...(timed[kind] ?? 0) { paths.append(try sample(kind, index, scratch)) }
        _ = try read(kind, paths.removeFirst(), scratch, wantBitmap)
        let elapsed = try ContinuousClock().measure {
            var pieces = Pieces()
            for path in paths { pieces.add(try read(kind, path, scratch, wantBitmap)) }
            try embed(pieces, fake: fake, models: models)
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return max(seconds / Double(paths.count), 1e-6)
    }

    private static func fail(_ message: String, _ scratch: Scratch) -> Never {
        try? FileHandle.standardError.write(contentsOf: Data("SesameHelper index bench: \(message)\n".utf8))
        scratch.removeAll()
        exit(1)
    }

    private static func embed(_ pieces: Pieces, fake: FakeEmbedder?, models: (text: URL, mm: URL)?) throws {
        if let fake {
            for text in pieces.texts { _ = try fake.embed(text, role: .document) }
            for _ in 0..<(pieces.images.count + pieces.windows.count) { _ = try fake.embed("bench", role: .document) }
            return
        }
        guard let models else { return }
        if !pieces.texts.isEmpty {
            let embedder = LlamaEmbedder(textModel: models.text)
            try embedder.load()
            defer { embedder.unload() }
            for text in pieces.texts { _ = try embedder.embed(text, role: .document) }
        }
        if !pieces.images.isEmpty {
            let model = try PhotoEmbedder(textModel: models.text, mmModel: models.mm)
            defer { model.close() }
            var made = 0
            try model.embed(pieces.images, unitSize: 16) { _, vectors in made += vectors.compactMap { $0 }.count }
            if made != pieces.images.count { throw Failed(description: "the model embedded \(made) of \(pieces.images.count) pictures") }
        }
        if !pieces.windows.isEmpty {
            let model = try PhotoEmbedder(textModel: models.text, mmModel: models.mm, audio: true)
            defer { model.close() }
            var made = 0
            try model.embedAudio(pieces.windows, unitSize: 16) { _, vectors in made += vectors.compactMap { $0 }.count }
            if made != pieces.windows.count { throw Failed(description: "the model embedded \(made) of \(pieces.windows.count) sound windows") }
        }
    }

    private static func read(_ kind: String, _ path: String, _ scratch: Scratch, _ wantBitmap: Bool) throws -> Pieces {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Failed(description: "a sample is gone: \(path)") }
        let identity = FileIdentity(
            size: Int64(info.st_size),
            mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            inode: UInt64(info.st_ino))
        var pieces = Pieces()
        switch kind {
        case "photo":
            let photo = try PhotoReader.read(path: path, expecting: identity, wantBitmap: wantBitmap)
            if let bitmap = photo.bitmap { pieces.images = [bitmap] }
        case "pdf":
            for page in try PdfReader.read(path: path, expecting: identity, firstPage: 1).pages {
                switch page.kind {
                case let .text(text): pieces.texts.append(text)
                case let .scan(ocrText, bitmap):
                    pieces.images.append(bitmap)
                    if !ocrText.isEmpty { pieces.texts.append(ocrText) }
                }
            }
        case "doc":
            pieces.texts = try DocReader.read(path: path, expecting: identity, fromChunk: 0).chunks.map(\.text)
        case "audio":
            let step = try AudioReader.read(
                path: path, expecting: identity, fromSecond: 0, scratch: scratch, shouldStop: { false })
            pieces.windows = step.windows.map(\.samples)
        default:
            let step = try VideoReader.read(
                path: path, expecting: identity, fromSecond: 0, scratch: scratch, shouldStop: { false })
            pieces.images = step.frames.map(\.bitmap)
            pieces.windows = step.windows.map(\.samples)
        }
        return pieces
    }


    private static func sample(_ kind: String, _ index: Int, _ scratch: Scratch) throws -> String {
        switch kind {
        case "photo":
            guard let data = sampleJPEG(index: index) else { throw Failed(description: "could not make a sample photo") }
            return try scratch.write(data, name: "bench-\(index).jpg")
        case "pdf":
            guard let data = samplePDF(index: index) else { throw Failed(description: "could not make a sample PDF") }
            return try scratch.write(data, name: "bench-pdf-\(index).pdf")
        case "doc":
            return try scratch.write(Data(words(seed: index * 7 + 1, characters: 1000).utf8), name: "bench-doc-\(index).txt")
        case "audio":
            return try scratch.write(sampleWAV(index: index), name: "bench-audio-\(index).wav")
        default:
            return try sampleVideo(index: index, scratch: scratch)
        }
    }

    private static let vocabulary = [
        "harbour", "lantern", "ledger", "orchard", "granite", "meadow", "compass", "violin", "quarry", "timber", "saffron",
        "glacier", "anchor", "pepper", "falcon", "marble", "cinder", "willow", "copper", "thistle", "ribbon", "juniper",
        "lagoon", "bramble", "cobalt", "ember", "fennel", "gable", "hollow", "ivory",
    ]

    private static func words(seed: Int, characters: Int) -> String {
        var text = ""
        var state = seed
        while text.count < characters {
            state = (state &* 31 &+ 7) % 1009
            text += vocabulary[state % vocabulary.count] + " "
        }
        return text
    }

    private static func samplePDF(index: Int) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for page in 1...8 {
            context.beginPDFPage(nil)
            let text = words(seed: index * 13 + page, characters: 600)
            if let string = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary) {
                let frame = CTFramesetterCreateFrame(
                    CTFramesetterCreateWithAttributedString(string), CFRange(), CGPath(rect: CGRect(x: 72, y: 300, width: 468, height: 360), transform: nil), nil)
                CTFrameDraw(frame, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A 16 kHz mono 16-bit WAV of 60 s, written byte by byte: silence with a 2 s tone starting at 2, 17, 32 and 47 s, so the
    /// reader makes two windows, as it does for the spoken lines of the 500-file mix.
    private static func sampleWAV(index: Int) -> Data {
        let rate = 16_000, seconds = 60
        var samples = [Int16](repeating: 0, count: rate * seconds)
        let frequency = 330.0 + 55.0 * Double(index)
        for burst in 0..<4 {
            let start = (2 + 15 * burst) * rate
            for offset in 0..<(2 * rate) {
                samples[start + offset] = Int16(0.4 * 32767 * sin(2 * Double.pi * frequency * Double(offset) / Double(rate)))
            }
        }
        let bytes = samples.count * 2
        var data = Data("RIFF".utf8)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        put(UInt32(bytes))
        for sample in samples { put(sample) }
        return data
    }

    /// An mp4 of 30 s at 5 frames a second and 320 x 192: three shots of ten seconds, each a shade with a pattern of lit cells on an
    /// 8 x 8 grid so the reader sees them as different shots, no soundtrack, as the videos of the 500-file mix.
    private static func sampleVideo(index: Int, scratch: Scratch) throws -> String {
        let width = 320, height = 192, fps = 5, seconds = 30
        let path = try scratch.write(Data(), name: "bench-video-\(index).mp4")
        scratch.remove(path: path)
        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 600_000, AVVideoMaxKeyFrameIntervalKey: fps * 2],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failed(description: "the video writer cannot take its input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failed(description: "the video writer did not start: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        let shots = try (0..<3).map { try shot(width: width, height: height, shade: index + $0, row: 1 + (index * 3 + $0) % 63) }
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw Failed(description: "the video writer failed: \(String(describing: writer.error))") }
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard adaptor.append(shots[frame / (fps * 10)], withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else {
                throw Failed(description: "a video frame could not be appended: \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(seconds * fps), timescale: Int32(fps)))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw Failed(description: "the video writer ended \(writer.status.rawValue): \(String(describing: writer.error))") }
        return path
    }

    private static func shot(width: Int, height: Int, shade: Int, row: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &made) == kCVReturnSuccess,
              let buffer = made else { throw Failed(description: "no pixel buffer for a video frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failed(description: "a pixel buffer has no memory") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let full = (b: 40 + (shade * 53) % 190, g: 40 + (shade * 97) % 190, r: 40 + (shade * 151) % 190)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let cell = min(7, y * 8 / height) * 8 + min(7, x * 8 / width)
                let share = (row & cell).nonzeroBitCount % 2 == 1 ? 0.55 : 1.0
                let offset = y * stride + x * 4
                pixels[offset] = UInt8(Double(full.b) * share)
                pixels[offset + 1] = UInt8(Double(full.g) * share)
                pixels[offset + 2] = UInt8(Double(full.r) * share)
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }

    /// A 1600 x 1200 picture: a gradient, a few shapes and three lines of text for Vision to read, different for each
    /// `index`. Generated here, so no image file is bundled.
    private static func sampleJPEG(index: Int) -> Data? {
        let width = 1600, height = 1200
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        func shade(_ step: Int, _ seed: Int) -> CGColor {
            let value = Double((seed &* 37 &+ step &* 91) % 256) / 255
            return CGColor(red: value, green: 1 - value, blue: Double((seed &* 53 &+ step &* 29) % 256) / 255, alpha: 1)
        }
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: space, colors: [shade(1, index), shade(2, index)] as CFArray, locations: nil) {
            context.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        for shape in 0..<6 {
            context.setFillColor(shade(shape + 3, index))
            let box = CGRect(x: (shape * 263 + index * 71) % 1200, y: (shape * 197 + index * 43) % 900, width: 300, height: 220)
            if shape % 2 == 0 { context.fillEllipse(in: box) } else { context.fill(box) }
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 84, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
        let lines = ["Invoice \(1000 + index)", "Total \(40 + index * 7).50 EUR", "Meeting room \(index % 9 + 1)"]
        for (row, text) in lines.enumerated() {
            guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { continue }
            context.textPosition = CGPoint(x: 120, y: 900 - row * 140)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
