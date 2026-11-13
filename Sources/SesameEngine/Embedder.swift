import Foundation

/// Whether the text is a search the person typed or a passage being indexed.
public enum EmbedRole: Sendable {
    case query
    case document
}

/// Turns text into one 768-number vector of length 1. The real one (t29) runs the text model;
/// `FakeEmbedder` stands in for tests and for runs with no model.
public protocol Embedder {
    func embed(_ text: String, role: EmbedRole) throws -> [Float]
}

/// The composition root: the embedder the `index` helper uses. The test kit's `SESAME_FAKE_EMBEDDER=1` gives the
/// fake and loads no model; otherwise a text-model path gives the real one, and no path gives none.
public enum EmbedderChoice {
    public static func make(textModel: URL?) -> (any Embedder)? {
        if ProcessInfo.processInfo.environment["SESAME_FAKE_EMBEDDER"] == "1" { return FakeEmbedder() }
        return textModel.map { LlamaEmbedder(textModel: $0) }
    }
}

/// A vector that is a pure function of the text: same text, same numbers, whatever the role.
/// Not meaningful, only stable and spread out.
public struct FakeEmbedder: Embedder {
    public init() {}

    public func embed(_ text: String, role: EmbedRole) throws -> [Float] {
        // FNV-1a over the UTF-8 bytes seeds a splitmix64 stream.
        var seed: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { seed = (seed ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        var state = seed
        var numbers = (0..<Schema.vectorLength).map { _ -> Double in
            state = state &+ 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53) - 0.5
        }
        let length = numbers.reduce(0) { $0 + $1 * $1 }.squareRoot()
        numbers = numbers.map { $0 / length }
        return numbers.map { Float($0) }
    }
}
