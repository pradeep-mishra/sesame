import Foundation
import Testing
@testable import SesameEngine
@testable import SesameHelper

// plan-4-t4, tester step. Written from the t4 entry of plan-4-tasks.md (Tests) and design section 3 ("Work runs in batches ...
// the helper loads that model, embeds, and unloads it when the batch ends or after 60 s idle ... the two are never loaded
// together in `index`") only; no product source is read. The module is imported with `@testable`, as the sealed WatchdogTests
// import the helper module.
//
// Names the entry fixes: `BatchModel` (`.text`, `.image`), `Batcher(load:unload:clock:)`, `use(_:)`, `endBatch()`, `idle(at:)`.
// None exists yet.
//
// SHAPES THESE TESTS PIN (the entry gives the names only; if a shape is wrong, ask for a test change; every construction is in
// `make` below, one place to edit):
//   `Batcher(load: (BatchModel) -> Void, unload: (BatchModel) -> Void, clock: () -> Date)`
//   `batcher.use(_ model: BatchModel)`   loads `model` through `load` when it is not the loaded one; the clock gives the moment
//        of this use
//   `batcher.endBatch()`                 unloads what is loaded, at once
//   `batcher.idle(at now: Date)`         unloads what is loaded when `now` is 60 s or more after the last `use`
//   a `use` of the other model unloads the loaded one first
// The loader is a recording fake. Its call list is the observation: every `load` and `unload` is appended, and at every call the
// fake checks that no model is loaded while the other is (or the same one twice) and that nothing is unloaded that is not
// loaded. The fake keeps its own `loaded` list from the calls, never from the Batcher.

private final class Loader: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var present: [String] = []
    private var broken: [String] = []

    func load(_ model: BatchModel) {
        lock.lock(); defer { lock.unlock() }
        let name = String(describing: model)
        recorded.append("load \(name)")
        if !present.isEmpty { broken.append("load \(name) while \(present) is loaded") }
        present.append(name)
    }

    func unload(_ model: BatchModel) {
        lock.lock(); defer { lock.unlock() }
        let name = String(describing: model)
        recorded.append("unload \(name)")
        if let index = present.firstIndex(of: name) {
            present.remove(at: index)
        } else {
            broken.append("unload \(name) which is not loaded")
        }
    }

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var loaded: [String] { lock.lock(); defer { lock.unlock() }; return present }
    var violations: [String] { lock.lock(); defer { lock.unlock() }; return broken }
}

private final class Time: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func make(_ loader: Loader, _ time: Time) -> Batcher {
    Batcher(load: { loader.load($0) }, unload: { loader.unload($0) }, clock: { time.now })
}

// plan-4-t5, tester step: what is added below (new tests only; nothing above this line or in the t4 tests is changed except the
// one `@testable import SesameEngine` line, which the new tests need to build a `PhotoBitmap`).
//
// Names the t5 entry fixes: `Batcher.embed(text:images:embedText:embedImages:)` and the recorded order "load text, embed text,
// unload text, load image, embed image". `PhotoBitmap` is named in the entry's Reuses line.
//
// SHAPES THE NEW TESTS PIN (the entry gives the names only; every call is in `Journal` and `emb` below, one place to edit):
//   `PhotoBitmap(width: Int, height: Int, rgb: [UInt8])`          a bitmap the test makes by hand (internal initialiser, hence the
//                                                                   `@testable import SesameEngine`)
//   `batcher.embed(text: [String], images: [PhotoBitmap],
//                  embedText: ([String]) throws -> [[Float]],
//                  embedImages: ([PhotoBitmap]) throws -> [[Float]]) throws -> R`
//        one call per step: `embedText` is called once with all the text pieces, then the text model is swapped for the image
//        model, then `embedImages` is called once with all the bitmaps. R has `.text: [[Float]]` and `.images: [[Float]]`, the
//        closures' results in the order of the pieces. A list that is empty is not embedded and loads no model. After the call
//        the model of the last list stays loaded until `endBatch()`.
// The batch size of 25 files (G21) is not a Batcher call: it is the helper's queue, and HelperPdfQueueTests proves it from outside.

