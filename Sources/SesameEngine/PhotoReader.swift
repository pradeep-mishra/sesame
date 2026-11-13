import CLlama
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// What a file looked like: the three numbers the index compares (design section 9, "reading a file's change").
public struct FileIdentity: Equatable, Sendable {
    public let size: Int64
    public let mtimeNs: Int64
    public let inode: UInt64

    public init(size: Int64, mtimeNs: Int64, inode: UInt64) {
        self.size = size
        self.mtimeNs = mtimeNs
        self.inode = inode
    }

    /// Reads the three numbers with `lstat`, or nil when the path is gone.
    static func of(path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(
            size: Int64(info.st_size),
            mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            inode: UInt64(info.st_ino))
    }
}

/// A picture as the vision encoder takes it: packed RGB, already at its final size.
public struct PhotoBitmap: Sendable {
    public let width: Int
    public let height: Int
    public let rgb: [UInt8]
}

/// What reading one photo gives: the words of its names, the text Vision read in it and, when asked, the pixels.
public struct PhotoPieces: Sendable {
    public let nameWords: String
    public let ocrText: String
    public let bitmap: PhotoBitmap?
}

public enum PhotoReadError: Error, Equatable {
    /// The path is gone, is not a regular photo any more, or `Rules.admit` no longer takes it.
    case notAdmitted
    /// Its size, modified time or inode differ from `expecting`, before or after the read.
    case changed
    /// The bytes could not be got: the process may not open the file (no permission, I/O error, time out) or reading
    /// it failed. Nothing is known about the picture, so the caller leaves it to be tried again.
    case cannotOpen
    /// The bytes were read and ImageIO cannot decode them.
    case unreadable
}

/// Photo file to pieces (design section 4): stat before and after, ImageIO for the pixels at 140 soft tokens, Vision
/// accurate text recognition on the full image. The file is opened only through `FileGate`.
public enum PhotoReader {
    /// Soft tokens an image is sized for.
    static let imageBudget = 140

