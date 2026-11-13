import CryptoKit
import Foundation

/// One model file: its name, its exact size in bytes and its SHA-256 (64 lower-case hex digits).
public struct ModelFile: Equatable, Sendable {
    public let name: String
    public let size: Int
    public let sha256: String

    public init(name: String, size: Int, sha256: String) {
        self.name = name
        self.size = size
        self.sha256 = sha256
    }
}

/// The two model files (design section 7) and the one check that says a file is whole.
public enum ModelFiles {
    public static let repository = "ggml-org/embeddinggemma-2-GGUF"
    public static let revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"

    /// Text file first, then the image-and-audio file.
    public static let all: [ModelFile] = [
        ModelFile(name: "embeddinggemma-2-Q8_0.gguf", size: 309_855_456,
                  sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"),
        ModelFile(name: "mmproj-embeddinggemma-2-Q8_0.gguf", size: 554_821_024,
                  sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f"),
    ]

    /// The path part of a file's download URL, after the host.
    public static func resolvePath(of file: ModelFile) -> String {
        "/\(repository)/resolve/\(revision)/\(file.name)"
    }

    static let pieceSize = 8 * 1024 * 1024

    /// SHA-256 of the file at `url`, read in 8 MB pieces, as lower-case hex.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let finished: Bool = try autoreleasepool {
                guard let piece = try handle.read(upToCount: pieceSize), !piece.isEmpty else { return true }
                hasher.update(data: piece)
                return false
            }
            if finished { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True only when the file at `url` has exactly `file.size` bytes and SHA-256 `file.sha256`.
    /// A missing or unreadable file is false.
    public static func isPresent(_ file: ModelFile, at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? Int) == file.size,
              let digest = try? sha256(of: url) else { return false }
        return digest == file.sha256
    }
}