private final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var present: [String] = []
    private var broken: [String] = []

    func load(_ model: BatchModel) {
        lock.lock(); defer { lock.unlock() }
        let name = String(describing: model)
        recorded.append("load \(name)")
        if !present.isEmpty { broken.append("load \(name) while \(present) is loaded") }
        present.append(name)
    }

    func unload(_ model: BatchModel) {
        lock.lock(); defer { lock.unlock() }
        let name = String(describing: model)
        recorded.append("unload \(name)")
        if let index = present.firstIndex(of: name) { present.remove(at: index) } else { broken.append("unload \(name) which is not loaded") }
    }

    /// An embed call: it must happen while exactly `model` is loaded.
    func embed(_ model: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append("embed \(model)")
        if present != [model] { broken.append("embed \(model) while the loaded models are \(present)") }
    }

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var loaded: [String] { lock.lock(); defer { lock.unlock() }; return present }
    var violations: [String] { lock.lock(); defer { lock.unlock() }; return broken }
}

private func journalBatcher(_ journal: Journal, _ time: Time) -> Batcher {
    Batcher(load: { journal.load($0) }, unload: { journal.unload($0) }, clock: { time.now })
}

private func bitmap(_ width: Int) -> PhotoBitmap {
    PhotoBitmap(width: width, height: 1, rgb: [UInt8](repeating: 7, count: width * 3))
}

@Suite("BatcherTests")
struct BatcherTests {

    @Test func aBatchModelIsTextOrImage() {
        #expect(BatchModel.text != BatchModel.image)
        #expect(String(describing: BatchModel.text) == "text")
        #expect(String(describing: BatchModel.image) == "image")
    }

    @Test func aBatchOfAnyNumberOfCallsLoadsTheTextModelOnceAndEndBatchUnloadsIt() throws {
        let loader = Loader(), time = Time(start)
        var batcher = make(loader, time)
        #expect(loader.calls.isEmpty, "making a Batcher loaded something: \(loader.calls)")
        for _ in 1...50 { try batcher.use(.text); time.advance(0.1) }
        #expect(loader.calls == ["load text"], "fifty uses of the text model made the calls \(loader.calls)")
        #expect(loader.loaded == ["text"])
        try batcher.endBatch()
        #expect(loader.calls == ["load text", "unload text"], "after endBatch the calls are \(loader.calls)")
        #expect(loader.loaded.isEmpty, "the text model is still loaded after endBatch")
        try batcher.endBatch()
        #expect(loader.calls == ["load text", "unload text"], "a second endBatch with nothing loaded made calls: \(loader.calls)")
        #expect(loader.violations.isEmpty, "\(loader.violations)")
        _ = batcher
    }

    @Test func aNewBatchAfterEndBatchLoadsTheModelAgain() throws {
        let loader = Loader(), time = Time(start)
        var batcher = make(loader, time)
        try batcher.use(.text)
        try batcher.use(.text)
        try batcher.endBatch()
        time.advance(5)
        try batcher.use(.text)
        try batcher.use(.text)
        try batcher.endBatch()
        #expect(loader.calls == ["load text", "unload text", "load text", "unload text"], "calls: \(loader.calls)")
        #expect(loader.violations.isEmpty, "\(loader.violations)")
        _ = batcher
    }

    @Test func theImageModelIsLoadedAndUnloadedTheSameWay() throws {
        let loader = Loader(), time = Time(start)
        var batcher = make(loader, time)
        for _ in 1...5 { try batcher.use(.image) }
        #expect(loader.calls == ["load image"], "calls: \(loader.calls)")
        try batcher.endBatch()
        #expect(loader.calls == ["load image", "unload image"], "calls: \(loader.calls)")
        #expect(loader.violations.isEmpty, "\(loader.violations)")
        _ = batcher
    }

    // MARK: 60 seconds idle

