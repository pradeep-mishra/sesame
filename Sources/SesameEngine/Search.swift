import Accelerate
import Foundation

/// One passage with a vector, as `IndexReader.vectoredPassages()` hands it over.
public struct VectoredPassage: Sendable {
    public let id: Int64
    public let path: String
    public let kind: String
    public let modality: String
    public let vector: [Float16]
}

/// One file in a ranked list, with the passage that scored best for it.
public struct Hit: Equatable, Sendable {
    public let path: String
    public let passageID: Int64
}

public enum SearchScope: Sendable {
    case plain, code
}

/// Query to ranked files (design sections 3 and 9.3): the dot product of the query vector with every
/// stored vector, a z-score per modality gated at 2, one row per file with its best passage.
/// The caller embeds the text and passes the vector. Tier 1 is every visible file whose name or text holds the
/// whole typed text as one phrase (`exactHits`); it comes first, and the fused ranking follows.
public final class Search: @unchecked Sendable {
    private static let dimension = Schema.vectorLength

    /// A description (2 or more words) whose best image dot is below this shows no image rows (`RankingWeights`).
    public static let imageFloor: Double = RankingWeights.imageFloor

    private static let chunkRows = 2048

    /// The loaded vectors: row `r` is `matrix[r * dimension ..< (r + 1) * dimension]`.
    private struct Matrix {
        var vectors: [Float16] = []
        var passageIDs: [Int64] = []
        var fileOfRow: [Int] = []
        var modalityOfRow: [Int] = []
        var modalityCount = 0
        var imageModality: Int?
        var textModality: Int?
        var audioModality: Int?
        var paths: [String] = []
        var kinds: [String] = []
    }

    private let reader: IndexReader
    private let mutex = NSLock()
    private var newest = 0
    private var matrices: [SearchScope: Matrix]?

    public init(reader: IndexReader) {
        self.reader = reader
    }

    /// One per keystroke. Only the newest ticket gets a list.
    public func newTicket() -> Int {
        mutex.lock()
        defer { mutex.unlock() }
        newest += 1
        return newest
    }