    public static func read(path: String, expecting: FileIdentity, wantBitmap: Bool) throws -> PhotoPieces {
        guard let admitted = Rules.admit(path: path), admitted.kind == "photo" else { throw PhotoReadError.notAdmitted }
        guard FileIdentity.of(path: path) == expecting else { throw PhotoReadError.changed }
        let data: Data
        do { data = try FileGate.read(admitted) } catch { throw PhotoReadError.cannotOpen }
        guard FileIdentity.of(path: path) == expecting else { throw PhotoReadError.changed }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth > 0, pixelHeight > 0,
              let full = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              CGImageSourceGetStatus(source) == .statusComplete,
              endsAsItShould(data) else { throw PhotoReadError.unreadable }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up

        let text = try recognizeText(in: full, orientation: orientation)
        var bitmap: PhotoBitmap?
        if wantBitmap {
            let turned = orientation.rawValue >= 5
            guard let made = Self.bitmap(
                source: source, width: turned ? pixelHeight : pixelWidth, height: turned ? pixelWidth : pixelHeight)
            else { throw PhotoReadError.unreadable }
            bitmap = made
        }
        return PhotoPieces(nameWords: nameWords(for: path), ocrText: text, bitmap: bitmap)
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let pngIEND: [UInt8] = [0x49, 0x45, 0x4E, 0x44]

    /// ImageIO calls a PNG that stops at a chunk boundary, and a JPEG cut in its scan data, complete: the structure is
    /// walked to the end marker (PNG IEND, JPEG EOI). Data after the marker (a motion photo's video) is ignored.
    private static func endsAsItShould(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        if bytes.starts(with: pngSignature) { return pngReachesEnd(bytes) }
        if bytes.starts(with: [0xFF, 0xD8]) { return jpegReachesEnd(bytes) }
        return true
    }

    /// Chunks (length, type, data, CRC) from the signature on: true when IEND is reached with every chunk inside the file.
    private static func pngReachesEnd(_ bytes: [UInt8]) -> Bool {
        var position = pngSignature.count
        while position + 12 <= bytes.count {
            let length = bytes[position..<position + 4].reduce(0) { $0 << 8 | Int($1) }
            let next = position + 12 + length
            guard next <= bytes.count else { return false }
            if bytes[position + 4..<position + 8].elementsEqual(pngIEND) { return true }
            position = next
        }
        return false
    }

    /// Marker segments from SOI on: a segment is skipped by its length (so an EXIF thumbnail's FF D9 inside APP1 does not
    /// count), the entropy-coded data after SOS is scanned to the next real marker, and true is returned at EOI.
    private static func jpegReachesEnd(_ bytes: [UInt8]) -> Bool {
        let count = bytes.count
        var position = 2
        while position < count {
            guard bytes[position] == 0xFF else { return false }
            while position < count, bytes[position] == 0xFF { position += 1 }  // fill bytes
            guard position < count else { return false }
            let marker = bytes[position]
            position += 1
            if marker == 0xD9 { return true }
            if marker == 0x00 { return false }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { continue }
            guard position + 2 <= count else { return false }
            let length = Int(bytes[position]) << 8 | Int(bytes[position + 1])
            guard length >= 2, position + length <= count else { return false }
            position += length
            guard marker == 0xDA else { continue }
            while position < count {
                guard bytes[position] == 0xFF else { position += 1; continue }
                guard position + 1 < count else { return false }
                let next = bytes[position + 1]
                if next == 0x00 || (0xD0...0xD7).contains(next) { position += 2 } else { break }
            }
        }
        return false
    }

    /// The words of a file's own name and of the folder it is in (design section 4: every file gets a `name` passage).
    public static func nameWords(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return [url.lastPathComponent, url.deletingLastPathComponent().lastPathComponent].joined(separator: " ")
    }

    /// Vision's accurate recognition, one line of text per recognized line. A picture with no text gives "" and is still
    /// found by meaning and by name. A Vision failure is retried once (`RecognitionRetry`) and then thrown as `RecognitionFailed`.
    static func recognizeText(in image: CGImage, orientation: CGImagePropertyOrientation) throws -> String {
        try RecognitionRetry.run {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
            try handler.perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
    }

    /// The thumbnail ImageIO makes at the size the encoder wants, drawn at exactly that size as packed RGB.
    private static func bitmap(source: CGImageSource, width: Int, height: Int) -> PhotoBitmap? {
        guard let target = targetSize(height: height, width: width, budget: imageBudget) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return packed(thumbnail, height: target.height, width: target.width)
    }

    /// The picture drawn at the size the encoder wants for it (`targetSize` of its own size), as packed RGB.
    static func bitmap(of image: CGImage) -> PhotoBitmap? {
        guard let target = targetSize(height: image.height, width: image.width, budget: imageBudget) else { return nil }
        return packed(image, height: target.height, width: target.width)
    }

    private static func packed(_ image: CGImage, height h: Int, width w: Int) -> PhotoBitmap? {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for pixel in 0..<(w * h) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return PhotoBitmap(width: w, height: h, rgb: rgb)
    }

    /// The reference image processor's size (transformers' Gemma 4): scale to fill `budget` soft tokens, each 3 x 3
    /// patches of 16 px, keeping the aspect ratio, each side rounded down to a multiple of 48 px.
    static func targetSize(height: Int, width: Int, budget: Int) -> (height: Int, width: Int)? {
        let patch = 16, pooling = 3
        let maxPatches = budget * pooling * pooling
        let factor = (Double(maxPatches * patch * patch) / Double(height * width)).squareRoot()
        let side = pooling * patch
        var targetHeight = Int((factor * Double(height) / Double(side)).rounded(.down)) * side
        var targetWidth = Int((factor * Double(width) / Double(side)).rounded(.down)) * side
        if targetHeight == 0 && targetWidth == 0 { return nil }
        let maxSide = (maxPatches / (pooling * pooling)) * side
        if targetHeight == 0 {
            targetHeight = side
            targetWidth = min(width / height * side, maxSide)
        } else if targetWidth == 0 {
            targetWidth = side
            targetHeight = min(height / width * side, maxSide)
        }
        return (targetHeight, targetWidth)
    }
}

public enum PhotoEmbedderError: Error, Equatable {
    case failed(String)
}

/// EmbeddingGemma 2 on llama.cpp (Metal) for pictures: the vision encoder (mtmd) feeds the text model, whose
/// mean-pooled output, scaled to length 1, is the vector. Several pictures share one `llama_process` call, each its own
/// sequence (a unit). Making one loads both model files; `close()` frees them. One thread at a time. Made with `audio` it
/// loads the audio tower too (about 312 MB more) and embeds 30 s windows of sound the same way; made without, it skips it.
public final class PhotoEmbedder {
    /// One input must fit one micro-batch: 2048 tokens, the reference's cut; a unit holds as many as fit.
    private static let maxTokens = 2048
    private static let maxSequences = 16
    /// A unit of audio windows holds at most this many (design section 8, D10).
    static let audioUnitWindows = 4

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var media: OpaquePointer?
    private var batch: OpaquePointer?
    private var embeddingSize = 0
    private var rowSize = 0
    private var sequences: Int32 = 0
    private var tokens = 0
    private var position: llama_pos = 0

    public init(textModel: URL, mmModel: URL, audio: Bool = false) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(textModel.path, modelParams) else {
            throw PhotoEmbedderError.failed("can't load the text model")
        }
        var params = llama_context_default_params()
        params.n_ctx = UInt32(Self.maxTokens)
        params.n_batch = UInt32(Self.maxTokens)
        params.n_ubatch = UInt32(Self.maxTokens)
        params.n_seq_max = UInt32(Self.maxSequences)
        params.kv_unified = true
        params.embeddings = true
        params.pooling_type = LLAMA_POOLING_TYPE_MEAN
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw PhotoEmbedderError.failed("can't create a llama.cpp context")
        }
        var mediaParams = mtmd_context_params_default()
        mediaParams.use_gpu = true
        mediaParams.print_timings = false
        mediaParams.warmup = true
        mediaParams.image_min_tokens = 1  // never rescale: pictures arrive at their final size
        mediaParams.image_max_tokens = 1120
        mediaParams.audio_only = audio
        mediaParams.vision_only = !audio  // pictures never need the mmproj's audio tower (about 312 MB); scripts/llama.cpp-vision-only.patch
        guard let media = mtmd_init_from_file(mmModel.path, model, mediaParams) else {
            llama_free(context)
            llama_model_free(model)
            throw PhotoEmbedderError.failed("can't load the vision model")
        }
        guard !audio || (mtmd_support_audio(media) && mtmd_get_audio_sample_rate(media) == 16_000) else {
            mtmd_free(media)
            llama_free(context)
            llama_model_free(model)
            throw PhotoEmbedderError.failed("the model takes no 16 kHz audio")
        }
        self.model = model
        self.context = context
        self.media = media
        batch = llama_batch_ext_init(context)
        embeddingSize = Int(llama_model_n_embd_out(model))
        rowSize = Int(llama_model_n_embd_inp(model))
    }