    @Test func aClockSixtySecondsAfterTheLastUseUnloadsThroughIdleAt() throws {
        let loader = Loader(), time = Time(start)
        var batcher = make(loader, time)
        try batcher.use(.text)
        time.advance(5)
        try batcher.use(.text)
        time.advance(5)
        try batcher.use(.text)
        let lastOfAll = time.now

        try batcher.idle(at: lastOfAll.addingTimeInterval(0))
        try batcher.idle(at: lastOfAll.addingTimeInterval(30))
        try batcher.idle(at: lastOfAll.addingTimeInterval(59.9))
        #expect(loader.calls == ["load text"], "idle before 60 s after the last use made calls: \(loader.calls)")
        #expect(loader.loaded == ["text"])

        try batcher.idle(at: lastOfAll.addingTimeInterval(60))
        #expect(loader.calls == ["load text", "unload text"], "idle 60 s after the last use should unload: \(loader.calls)")
        #expect(loader.loaded.isEmpty)

        try batcher.idle(at: lastOfAll.addingTimeInterval(200))
        try batcher.endBatch()
        #expect(loader.calls == ["load text", "unload text"], "idle or endBatch with nothing loaded made calls: \(loader.calls)")
        #expect(loader.violations.isEmpty, "\(loader.violations)")
        _ = batcher
    }

    @Test func theSixtySecondsRunFromTheLastUseNotFromTheFirst() throws {
        let loader = Loader(), time = Time(start)
        var batcher = make(loader, time)
        try batcher.use(.text)                        // at start
        time.advance(50)
        try batcher.use(.text)                        // at start + 50
        try batcher.idle(at: start.addingTimeInterval(100))   // 50 s after the last use: still loaded
        #expect(loader.calls == ["load text"], "idle 50 s after the last use unloaded: \(loader.calls)")
        try batcher.idle(at: start.addingTimeInterval(109))   // 59 s after the last use: still loaded
        #expect(loader.calls == ["load text"], "idle 59 s after the last use unloaded: \(loader.calls)")
        try batcher.idle(at: start.addingTimeInterval(110))   // 60 s after the last use
        #expect(loader.calls == ["load text", "unload text"], "idle 60 s after the last use did not unload: \(loader.calls)")
        #expect(loader.violations.isEmpty, "\(loader.violations)")
        _ = batcher
    }

    @Test func idleWithNothingLoadedDoesNothing() throws {
        let loader = Loader(), time = Time(start)
        var batcher = make(loader, time)
        try batcher.idle(at: start.addingTimeInterval(1_000))
        try batcher.endBatch()
        #expect(loader.calls.isEmpty, "calls with nothing loaded: \(loader.calls)")
        _ = batcher
    }

    // MARK: never both

    @Test func theOtherModelIsUnloadedBeforeThisOneIsLoadedAndNeverBothAreLoaded() throws {
        let loader = Loader(), time = Time(start)
        var batcher = make(loader, time)
        let sequence: [BatchModel] = [.text, .text, .image, .image, .text, .image, .image, .text]
        var longest = 0
        for model in sequence {
            try batcher.use(model)
            time.advance(1)
            longest = max(longest, loader.loaded.count)
            #expect(loader.loaded == [String(describing: model)], "after use(\(model)) the loaded models are \(loader.loaded)")
        }
        try batcher.endBatch()
        let expected = [
            "load text", "unload text", "load image", "unload image", "load text", "unload text", "load image",
            "unload image", "load text", "unload text",
        ]
        #expect(loader.calls == expected, "calls were \(loader.calls)")
        #expect(longest == 1, "at some step \(longest) models were loaded")
        #expect(loader.violations.isEmpty, "a model was loaded while the other was, or an unload had nothing to unload: \(loader.violations)")
        #expect(loader.loaded.isEmpty)
        _ = batcher
    }

    @Test func aSwapAfterTheIdleUnloadLoadsTheNewModelWithoutAnotherUnload() throws {
        let loader = Loader(), time = Time(start)
        var batcher = make(loader, time)
        try batcher.use(.text)
        try batcher.idle(at: start.addingTimeInterval(60))
        time.advance(70)
        try batcher.use(.image)
        #expect(loader.calls == ["load text", "unload text", "load image"], "calls: \(loader.calls)")
        try batcher.endBatch()
        #expect(loader.calls == ["load text", "unload text", "load image", "unload image"], "calls: \(loader.calls)")
        #expect(loader.violations.isEmpty, "\(loader.violations)")
        _ = batcher
    }

