import Foundation
import Testing
import SesameEngine

// plan-1-t29, tester step. Written from design sections 2, 7 and 10 and the t29 entry only; no product source read.
//
// What is asserted comes from this file, from design section 7 (file names, revision) or from the reference
// vectors (read only, made by mlx-vlm, never by Sesame). Nothing is taken from the code under test.
//
// API SHAPES these tests pin (the design names `LlamaEmbedder`, `Embedder` and `LlamaEmbedder.vectorSource` but
// fixes no signatures; the Embedder shape is the one the t23 tests pin). All `public` in SesameEngine, because this
// file uses `import SesameEngine`, not `@testable`. If a shape is wrong, ask for a test change rather than guess.
//   1. `final class LlamaEmbedder: Embedder` with `init(textModel: URL)`: the text model file only (the
//      `encode` helper loads the text file only, design section 7). Making one loads nothing.
//   2. `func load() throws` loads the model; `func unload()` releases it; `var isLoaded: Bool { get }` is false
//      after `init`, true after `load()`, false after `unload()`. `load()` after `unload()` works again.
//   3. `embed(_ text: String, role: EmbedRole) throws -> [Float]` (the Embedder requirement) is called on a loaded
//      embedder. It applies the model-card prompt of the role itself: for `.query`
//      "task: search result | query: <text>", for `.document` (no title is given) "title: none | text: <text>".
//   4. `static var vectorSource: String { get }`: the `meta.vector_source` text. Readable with no instance and no
//      model file. It holds both file names, the revision and a vector version; its separators are not pinned.

private let textName = "embeddinggemma-2-Q8_0.gguf"
private let mmName = "mmproj-embeddinggemma-2-Q8_0.gguf"
private let revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"   // design section 7

// The reference vectors (design section 7), read only.
private let referenceFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Reference/vectors.json")

// The kit's model cache: `$KIT_ROOT/cache`, KIT_ROOT defaulting to `$TMPDIR/sesame-kit` (scripts/kit-lib/common.sh).
private let cacheFolder: URL? = {
    let env = ProcessInfo.processInfo.environment
    let root: String
    if let kit = env["KIT_ROOT"], !kit.isEmpty {
        root = kit
    } else if let tmp = env["TMPDIR"], !tmp.isEmpty {
        root = (tmp as NSString).appendingPathComponent("sesame-kit")
    } else {
        return nil
    }
    return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("cache", isDirectory: true)
}()

private func dot(_ a: [Float], _ b: [Float]) -> Double {
    var sum = 0.0
    for index in 0..<min(a.count, b.count) { sum += Double(a[index]) * Double(b[index]) }
    return sum
}

private func norm(_ a: [Float]) -> Double { dot(a, a).squareRoot() }

private func cosine(_ a: [Float], _ b: [Float]) -> Double { dot(a, b) / (norm(a) * norm(b)) }

// A failure, never a skip, when the cached model is missing (the kit seeds it in t6).
private func textModelURL() throws -> URL {
    let folder = try #require(cacheFolder, "no KIT_ROOT and no TMPDIR: cannot find the kit's model cache")
    let url = folder.appendingPathComponent(textName)
    try #require(FileManager.default.fileExists(atPath: url.path),
                 "model file missing: \(url.path) (seed the cache: scripts/kit-mirror.sh seed --real)")
    return url
}

private func referenceVectors() throws -> [String: [Float]] {
    let data = try #require(try? Data(contentsOf: referenceFile),
                            "reference vectors missing: \(referenceFile.path)")
    let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let raw = try #require(top["vectors"] as? [String: [Double]], "reference file has no `vectors` table")
    return raw.mapValues { $0.map { Float($0) } }
}

// The long document of the reference, written out again here (the reference's own generator).
private let longDocument: String = (1...60).map {
    "Note \($0): the review moved to room \($0 % 7 + 2) because the projector in the main hall failed again, "
        + "and the team agreed to send the slides the night before."
}.joined(separator: " ")

private func withLoadedEmbedder<T>(_ body: (LlamaEmbedder) throws -> T) throws -> T {
    let embedder = LlamaEmbedder(textModel: try textModelURL())
    try embedder.load()
    defer { embedder.unload() }
    return try body(embedder)
}

// One model in memory at a time: the suite runs one test after another.
@Suite("LlamaEmbedderTests", .serialized)
struct LlamaEmbedderTests {

    // MARK: the query vector