    deinit { close() }

    public func close() {
        if let batch { llama_batch_ext_free(batch) }
        if let media { mtmd_free(media) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        (batch, media, context, model) = (nil, nil, nil, nil)
    }

    /// Embeds `images` in units of at most `unitSize` (and fewer when the tokens would not fit one batch). After each
    /// unit, `unit` gets the range of images it covered and one vector per image of the range, nil for a picture the
    /// encoder cannot take. A failed model call throws.
    public func embed(
        _ images: [PhotoBitmap], unitSize: Int, unit: (Range<Int>, [[Float]?]) throws -> Void
    ) throws {
        try embedSteps(images, unitSize: unitSize) { step in
            if case let .done(range, vectors) = step { try unit(range, vectors) }
        }
    }

    /// What `embedSteps` tells its caller.
    public enum EmbedStep {
        /// About to run a model call that holds the inputs of these images (their indexes in `images`): the picture being
        /// tokenized and encoded, then the whole unit in the text model. A death now belongs to these images alone.
        case inFlight([Int])
        /// A unit finished: the range of images it covered and one vector per image, nil for a picture the encoder cannot take.
        case done(Range<Int>, [[Float]?])
    }

    /// `embed`, with a word before each model call so the caller can mark which images are in it (design section 3).
    public func embedSteps(_ images: [PhotoBitmap], unitSize: Int, step: (EmbedStep) throws -> Void) throws {
        try embedSteps(count: images.count, unitSize: unitSize, input: { index in
            images[index].rgb.withUnsafeBufferPointer { mtmd_bitmap_init(UInt32(images[index].width), UInt32(images[index].height), $0.baseAddress) }
        }, step: step)
    }

    /// Embeds 30 s windows of 16 kHz mono samples in units of at most `unitSize` and `audioUnitWindows` (fewer when the
    /// tokens would not fit one batch), as `embed` does pictures. Needs the embedder made with `audio`.
    public func embedAudio(
        _ windows: [[Float]], unitSize: Int, unit: (Range<Int>, [[Float]?]) throws -> Void
    ) throws {
        try embedSteps(count: windows.count, unitSize: min(unitSize, Self.audioUnitWindows), input: { index in
            windows[index].withUnsafeBufferPointer { mtmd_bitmap_init_from_audio($0.count, $0.baseAddress) }
        }, step: { step in
            if case let .done(range, vectors) = step { try unit(range, vectors) }
        })
    }

    /// The loop of `embed` and `embedAudio`: `input` makes the mtmd bitmap of input `index` (nil when it cannot), which is freed once tokenized.
    private func embedSteps(
        count inputs: Int, unitSize: Int, input: (Int) -> OpaquePointer?, step: (EmbedStep) throws -> Void
    ) throws {
        let limit = max(1, min(unitSize, Self.maxSequences))
        var start = 0
        while start < inputs {
            reset()
            var sequenceOf: [Int32?] = []
            var next = start
            while next < inputs {
                try step(.inFlight([next]))
                let chunks = mtmd_input_chunks_init()
                defer { mtmd_input_chunks_free(chunks) }
                guard let count = tokenize(input(next), into: chunks) else {
                    sequenceOf.append(nil)
                    next += 1
                    continue
                }
                if sequences > 0, Int(sequences) >= limit || tokens + count > Self.maxTokens { break }
                begin()
                try add(chunks)
                sequenceOf.append(sequences - 1)
                next += 1
            }
            if sequences > 0 {
                try step(.inFlight(sequenceOf.indices.filter { sequenceOf[$0] != nil }.map { start + $0 }))
            }
            let pooled = sequences > 0 ? try run() : []
            try step(.done(start..<next, sequenceOf.map { $0.map { pooled[Int($0)] } }))
            start = next
        }
    }

    // MARK: pictures

    /// Tokenizes one picture or sound (its mtmd bitmap, freed here) into chunks and returns its token count, or nil when mtmd refuses it.
    private func tokenize(_ made: OpaquePointer?, into chunks: OpaquePointer?) -> Int? {
        guard let bitmap = made else { return nil }
        defer { mtmd_bitmap_free(bitmap) }
        var bitmaps: [OpaquePointer?] = [bitmap]
        let status = String(cString: mtmd_default_marker()).withCString { marker in
            var text = mtmd_input_text(text: marker, text_len: strlen(marker), add_special: true, parse_special: true)
            return mtmd_tokenize(media, chunks, &text, &bitmaps, 1)
        }
        guard status == 0 else { return nil }
        return (0..<mtmd_input_chunks_size(chunks)).reduce(0) {
            $0 + mtmd_input_chunk_get_n_tokens(mtmd_input_chunks_get(chunks, $1))
        }
    }

    /// Adds a picture's text tokens and encoder rows to the batch as the sequence `begin()` opened.
    private func add(_ chunks: OpaquePointer?) throws {
        for index in 0..<mtmd_input_chunks_size(chunks) {
            let chunk = mtmd_input_chunks_get(chunks, index)
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                var count = 0
                guard let ids = mtmd_input_chunk_get_tokens_text(chunk, &count) else { continue }
                for i in 0..<count { try place(llama_batch_ext_add_token(batch, sequences - 1, ids[i])) }
            } else {
                guard mtmd_encode_chunk(media, chunk) == 0, let rows = mtmd_get_output_embd(media) else {
                    throw PhotoEmbedderError.failed("the vision encoder failed")
                }
                for row in 0..<mtmd_input_chunk_get_n_tokens(chunk) {
                    let embd = llama_embd(data: rows + row * rowSize, n_rows: 1, n_embd: rowSize)  // copied by the batch
                    try place(llama_batch_ext_add_embd(batch, sequences - 1, embd))
                }
            }
        }
    }