    // MARK: plan-4-t5: a step with both kinds embeds its text pieces first, then swaps, then embeds its images

    @Test func embedEmbedsTheTextPiecesThenSwapsThenEmbedsTheImagesAndNeverHoldsBothModels() throws {
        let journal = Journal(), time = Time(start)
        var batcher = journalBatcher(journal, time)
        let result = try batcher.embed(
            text: ["a", "bcd", "ef"], images: [bitmap(1), bitmap(2)],
            embedText: { pieces in journal.embed("text"); return pieces.map { [Float($0.count)] } },
            embedImages: { pictures in journal.embed("image"); return pictures.map { [Float($0.width)] } })
        #expect(journal.calls == ["load text", "embed text", "unload text", "load image", "embed image"],
                "the recorded order is \(journal.calls)")
        #expect(result.text == [[1], [3], [2]], "the text vectors are \(result.text), expected one per piece in order, [[1], [3], [2]]")
        #expect(result.images == [[1], [2]], "the image vectors are \(result.images), expected [[1], [2]]")
        #expect(journal.loaded == ["image"], "after the step the loaded models are \(journal.loaded)")
        try batcher.endBatch()
        #expect(journal.calls.last == "unload image" && journal.loaded.isEmpty, "after endBatch: \(journal.calls), loaded \(journal.loaded)")
        #expect(journal.violations.isEmpty, "\(journal.violations)")
        _ = batcher
    }

    @Test func aStepWithOnlyTextPiecesNeverLoadsTheImageModelAndOneWithOnlyPicturesNeverLoadsTheTextModel() throws {
        let textOnly = Journal(), pictureOnly = Journal(), time = Time(start)
        var first = journalBatcher(textOnly, time)
        let one = try first.embed(
            text: ["xy", "z"], images: [],
            embedText: { pieces in textOnly.embed("text"); return pieces.map { [Float($0.count)] } },
            embedImages: { _ in textOnly.embed("image"); return [] })
        #expect(textOnly.calls == ["load text", "embed text"], "text only: the recorded order is \(textOnly.calls)")
        #expect(one.text == [[2], [1]] && one.images.isEmpty, "text only: results \(one.text) and \(one.images)")
        try first.endBatch()
        #expect(textOnly.calls == ["load text", "embed text", "unload text"], "text only after endBatch: \(textOnly.calls)")

        var second = journalBatcher(pictureOnly, time)
        let two = try second.embed(
            text: [], images: [bitmap(3)],
            embedText: { _ in pictureOnly.embed("text"); return [] },
            embedImages: { pictures in pictureOnly.embed("image"); return pictures.map { [Float($0.width)] } })
        #expect(pictureOnly.calls == ["load image", "embed image"], "pictures only: the recorded order is \(pictureOnly.calls)")
        #expect(two.images == [[3]] && two.text.isEmpty, "pictures only: results \(two.text) and \(two.images)")
        try second.endBatch()
        #expect(pictureOnly.calls == ["load image", "embed image", "unload image"], "pictures only after endBatch: \(pictureOnly.calls)")
        #expect(textOnly.violations.isEmpty && pictureOnly.violations.isEmpty, "\(textOnly.violations) \(pictureOnly.violations)")
        _ = (first, second)
    }

    @Test func twoStepsOfOneBatchSwapTheModelsEachTimeAndNeverHoldBoth() throws {
        let journal = Journal(), time = Time(start)
        var batcher = journalBatcher(journal, time)
        for step in 1...2 {
            let result = try batcher.embed(
                text: ["t\(step)"], images: [bitmap(step)],
                embedText: { pieces in journal.embed("text"); return pieces.map { _ in [Float(step)] } },
                embedImages: { pictures in journal.embed("image"); return pictures.map { _ in [Float(10 * step)] } })
            #expect(result.text == [[Float(step)]] && result.images == [[Float(10 * step)]], "step \(step): results \(result.text) and \(result.images)")
        }
        let expected = [
            "load text", "embed text", "unload text", "load image", "embed image",
            "unload image", "load text", "embed text", "unload text", "load image", "embed image",
        ]
        #expect(journal.calls == expected, "the recorded order is \(journal.calls)")
        try batcher.endBatch()
        #expect(journal.calls.last == "unload image" && journal.loaded.isEmpty, "after endBatch: \(journal.calls), loaded \(journal.loaded)")
        #expect(journal.violations.isEmpty, "a model was loaded while the other was, or an embed ran with the wrong model loaded: \(journal.violations)")
        _ = batcher
    }
}

