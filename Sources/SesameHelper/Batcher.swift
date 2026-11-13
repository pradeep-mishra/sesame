import Foundation
import SesameEngine

/// The two model files `index` loads, one at a time (design section 3).
enum BatchModel: Equatable {
    /// Text vectors: document, PDF text page, code.
    case text
    /// Picture vectors: photo, video frame, scanned-PDF page.
    case image
    /// Sound vectors: audio windows. The picture model with the audio tower loaded too, so never together with `.image`.
    case audio
}

/// Which model is loaded now. A batch asks for the model it needs before each embed call; the first ask loads it, the
/// next ones only note the time, asking for the other one unloads this one first (never both loaded), `endBatch`
/// unloads at once, and `idle(at:)` unloads when 60 s have passed since the last ask.
struct Batcher {
    static let idleSeconds: TimeInterval = 60

    private let load: (BatchModel) throws -> Void
    private let unload: (BatchModel) -> Void
    private let clock: () -> Date
    private(set) var loaded: BatchModel?
    private var lastUse = Date.distantPast

    init(load: @escaping (BatchModel) throws -> Void, unload: @escaping (BatchModel) -> Void, clock: @escaping () -> Date) {
        self.load = load
        self.unload = unload
        self.clock = clock
    }

    /// Makes `model` the loaded one. When loading it fails nothing is loaded and the error is thrown.
    mutating func use(_ model: BatchModel) throws {
        if loaded != model {
            endBatch()
            try load(model)
            loaded = model
        }
        lastUse = clock()
    }

    /// Embeds the pieces of one step: its text pieces first, then the model is swapped, then its pictures. Each closure is
    /// called once, with its whole list, and gives one vector per piece in order. A list that is empty is not embedded and
    /// loads no model. The model of the last list stays loaded until `endBatch`.
    mutating func embed(
        text: [String], images: [PhotoBitmap], embedText: ([String]) throws -> [[Float]],
        embedImages: ([PhotoBitmap]) throws -> [[Float]]
    ) throws -> (text: [[Float]], images: [[Float]]) {
        var texts: [[Float]] = []
        var pictures: [[Float]] = []
        if !text.isEmpty {
            try use(.text)
            texts = try embedText(text)
        }
        if !images.isEmpty {
            try use(.image)
            pictures = try embedImages(images)
        }
        return (texts, pictures)
    }

    /// Embeds the pieces of one media step: its frames first in the picture model, then the model is swapped, then its
    /// sound windows in the audio model, never both loaded. Same rules as `embed`; an error from `embedImages` leaves at
    /// once, so the audio model is not loaded.
    mutating func embedMedia(
        images: [PhotoBitmap], windows: [[Float]], embedImages: ([PhotoBitmap]) throws -> [[Float]],
        embedWindows: ([[Float]]) throws -> [[Float]]
    ) throws -> (images: [[Float]], windows: [[Float]]) {
        var pictures: [[Float]] = []
        var sounds: [[Float]] = []
        if !images.isEmpty {
            try use(.image)
            pictures = try embedImages(images)
        }
        if !windows.isEmpty {
            try use(.audio)
            sounds = try embedWindows(windows)
        }
        return (pictures, sounds)
    }

    /// Unloads what is loaded.
    mutating func endBatch() {
        guard let model = loaded else { return }
        loaded = nil
        unload(model)
    }

    /// Unloads what is loaded once `now` is `idleSeconds` or more after the last `use`.
    mutating func idle(at now: Date) {
        if loaded != nil, now.timeIntervalSince(lastUse) >= Self.idleSeconds { endBatch() }
    }
}