    // MARK: text model

    private func begin() {
        sequences += 1
        position = 0
    }

    private func reset() {
        llama_batch_ext_clear(batch)
        sequences = 0
        tokens = 0
    }

    private func place(_ index: Int32) throws {
        guard index >= 0 else { throw PhotoEmbedderError.failed("batch full (\(index))") }
        var pos: [llama_pos] = [position, 0, 0, 0]
        guard llama_batch_ext_set_pos(batch, index, &pos), llama_batch_ext_set_output_embd(batch, index, true) else {
            throw PhotoEmbedderError.failed("can't place token \(index)")
        }
        position += 1
        tokens += 1
    }

    /// Runs the text model over the batch and returns one vector of length 1 per sequence, in order.
    private func run() throws -> [[Float]] {
        defer { reset() }
        let status = llama_process(context, LLAMA_PROCESS_TYPE_ENCODE, batch)
        guard status == 0 else { throw PhotoEmbedderError.failed("llama_process failed (\(status))") }
        return try (0..<sequences).map { sequence in
            guard let pooled = llama_get_embeddings_seq(context, sequence) else {
                throw PhotoEmbedderError.failed("no pooled embedding for input \(sequence)")
            }
            var sum = 0.0
            for i in 0..<embeddingSize { sum += Double(pooled[i]) * Double(pooled[i]) }
            let scale = sum > 0 ? Float(1 / sum.squareRoot()) : 0
            return (0..<embeddingSize).map { pooled[$0] * scale }
        }
    }

    /// llama.cpp's process-wide setup, once; only warnings and errors are printed (it logs a lot at load time).
    private static let backend: Void = {
        let log: ggml_log_callback = { level, text, _ in
            guard let text, level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue else { return }
            FileHandle.standardError.write(Data(String(cString: text).utf8))
        }
        llama_log_set(log, nil)
        mtmd_log_set(log, nil)
        llama_backend_init()
    }()
}