// plan-5-t2, tester step: what is added below (new tests only; nothing above this line is changed). Written from the t2 entry of
// plan-5-tasks.md ("`BatcherTests` extended: `use(.audio)` after `.image` or `.text` unloads the other first, never two loaded (the
// recorded call list at every step); `embedMedia` is not tested here (t3)") and Decision D3 ("a third model state, `BatchModel.audio`,
// never loaded together with another") only; no product source is read. The name `BatchModel.audio` is the one the entry fixes; the
// fakes are the `Loader` and `Time` of the plan-4-t4 tests above, whose call list is the observation.

extension BatcherTests {

    @Test func aBatchModelIsTextImageOrAudioAndTheThirdIsNamedAudio() {
        #expect(BatchModel.audio != BatchModel.text && BatchModel.audio != BatchModel.image && BatchModel.text != BatchModel.image)
        #expect(String(describing: BatchModel.audio) == "audio", "the third model's name is \(String(describing: BatchModel.audio))")
    }

    @Test func theAudioModelIsLoadedAndUnloadedTheSameWayAsTheOthers() throws {
        let loader = Loader(), time = Time(start)
        var batcher = make(loader, time)
        for _ in 1...5 { try batcher.use(.audio) }
        #expect(loader.calls == ["load audio"], "calls: \(loader.calls)")
        try batcher.endBatch()
        #expect(loader.calls == ["load audio", "unload audio"], "calls: \(loader.calls)")
        #expect(loader.violations.isEmpty, "\(loader.violations)")
        _ = batcher
    }

    @Test func useAudioAfterTextOrImageUnloadsTheOtherFirstAndNoStepHoldsTwoModels() throws {
        let loader = Loader(), time = Time(start)
        var batcher = make(loader, time)
        let sequence: [BatchModel] = [.text, .audio, .audio, .image, .audio, .text, .image, .audio]
        var longest = 0
        for model in sequence {
            try batcher.use(model)
            time.advance(1)
            longest = max(longest, loader.loaded.count)
            #expect(loader.loaded == [String(describing: model)], "after use(\(model)) the loaded models are \(loader.loaded)")
        }
        try batcher.endBatch()
        let expected = [
            "load text", "unload text", "load audio", "unload audio", "load image", "unload image", "load audio",
            "unload audio", "load text", "unload text", "load image", "unload image", "load audio", "unload audio",
        ]
        #expect(loader.calls == expected, "calls were \(loader.calls)")
        #expect(longest == 1, "at some step \(longest) models were loaded")
        #expect(loader.violations.isEmpty, "a model was loaded while another was, or an unload had nothing to unload: \(loader.violations)")
        #expect(loader.loaded.isEmpty)
        _ = batcher
    }

    @Test func anIdleAudioModelUnloadsSixtySecondsAfterItsLastUseAndALaterSwapLoadsWithoutAnotherUnload() throws {
        let loader = Loader(), time = Time(start)
        var batcher = make(loader, time)
        try batcher.use(.audio)
        try batcher.idle(at: start.addingTimeInterval(59))
        #expect(loader.calls == ["load audio"], "idle 59 s after the use unloaded: \(loader.calls)")
        try batcher.idle(at: start.addingTimeInterval(60))
        #expect(loader.calls == ["load audio", "unload audio"], "idle 60 s after the last use should unload the audio model: \(loader.calls)")
        time.advance(70)
        try batcher.use(.text)
        #expect(loader.calls == ["load audio", "unload audio", "load text"], "calls: \(loader.calls)")
        try batcher.endBatch()
        #expect(loader.calls == ["load audio", "unload audio", "load text", "unload text"], "calls: \(loader.calls)")
        #expect(loader.violations.isEmpty, "\(loader.violations)")
        _ = batcher
    }
}