    public var matrixLoaded: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return matrices != nil
    }

    /// Drops the matrix; the next search loads it again.
    public func release() {
        mutex.lock()
        defer { mutex.unlock() }
        matrices = nil
    }

    /// The visible files of `scope` whose name or text holds the whole `text` (cut at 500 characters) as one FTS5 phrase, one row
    /// per file with its first such passage, ordered by path (the keyword list; `rank` orders the same files by dot). Typed quotes and operators are only text.
    public func exactHits(text: String, visible: Visible, scope: SearchScope = .plain) -> [Hit] {
        tierOne(text: text, visible: visible, scope: scope).map(\.hit)
    }

    private func tierOne(text: String, visible: Visible, scope: SearchScope) -> [(hit: Hit, defines: Bool)] {
        let typed = String(text.prefix(RankingWeights.clamp))
        let words = typed.split(whereSeparator: \.isWhitespace).map(String.init)
        var firstOfPath: [String: Int64] = [:]
        var definingOfPath: [String: Int64] = [:]
        for hit in reader.keywordHits(typed)
        where (hit.kind == "code") == (scope == .code) && visible.allows(path: hit.path, kind: hit.kind) {
            if firstOfPath[hit.path] == nil { firstOfPath[hit.path] = hit.passageID }
            if scope == .code, definingOfPath[hit.path] == nil, let stretch = reader.passageText(hit.passageID),
               DefinitionRule.declares(stretch: stretch, words: words, ext: (hit.path as NSString).pathExtension.lowercased()) {
                definingOfPath[hit.path] = hit.passageID
            }
        }
        return firstOfPath.keys.sorted().map { path in
            (hit: Hit(path: path, passageID: definingOfPath[path] ?? firstOfPath[path]!), defines: definingOfPath[path] != nil)
        }
    }

    /// The files for `text`: tier 1 (the files of `exactHits`, whatever their dot and the gate, the definitions of a `code:` search
    /// first, each group ordered by the best dot among a file's passages, then path), then the fused ranking (best dot, then path)
    /// without those files. Nil when `ticket` is no longer the newest. An empty list means no row passed.
    public func rank(text: String, vector: [Float], ticket: Int, visible: Visible, scope: SearchScope = .plain) -> [Hit]? {
        guard isNewest(ticket) else { return nil }
        let loaded = currentMatrix(scope)
        guard vector.count == Self.dimension, !loaded.passageIDs.isEmpty else {
            return isNewest(ticket) ? [] : nil
        }
        // Tier 1 is limited to the files the loaded matrix holds, so a file written after the load shows in the
        // ranked list only once the matrix is reloaded (the pipeline's `indexChanged` rule); `exactHits` itself reads live.
        let loadedFiles = Set(loaded.paths)
        let found = tierOne(text: text, visible: visible, scope: scope).filter { loadedFiles.contains($0.hit.path) }

        let dots = Self.dots(of: loaded, query: vector)
        let definitions = Self.byBestDot(found.filter(\.defines).map(\.hit), in: loaded, dots: dots)
        let exact = definitions + Self.byBestDot(found.filter { !$0.defines }.map(\.hit), in: loaded, dots: dots)
        let tokens = String(text.prefix(RankingWeights.clamp)).split(whereSeparator: \.isWhitespace)
        let gate = Self.gated(dots, in: loaded, strictText: tokens.count >= 2)
        var passes = gate.passes
        let zs = gate.z

        var cappedImages: Set<Int64> = []
        if tokens.count >= 2, let image = loaded.imageModality {
            let imageRows = dots.indices.filter { loaded.modalityOfRow[$0] == image }
            if imageRows.count <= RankingWeights.smallLibraryCount {
                // z cannot discriminate among so few rows, so the floor alone decides, and the list is short.
                for row in imageRows { passes[row] = Double(dots[row]) >= Self.imageFloor }
                cappedImages = Set(imageRows.map { loaded.passageIDs[$0] })
            } else if let best = imageRows.map({ Double(dots[$0]) }).max(), best < Self.imageFloor {
                for row in imageRows { passes[row] = false }
            }
        }

        var hits = Self.hits(loaded, dots: dots, z: zs, eligible: { passes[$0] }, visible: visible)
        if !cappedImages.isEmpty {
            var images = 0
            hits = hits.filter { hit in
                guard cappedImages.contains(hit.passageID) else { return true }
                images += 1
                return images <= RankingWeights.relaxedCount
            }
        }
        if hits.isEmpty && exact.isEmpty && tokens.count == 1 {
            hits = Self.hits(loaded, dots: dots, z: zs, eligible: { _ in true }, visible: visible)
            hits = Array(hits.prefix(RankingWeights.relaxedCount))
        }
        let first = Set(exact.map(\.path))
        return isNewest(ticket) ? exact + hits.filter { !first.contains($0.path) } : nil
    }

    // MARK: helpers

    /// The tier-1 rows ordered by the best dot among their file's passages, highest first, then by path.
    private static func byBestDot(_ hits: [Hit], in matrix: Matrix, dots: [Float]) -> [Hit] {
        guard hits.count > 1 else { return hits }
        var best = [Float](repeating: -.infinity, count: matrix.paths.count)
        for row in 0..<dots.count {
            let file = matrix.fileOfRow[row]
            if dots[row] > best[file] { best[file] = dots[row] }
        }
        var fileOfPath: [String: Int] = [:]
        for (file, path) in matrix.paths.enumerated() { fileOfPath[path] = file }
        return hits.sorted { left, right in
            let one = best[fileOfPath[left.path]!], other = best[fileOfPath[right.path]!]
            return one != other ? one > other : left.path < right.path
        }
    }

    private func isNewest(_ ticket: Int) -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return ticket == newest
    }

    private func currentMatrix(_ scope: SearchScope) -> Matrix {
        mutex.lock()
        defer { mutex.unlock() }
        if let matrices { return matrices[scope]! }
        let passages = reader.vectoredPassages()
        let built = [
            SearchScope.plain: Self.load(passages.filter { $0.kind != "code" }),
            SearchScope.code: Self.load(passages.filter { $0.kind == "code" }),
        ]
        matrices = built
        return built[scope]!
    }

    private static func load(_ passages: [VectoredPassage]) -> Matrix {
        var built = Matrix()
        built.vectors.reserveCapacity(passages.count * dimension)
        var fileIndex: [String: Int] = [:]
        var modalityIndex: [String: Int] = [:]
        for passage in passages {
            // A stored vector with a NaN or infinite component would poison its modality's mean: it is left out.
            guard passage.vector.allSatisfy(\.isFinite) else { continue }
            built.vectors.append(contentsOf: passage.vector)
            built.passageIDs.append(passage.id)
            if fileIndex[passage.path] == nil {
                fileIndex[passage.path] = built.paths.count
                built.paths.append(passage.path)
                built.kinds.append(passage.kind)
            }
            built.fileOfRow.append(fileIndex[passage.path]!)
            if modalityIndex[passage.modality] == nil { modalityIndex[passage.modality] = modalityIndex.count }
            built.modalityOfRow.append(modalityIndex[passage.modality]!)
        }
        built.modalityCount = modalityIndex.count
        built.imageModality = modalityIndex["image"]
        built.textModality = modalityIndex["text"]
        built.audioModality = modalityIndex["audio"]
        return built
    }

    /// The dot product of `query` with every row, in chunks so only one chunk is ever held as Float32.
    private static func dots(of matrix: Matrix, query: [Float]) -> [Float] {
        let rowCount = matrix.passageIDs.count
        var result = [Float](repeating: 0, count: rowCount)
        var chunk = [Float](repeating: 0, count: min(chunkRows, rowCount) * dimension)
        var start = 0
        while start < rowCount {
            let rows = min(chunkRows, rowCount - start)
            let from = start * dimension
            for index in 0..<(rows * dimension) { chunk[index] = Float(matrix.vectors[from + index]) }
            result.withUnsafeMutableBufferPointer { out in
                vDSP_mmul(chunk, 1, query, 1, out.baseAddress! + start, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
            }
            start += rows
        }
        return result
    }

    /// Per row: does its dot stand at z >= 2 among all the rows of its own modality? With `strictText` (a description)
    /// the text rows and the audio rows of a library of more than `smallLibraryCount` rows of that modality must stand at
    /// `RankingWeights.textGateZ(rows:)` (or, with a topic of several rows together, `textTopicGateZ(rows:)`), z taken against the
    /// noise statistics of that modality's rows (`RankingWeights.trimmedNoise`). Also the z of every row within its own modality.
    private static func gated(_ dots: [Float], in matrix: Matrix, strictText: Bool) -> (passes: [Bool], z: [Double]) {
        var count = [Double](repeating: 0, count: matrix.modalityCount)
        var sum = count
        var squares = count
        for (row, dot) in dots.enumerated() {
            let modality = matrix.modalityOfRow[row]
            count[modality] += 1
            sum[modality] += Double(dot)
            squares[modality] += Double(dot) * Double(dot)
        }
        let mean = (0..<count.count).map { sum[$0] / count[$0] }
        let deviation = (0..<count.count).map { max(0, squares[$0] / count[$0] - mean[$0] * mean[$0]).squareRoot() }
        // A description's gate measures z against the noise, not against rows on the query's own topic: those
        // would widen the spread and hide themselves. The choice between a file's rows is made on the same noise
        // z for every modality with more than `smallLibraryCount` rows: a frame row's plain z is cut down by its own
        // outlier, which would make a frame lose to a window whose audio rows are measured against their noise.
        var noiseMean = mean
        var noiseDeviation = deviation
        var topicGate = [Double](repeating: .infinity, count: count.count)
        var strict = [Bool](repeating: false, count: count.count)
        for modality in 0..<count.count where count[modality] > Double(RankingWeights.smallLibraryCount) {
            let modalityDots = dots.indices.filter { matrix.modalityOfRow[$0] == modality }.map { Double(dots[$0]) }
            // Noise rows that are all equal have no spread: any row above them stands out by any number of deviations
            // (the floor keeps rounding in their mean from doing the same to rows equal to them).
            let noise = modality == matrix.audioModality
                ? RankingWeights.trimmedNoise(of: modalityDots, topicZ: RankingWeights.audioTopicZ, refinedFraction: RankingWeights.audioNoiseFraction)
                : RankingWeights.trimmedNoise(of: modalityDots)
            (noiseMean[modality], noiseDeviation[modality]) = (noise.mean, max(noise.deviation, 1e-9))
            guard strictText, modality == matrix.textModality || modality == matrix.audioModality else { continue }
            strict[modality] = true
            let low = RankingWeights.textTopicGateZ(rows: modalityDots.count)
            let topicRows = modality == matrix.audioModality ? RankingWeights.audioTopicRows : RankingWeights.textTopicRows
            if modalityDots.filter({ ($0 - noiseMean[modality]) / noiseDeviation[modality] >= low }).count >= topicRows {
                topicGate[modality] = low
            }
        }
        var passes = [Bool](repeating: false, count: dots.count)
        var zs = [Double](repeating: 0, count: dots.count)
        for (row, dot) in dots.enumerated() {
            let modality = matrix.modalityOfRow[row]
            zs[row] = (Double(dot) - noiseMean[modality]) / max(noiseDeviation[modality], 1e-9)
            if strict[modality] {
                passes[row] = zs[row] >= RankingWeights.textGateZ(rows: Int(count[modality])) || zs[row] >= topicGate[modality]
            } else if deviation[modality] > 0 {
                passes[row] = (Double(dot) - mean[modality]) / deviation[modality] >= RankingWeights.gate
            }
        }
        return (passes, zs)
    }

    /// One hit per visible file whose eligible rows exist, its row of the highest z within its own modality (a video holds
    /// frame rows and audio rows, whose raw dots are on different scales), ordered by that row's dot then path.
    private static func hits(_ matrix: Matrix, dots: [Float], z: [Double], eligible: (Int) -> Bool, visible: Visible) -> [Hit] {
        var best: [Int: Int] = [:]
        var shown: [Int: Bool] = [:]
        for row in 0..<dots.count where eligible(row) {
            let file = matrix.fileOfRow[row]
            if shown[file] == nil { shown[file] = visible.allows(path: matrix.paths[file], kind: matrix.kinds[file]) }
            guard shown[file] == true else { continue }
            if let current = best[file], z[current] >= z[row] { continue }
            best[file] = row
        }
        return best
            .map { (file: $0.key, row: $0.value) }
            .sorted { left, right in
                if dots[left.row] != dots[right.row] { return dots[left.row] > dots[right.row] }
                return matrix.paths[left.file] < matrix.paths[right.file]
            }
            .map { Hit(path: matrix.paths[$0.file], passageID: matrix.passageIDs[$0.row]) }
    }
}