    @Test func embedsADogOnTheBeachWithTheQueryPromptTo768NumbersOfUnitNorm() throws {
        let vector = try withLoadedEmbedder { try $0.embed("a dog on the beach", role: .query) }
        #expect(vector.count == 768)
        #expect(abs(norm(vector) - 1) <= 1e-4, "norm is \(norm(vector))")
        #expect(vector.allSatisfy { $0.isFinite })
    }

    @Test func embedsTheSameTextToTheSameVectorTwice() throws {
        try withLoadedEmbedder { embedder in
            let first = try embedder.embed("a dog on the beach", role: .query)
            let second = try embedder.embed("a dog on the beach", role: .query)
            #expect(first.count == 768 && second.count == 768)
            let widest = zip(first, second).map { abs($0 - $1) }.max() ?? .infinity
            #expect(widest <= 1e-6, "two embeds differ by \(widest)")
        }
    }

    @Test func aFreshLoadGivesTheSameVectorAsTheFirst() throws {
        let first = try withLoadedEmbedder { try $0.embed("a dog on the beach", role: .query) }
        let second = try withLoadedEmbedder { try $0.embed("a dog on the beach", role: .query) }
        let widest = zip(first, second).map { abs($0 - $1) }.max() ?? .infinity
        #expect(first.count == 768 && widest <= 1e-6, "two loads differ by \(widest)")
    }

    @Test func differentTextsGiveDifferentVectors() throws {
        try withLoadedEmbedder { embedder in
            let dog = try embedder.embed("a dog on the beach", role: .query)
            let invoice = try embedder.embed("the invoice for the third quarter", role: .query)
            #expect(cosine(dog, invoice) < 0.95, "cosine \(cosine(dog, invoice))")
        }
    }

    @Test func theRoleChangesThePrompt() throws {
        try withLoadedEmbedder { embedder in
            let asQuery = try embedder.embed("a dog on the beach", role: .query)
            let asDocument = try embedder.embed("a dog on the beach", role: .document)
            #expect(asDocument.count == 768)
            #expect(abs(norm(asDocument) - 1) <= 1e-4)
            #expect(cosine(asQuery, asDocument) < 0.9999, "the two roles gave one vector")
        }
    }

    // MARK: the reference vectors (design section 7)

    @Test(arguments: [
        ("query", "payment declined error"),
        ("query-bn", "ইলিশ মাছ রান্না"),
        ("query-ar", "متى تغلق المكتبة"),
    ]) func aQueryVectorMatchesTheReferenceWithCosineAtLeast0999(name: String, text: String) throws {
        let reference = try #require(try referenceVectors()[name], "no `\(name)` in the reference file")
        #expect(reference.count == 768)
        let vector = try withLoadedEmbedder { try $0.embed(text, role: .query) }
        #expect(vector.count == 768)
        #expect(cosine(vector, reference) >= 0.999, "\(name): cosine \(cosine(vector, reference))")
    }

    @Test func aLongDocumentVectorMatchesTheReferenceWithCosineAtLeast0999() throws {
        // The reference "document-long" was made from the prompt "title: none | text: <the 60 notes>".
        let reference = try #require(try referenceVectors()["document-long"], "no `document-long` in the reference file")
        let vector = try withLoadedEmbedder { try $0.embed(longDocument, role: .document) }
        #expect(vector.count == 768)
        #expect(cosine(vector, reference) >= 0.999, "document-long: cosine \(cosine(vector, reference))")
    }

    // MARK: load and unload on request

    @Test func loadsAndUnloadsOnRequest() throws {
        let embedder = LlamaEmbedder(textModel: try textModelURL())
        #expect(!embedder.isLoaded, "making one must load nothing")
        try embedder.load()
        #expect(embedder.isLoaded)
        let loaded = try embedder.embed("a dog on the beach", role: .query)
        #expect(loaded.count == 768)
        embedder.unload()
        #expect(!embedder.isLoaded)
        try embedder.load()
        #expect(embedder.isLoaded)
        let again = try embedder.embed("a dog on the beach", role: .query)
        let widest = zip(loaded, again).map { abs($0 - $1) }.max() ?? .infinity
        #expect(again.count == 768 && widest <= 1e-6, "after unload and load the vector moved by \(widest)")
        embedder.unload()
        #expect(!embedder.isLoaded)
    }

    // MARK: the vector source

    @Test func vectorSourceIsReadableWithoutLoadingAModel() {
        let source = LlamaEmbedder.vectorSource
        #expect(!source.isEmpty)
        #expect(source.contains(textName), "no text model name in \(source)")
        #expect(source.contains(mmName), "no image-and-audio model name in \(source)")
        #expect(source.contains(revision), "no revision in \(source)")
        #expect(LlamaEmbedder.vectorSource == source, "the text changed between two reads")
    }
}