// plan-5-t3, tester step: what is added below (new tests only; nothing above this line is changed). Written from the t3 entry of plan-5-tasks.md
// ("`BatcherTests` extended: `embedMedia(images:windows:embedImages:embedWindows:)` embeds the frames first, then swaps, then the windows (the
// recorded order: load image, embed image, unload image, load audio, embed audio), never both loaded; an empty list loads nothing") and Decisions
// D3 and D7 only; no product source is read. The fakes are the `Journal` and `Time` of the plan-4-t5 tests above, whose call list is the observation.
//
// SHAPES THE NEW TESTS PIN (the entry gives the name and the labels, not the types; every call is in `mediaStep` below, one place to edit):
//   `batcher.embedMedia(images: [PhotoBitmap], windows: [[Float]],
//                       embedImages: ([PhotoBitmap]) throws -> [[Float]],
//                       embedWindows: ([[Float]]) throws -> [[Float]]) throws -> R`
//        a window is its 16 kHz mono samples (`AudioWindow.samples`), so the test needs no initialiser of `AudioWindow`; R has `.images: [[Float]]`
//        and `.windows: [[Float]]`, the closures' results in the order of the inputs. One call per step: `embedImages` once with all the frames,
//        then the image model is swapped for the audio model, then `embedWindows` once with all the windows. A list that is empty is not embedded and
//        loads no model. After the call the model of the last non-empty list stays loaded until `endBatch()`. An error thrown by `embedImages`
//        leaves the call at once: `embedWindows` is never called and the audio model is never loaded.

private func samples(_ count: Int) -> [Float] { [Float](repeating: 0.25, count: count) }

extension BatcherTests {

    private func mediaStep(_ batcher: inout Batcher, _ journal: Journal, frames: [Int], windows: [Int]) throws -> (images: [[Float]], windows: [[Float]]) {
        let result = try batcher.embedMedia(
            images: frames.map { bitmap($0) }, windows: windows.map { samples($0) },
            embedImages: { pictures in journal.embed("image"); return pictures.map { [Float($0.width)] } },
            embedWindows: { clips in journal.embed("audio"); return clips.map { [Float($0.count)] } })
        return (result.images, result.windows)
    }

    @Test func embedMediaEmbedsTheFramesThenSwapsThenEmbedsTheWindowsAndNeverHoldsBothModels() throws {
        let journal = Journal(), time = Time(start)
        var batcher = journalBatcher(journal, time)
        let result = try mediaStep(&batcher, journal, frames: [1, 2], windows: [3, 5, 2])
        #expect(journal.calls == ["load image", "embed image", "unload image", "load audio", "embed audio"], "the recorded order is \(journal.calls)")
        #expect(result.images == [[1], [2]], "the frame vectors are \(result.images), expected [[1], [2]]")
        #expect(result.windows == [[3], [5], [2]], "the window vectors are \(result.windows), expected [[3], [5], [2]] (one per window, in order)")
        #expect(journal.loaded == ["audio"], "after the step the loaded models are \(journal.loaded)")
        try batcher.endBatch()
        #expect(journal.calls.last == "unload audio" && journal.loaded.isEmpty, "after endBatch: \(journal.calls), loaded \(journal.loaded)")
        #expect(journal.violations.isEmpty, "\(journal.violations)")
        _ = batcher
    }

    @Test func aStepWithOnlyFramesNeverLoadsTheAudioModelAndOneWithOnlyWindowsNeverLoadsTheImageModelAndAnEmptyStepLoadsNothing() throws {
        let framesOnly = Journal(), windowsOnly = Journal(), nothing = Journal(), time = Time(start)
        var first = journalBatcher(framesOnly, time)
        let one = try mediaStep(&first, framesOnly, frames: [4], windows: [])
        #expect(framesOnly.calls == ["load image", "embed image"], "frames only: the recorded order is \(framesOnly.calls)")
        #expect(one.images == [[4]] && one.windows.isEmpty, "frames only: results \(one.images) and \(one.windows)")
        try first.endBatch()
        #expect(framesOnly.calls == ["load image", "embed image", "unload image"], "frames only after endBatch: \(framesOnly.calls)")

        var second = journalBatcher(windowsOnly, time)
        let two = try mediaStep(&second, windowsOnly, frames: [], windows: [6, 7])
        #expect(windowsOnly.calls == ["load audio", "embed audio"], "windows only: the recorded order is \(windowsOnly.calls)")
        #expect(two.windows == [[6], [7]] && two.images.isEmpty, "windows only: results \(two.images) and \(two.windows)")
        try second.endBatch()
        #expect(windowsOnly.calls == ["load audio", "embed audio", "unload audio"], "windows only after endBatch: \(windowsOnly.calls)")

        var third = journalBatcher(nothing, time)
        let none = try mediaStep(&third, nothing, frames: [], windows: [])
        #expect(nothing.calls.isEmpty && none.images.isEmpty && none.windows.isEmpty, "an empty step made calls \(nothing.calls) and results \(none.images) \(none.windows)")
        try third.endBatch()
        #expect(nothing.calls.isEmpty, "endBatch after an empty step made calls: \(nothing.calls)")
        #expect(framesOnly.violations.isEmpty && windowsOnly.violations.isEmpty && nothing.violations.isEmpty, "\(framesOnly.violations) \(windowsOnly.violations)")
        _ = (first, second, third)
    }

    @Test func twoMediaStepsOfOneBatchSwapTheModelsEachTimeAndNeverHoldBoth() throws {
        let journal = Journal(), time = Time(start)
        var batcher = journalBatcher(journal, time)
        for _ in 1...2 { _ = try mediaStep(&batcher, journal, frames: [1], windows: [2]) }
        let expected = [
            "load image", "embed image", "unload image", "load audio", "embed audio",
            "unload audio", "load image", "embed image", "unload image", "load audio", "embed audio",
        ]
        #expect(journal.calls == expected, "the recorded order is \(journal.calls)")
        try batcher.endBatch()
        #expect(journal.calls.last == "unload audio" && journal.loaded.isEmpty, "after endBatch: \(journal.calls), loaded \(journal.loaded)")
        #expect(journal.violations.isEmpty, "a model was loaded while another was, or an embed ran with the wrong model loaded: \(journal.violations)")
        _ = batcher
    }

    @Test func aMediaStepAfterATextStepUnloadsTheTextModelFirst() throws {
        let journal = Journal(), time = Time(start)
        var batcher = journalBatcher(journal, time)
        try batcher.use(.text)
        _ = try mediaStep(&batcher, journal, frames: [1], windows: [2])
        #expect(journal.calls == ["load text", "unload text", "load image", "embed image", "unload image", "load audio", "embed audio"], "the recorded order is \(journal.calls)")
        #expect(journal.violations.isEmpty, "\(journal.violations)")
        _ = batcher
    }

    private struct MediaFailure: Error {}

    @Test func anErrorFromTheFrameStepLeavesTheCallAtOnceAndTheAudioModelIsNeverLoaded() throws {
        let journal = Journal(), time = Time(start)
        var batcher = journalBatcher(journal, time)
        var windowsCalled = false
        #expect(throws: MediaFailure.self) {
            _ = try batcher.embedMedia(
                images: [bitmap(1)], windows: [samples(3)],
                embedImages: { _ in journal.embed("image"); throw MediaFailure() },
                embedWindows: { clips in windowsCalled = true; return clips.map { _ in [0] } })
        }
        #expect(!windowsCalled && !journal.calls.contains("load audio"), "after the frame step threw, the window step ran or the audio model was loaded: \(journal.calls)")
        #expect(journal.violations.isEmpty, "\(journal.violations)")
        _ = batcher
    }
}
