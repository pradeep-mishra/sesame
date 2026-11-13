import Foundation
import Testing
import SesameEngine

// plan-4 review round 1, fix round, tester step (must-fix 1: the text gate does not scale with the library).
// Written from the reviewer's report (the first must-fix) and the brief only; no product source read. Names come from the
// existing rig (SearchExactTierTests, SearchFloorTests, SearchSmallLibraryTests): `IndexStore.addFile/addPassage`,
// `withTempHome`, `createFolder`, `Search(reader:)`, `Search.rank(text:vector:ticket:visible:)`, `Visible`, `Settings.Folder`.
//
// THE FINDING. The text gate is a z constant (3.2) measured inside the whole text modality, tuned on 63 text rows. For a
// description made of noise, the best of n scores grows with n (about 2.2 sigma at 63 rows, about 3.7 sigma at 5,000), so in a
// library of thousands of PDF pages and document chunks a nonsense description lets its top row through and "No matches" never
// shows. Images have an absolute floor (0.69); text has none.
//
// THE LIBRARY. Seeded and synthetic: a fixed-seed generator written in this file (SplitMix64 and Box-Muller), not the product's.
// The text rows are random unit vectors in 768 dimensions: PDF pages (files of 10 pages) and document chunks (files of 5
// chunks), alternating, with six photo files (image rows) so the library is mixed. Every file also has a `name` passage with
// words that no query holds. Nothing in the library holds a word of a query, so only the vectors decide.
//
// WHAT THEY PIN.
//   - 100 seeded random unit vectors as descriptions of 2, 3 and 4 words, on 5,000 text rows: at most 2 of the 100 may list
//     any PDF or document row. (Red today: the 3.2 gate lets the top row of most of them through.)
//   - A planted match: one PDF page whose dot with its query vector is the mean of the noise dots plus 6 of their standard
//     deviations (mean and standard deviation computed here from the noise rows' own dots, with the planted row not in them) is
//     found FIRST by its description, at 63, 5,000 and 20,000 text rows. (Green controls: today's gate keeps it. They must stay
//     green when the gate is changed, so a fix that simply closes the gate fails here.)
//
// SHAPES THIS FILE PINS that the brief did not fix: none new. The rig's own choices are the paths (/docs/pNNN.pdf,
// /docs/dNNN.docx, /photos/iNN.jpg, /docs/planted.pdf), the sources ("page" for a PDF page, "chunk" for a document chunk,
// "image" for a photo) and the modality "text" for the first two.

private let dimension = 768

// MARK: the generator (written here; the product's is never used)

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// In [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-300)
        let u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

private func randomUnit(_ rng: inout SplitMix64) -> [Float] {
    let raw = (0..<dimension).map { _ in rng.gaussian() }
    let length = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return raw.map { Float($0 / length) }
}

private func dot(_ a: [Float], _ b: [Float]) -> Double {
    var sum = 0.0
    for index in 0..<min(a.count, b.count) { sum += Double(a[index]) * Double(b[index]) }
    return sum
}

/// A unit vector whose dot product with the unit vector `q` is `a`: a*q + sqrt(1-a*a)*u, u at right angles to q.
private func vector(dot a: Double, with q: [Float], using rng: inout SplitMix64) -> [Float] {
    let r = (0..<dimension).map { _ in rng.gaussian() }
    var along = 0.0
    for index in 0..<dimension { along += r[index] * Double(q[index]) }
    var u = (0..<dimension).map { r[$0] - along * Double(q[$0]) }
    let length = u.reduce(0) { $0 + $1 * $1 }.squareRoot()
    u = u.map { $0 / length }
    let side = (1 - a * a).squareRoot()
    return (0..<dimension).map { Float(a * Double(q[$0]) + side * u[$0]) }
}

// MARK: the library

private let everything = Visible(
    folders: [Settings.Folder(path: "/docs", code: false, reading: true), Settings.Folder(path: "/photos", code: false, reading: true)],
    codeSearchOn: true,
    kindsOn: ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true])

private let plantedPath = "/docs/planted.pdf"

private struct Planted {
    let path: String
    let passageID: Int64
    /// The mean and the standard deviation of the noise rows' dots with the planted query, and the planted row's own dot.
    let mean: Double
    let deviation: Double
    let dot: Double
}

/// Writes `rows` text passages of noise (PDF pages and document chunks, alternating files), six photo files, and, when `planting`
/// is a query vector, one more PDF page at mean + 6 standard deviations of the noise dots with that query. Calls `body` with a
/// `Search` over the written index.
private func withTextLibrary(rows: Int, seed: UInt64, planting query: [Float]? = nil,
                             _ body: (Search, Planted?) throws -> Void) throws {
    var rng = SplitMix64(seed: seed)
    let noise = (0..<rows).map { _ in randomUnit(&rng) }
    let photos = (0..<6).map { _ in randomUnit(&rng) }
    var planted: (vector: [Float], mean: Double, deviation: Double, dot: Double)?
    if let query {
        let dots = noise.map { dot($0, query) }
        let mean = dots.reduce(0, +) / Double(dots.count)
        let variance = dots.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(dots.count)
        let deviation = variance.squareRoot()
        let target = mean + 6 * deviation
        planted = (vector(dot: target, with: query, using: &rng), mean, deviation, target)
    }
    try withTempHome { t in
        guard try createFolder(t) else { return }
        let store = try IndexStore()
        var inode: Int64 = 100
        func addFile(_ path: String, kind: String) throws -> Int64 {
            inode += 1
            return try store.addFile(path: path, kind: kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                     inode: inode, device: 16_777_220, status: "done")
        }
        var written = 0
        var fileNumber = 0
        while written < rows {
            let isPdf = fileNumber % 2 == 0
            let path = isPdf ? String(format: "/docs/p%04d.pdf", fileNumber) : String(format: "/docs/d%04d.docx", fileNumber)
            let id = try addFile(path, kind: isPdf ? "pdf" : "doc")
            _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                     name: "sheet\(fileNumber)", body: "")
            for _ in 0..<(isPdf ? 10 : 5) where written < rows {
                _ = try store.addPassage(fileID: id, source: isPdf ? "page" : "chunk", start: 0, end: 0, modality: "text",
                                         vector: noise[written], name: "", body: "")
                written += 1
            }
            fileNumber += 1
        }
        for (number, vector) in photos.enumerated() {
            let id = try addFile(String(format: "/photos/i%02d.jpg", number), kind: "photo")
            _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                     name: "frame\(number)", body: "")
            _ = try store.addPassage(fileID: id, source: "image", start: 0, end: 0, modality: "image", vector: vector,
                                     name: "", body: "")
        }
        var plantedRow: Planted?
        if let planted {
            let id = try addFile(plantedPath, kind: "pdf")
            _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                     name: "sheetplanted", body: "")
            let passage = try store.addPassage(fileID: id, source: "page", start: 0, end: 0, modality: "text",
                                               vector: planted.vector, name: "", body: "")
            plantedRow = Planted(path: plantedPath, passageID: passage, mean: planted.mean, deviation: planted.deviation, dot: planted.dot)
        }
        store.close()
        let reader = IndexReader()
        defer { reader.close() }
        try body(Search(reader: reader), plantedRow)
    }
}

private struct Found: Equatable {
    let path: String
    let passageID: Int64
}

private func ranked(_ search: Search, _ typed: String, _ vector: [Float]) throws -> [Found] {
    let ticket = search.newTicket()
    let hits = try #require(search.rank(text: typed, vector: vector, ticket: ticket, visible: everything),
                            "the newest ticket must get a list")
    return hits.map { Found(path: $0.path, passageID: $0.passageID) }
}

/// A description of 2, 3 or 4 words that no stored word holds (the names are `sheetN` and `frameN`, the bodies are empty).
private let nonsenseWords = ["velvet", "quartz", "lantern", "orbit", "maple", "tundra", "saffron", "glacier"]

private func nonsense(_ number: Int) -> String {
    let count = 2 + number % 3
    return (0..<count).map { nonsenseWords[(number * 3 + $0 * 5) % nonsenseWords.count] }.joined(separator: " ")
}

// MARK: a topic cluster (plan-4 review round 2, fix round, tester step: must-fix 1)
//
// THE FINDING (round 2). The gate z uses the mean and the standard deviation of ALL text rows. Rows that are on the query's topic
// are not noise: they raise the standard deviation and the mean, so the best of them scores a lower z than the same rows would in a
// library with no relatives. The largest z that k related rows out of n can reach is sqrt((n-k)/k), under the gate once k/n is
// above about 9 percent (gate 3.2), 5 percent (1,000 rows), 4 percent (5,000 rows). A person searching for "the lease" by its
// description, in a library where 5 percent of the passages are about leases, sees "No matches" or a list without the lease.
//
// THE RIG (same generator as above). For a cell (n text rows in all, k cluster rows) and each of 20 trials:
//   - the noise rows are the first n - k of a cached list of random unit vectors (so the cells share noise rows, per n);
//   - the query is a fresh random unit vector (a seed of the trial);
//   - the mean and the standard deviation (SD) of the NOISE rows' dots with the query are computed here, over the n - k noise rows
//     only; each cluster row is a unit vector whose dot with the query is mean + s SD, s spread evenly over 5.6 to 6.4 (seeded), so
//     "about 6 SD" with a little spread;
//   - the library holds the noise rows and the cluster rows as PDF pages and document chunks (files of 10 and 5, alternating; the
//     cluster rows are in files named /docs/topicNNNN.pdf and /docs/topicNNNN.docx), plus six photo files, and a `name` passage per
//     file with words no query holds;
//   - the query is the 3 words "invoice from landlord" and the vector. Only the vector can match.
// A trial is a pass when the list holds at least one row of a /docs/topic file. A cell passes when at least 19 of its 20 trials
// pass (95 percent). The nine cells: n in 200, 1000, 5000 and k = 2, 5 and 10 percent of n. And one more: a 63-row library with k = 6.
//
// SHAPES THIS PINS that the brief did not fix: the cluster files' names (/docs/topicNNNN.pdf, .docx) and that "a cluster row in the
// result" means a row with such a path; the three words; 19 of 20 as "95 percent"; the spread 5.6 to 6.4 SD.

private final class NoiseRows: @unchecked Sendable {
    static let shared = NoiseRows()
    private let lock = NSLock()
    private var byCount: [Int: [[Float]]] = [:]

    func rows(_ count: Int) -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        if let have = byCount[count] { return have }
        var rng = SplitMix64(seed: UInt64(31_000 + count))
        let made = (0..<count).map { _ in randomUnit(&rng) }
        byCount[count] = made
        return made
    }
}

private let clusterPhrase = "invoice from landlord"
private let clusterPrefix = "/docs/topic"

private struct ClusterTrial {
    let shown: Bool
    let listed: Int
    let textRowsListed: Int
    let setupProblem: String?
    let seconds: Double
}

private let otherPrefix = "/docs/other"

/// `low` and `width`: the cluster rows sit at mean + s SD of the noise rows, s spread evenly over low ... low + width. `extraHigh`:
/// that many more rows (files /docs/otherNNNN.pdf, .docx) at the same height with the query, written like a second topic whose rows
/// are high for the statistic; the noise is then the first n - k - extraHigh cached rows.
private func runClusterTrial(rows n: Int, cluster k: Int, seed: UInt64, low: Double = 5.6, width: Double = 0.8,
                             extraHigh: Int = 0) throws -> ClusterTrial {
    let started = Date()
    var queryRNG = SplitMix64(seed: seed)
    let query = randomUnit(&queryRNG)
    let noise = Array(NoiseRows.shared.rows(n).prefix(n - k - extraHigh))
    let dots = noise.map { dot($0, query) }
    let mean = dots.reduce(0, +) / Double(dots.count)
    let deviation = (dots.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(dots.count)).squareRoot()
    var clusterRNG = SplitMix64(seed: seed ^ 0xC1_05_7E_12)
    var targets: [Double] = []
    let cluster: [[Float]] = (0..<k).map { _ in
        let target = mean + (low + width * clusterRNG.unit()) * deviation
        targets.append(target)
        return vector(dot: target, with: query, using: &clusterRNG)
    }
    var otherRNG = SplitMix64(seed: seed ^ 0x07_4E_52_11)
    let other: [[Float]] = (0..<extraHigh).map { _ in
        vector(dot: mean + (low + width * otherRNG.unit()) * deviation, with: query, using: &otherRNG)
    }
    var problem: String?
    for (index, row) in cluster.enumerated() where abs(dot(row, query) - targets[index]) > 1e-4 {
        problem = "setup: cluster row \(index) has dot \(dot(row, query)) with the query, expected \(targets[index])"
        break
    }
    var photoRNG = SplitMix64(seed: seed ^ 0x9407_0F11)
    let photos = (0..<6).map { _ in randomUnit(&photoRNG) }

    var result: ClusterTrial?
    try withTempHome { t in
        guard try createFolder(t) else { return }
        let store = try IndexStore()
        var inode: Int64 = 100
        func addFile(_ path: String, kind: String) throws -> Int64 {
            inode += 1
            return try store.addFile(path: path, kind: kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                     inode: inode, device: 16_777_220, status: "done")
        }
        func fill(_ vectors: [[Float]], prefix: String, label: String) throws {
            var written = 0
            var fileNumber = 0
            while written < vectors.count {
                let isPdf = fileNumber % 2 == 0
                let path = prefix + String(format: "%04d", fileNumber) + (isPdf ? ".pdf" : ".docx")
                let id = try addFile(path, kind: isPdf ? "pdf" : "doc")
                _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                         name: "sheet\(label)\(fileNumber)", body: "")
                for _ in 0..<(isPdf ? 10 : 5) where written < vectors.count {
                    _ = try store.addPassage(fileID: id, source: isPdf ? "page" : "chunk", start: 0, end: 0, modality: "text",
                                             vector: vectors[written], name: "", body: "")
                    written += 1
                }
                fileNumber += 1
            }
        }
        try fill(noise, prefix: "/docs/p", label: "n")
        try fill(cluster, prefix: clusterPrefix, label: "c")
        try fill(other, prefix: otherPrefix, label: "o")
        for (number, vector) in photos.enumerated() {
            let id = try addFile(String(format: "/photos/i%02d.jpg", number), kind: "photo")
            _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                     name: "frame\(number)", body: "")
            _ = try store.addPassage(fileID: id, source: "image", start: 0, end: 0, modality: "image", vector: vector,
                                     name: "", body: "")
        }
        store.close()
        let reader = IndexReader()
        defer { reader.close() }
        let list = try ranked(Search(reader: reader), clusterPhrase, query)
        result = ClusterTrial(shown: list.contains { $0.path.hasPrefix(clusterPrefix) }, listed: list.count,
                              textRowsListed: list.filter { $0.path.hasSuffix(".pdf") || $0.path.hasSuffix(".docx") }.count,
                              setupProblem: problem, seconds: Date().timeIntervalSince(started))
    }
    return try #require(result, "the trial did not run")
}

/// 20 seeded trials of one cell. Returns the trials that did not show a cluster row (their numbers), the count that did, and the time.
private func clusterCell(rows n: Int, cluster k: Int, cellSeed: UInt64, trials: Int = 20, low: Double = 5.6, width: Double = 0.8,
                         extraHigh: Int = 0) throws -> (passed: Int, missed: [Int], problems: [String], seconds: Double, listed: [Int]) {
    let started = Date()
    var passed = 0
    var missed: [Int] = []
    var problems: [String] = []
    var listed: [Int] = []
    for trial in 0..<trials {
        let outcome = try runClusterTrial(rows: n, cluster: k, seed: cellSeed &* 1_000 &+ UInt64(trial), low: low, width: width,
                                          extraHigh: extraHigh)
        if let problem = outcome.setupProblem { problems.append("trial \(trial): \(problem)") }
        if outcome.shown { passed += 1 } else { missed.append(trial) }
        listed.append(outcome.listed)
    }
    return (passed, missed, problems, Date().timeIntervalSince(started), listed)
}

@Suite("SearchTextGateScaleTests", .serialized)
struct SearchTextGateScaleTests {

    // MARK: a topic cluster must not hide itself (round 2)

    @Test(arguments: [200, 1000, 5000], [2, 5, 10])
    func aTopicClusterOfRowsAtAboutSixDeviationsIsShownByItsDescriptionInAtLeastNineteenOfTwentyTrials(rows: Int, percent: Int) throws {
        let k = rows * percent / 100
        let cell = try clusterCell(rows: rows, cluster: k, cellSeed: UInt64(rows * 100 + percent))
        print("CLUSTER n=\(rows) k=\(k) (\(percent)%): \(cell.passed) of 20 trials showed a cluster row, \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.problems.isEmpty, "\(cell.problems.prefix(3))")
        #expect(cell.passed >= 19,
                "\(rows) text rows, \(k) of them (\(percent)%) on the topic at about mean + 6 SD of the noise: only \(cell.passed) of 20 trials listed a cluster row (at least 19 needed); trials with none: \(cell.missed); list sizes \(cell.listed)")
    }

    // Green controls for the cluster rig itself: ONE related row (k = 1) at about 6 SD, built by the same code, is shown in at
    // least 19 of 20 trials today. A rig that cannot show a lone planted row would make every red above meaningless.
    @Test(arguments: [63, 1000, 5000])
    func aLoneRelatedRowAtAboutSixDeviationsBuiltByTheClusterRigIsShownInAtLeastNineteenOfTwentyTrials(rows: Int) throws {
        let cell = try clusterCell(rows: rows, cluster: 1, cellSeed: UInt64(rows * 100 + 1))
        print("CLUSTER-CONTROL n=\(rows) k=1: \(cell.passed) of 20 trials showed the row, \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.problems.isEmpty, "\(cell.problems.prefix(3))")
        #expect(cell.passed >= 19,
                "\(rows) text rows, one on the topic at about mean + 6 SD: only \(cell.passed) of 20 trials listed it; trials with none: \(cell.missed)")
    }

    @Test func inASixtyThreeRowLibraryAClusterOfSixRowsIsShownByItsDescriptionInAtLeastNineteenOfTwentyTrials() throws {
        let cell = try clusterCell(rows: 63, cluster: 6, cellSeed: 63_006)
        print("CLUSTER n=63 k=6: \(cell.passed) of 20 trials showed a cluster row, \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.problems.isEmpty, "\(cell.problems.prefix(3))")
        #expect(cell.passed >= 19,
                "63 text rows, 6 of them on the topic at about mean + 6 SD of the noise: only \(cell.passed) of 20 trials listed a cluster row (at least 19 needed); trials with none: \(cell.missed); list sizes \(cell.listed)")
    }

    // MARK: plan-4 review round 3 (fix round 3, tester step: must-fix 1, the noise estimate of the text gate)
    //
    // THE FINDING (round 3). The noise is estimated from the lowest 88 percent of the text dots, so a topic cluster above about 12
    // percent of the text rows lands inside that 88 percent, blows up the SD, and every z falls under the gate: a library that is 40
    // percent leases hides every lease row for a lease query. Same rig as the cells above (the noise SD and mean are those of the
    // noise rows only), but the cluster is spread 0.3 SD around mean + 6 SD (5.85 to 6.15) and is 15, 25 and 40 percent of the rows.
    // The two-topic cells add a second topic of the same size whose rows sit at the same height for the query (an extra high group
    // for the statistic; the query matches topic A only). The 12 percent cells at mean + 4 SD (3.85 to 4.15) pin that the noise
    // estimate does not over-correct. The 100-nonsense test below is the lower bound these may not break.
    //
    // SHAPES THIS PINS that the brief did not fix: topic B's files are /docs/otherNNNN.pdf and .docx and sit at the same height as
    // topic A for the query; spread 0.3 SD means the range 5.85 to 6.15 (3.85 to 4.15); 19 of 20 as "95 percent".

    @Test(arguments: [200, 1000, 5000], [15, 25, 40])
    func aLargeTopicClusterAtAboutSixDeviationsIsShownByItsDescriptionInAtLeastNineteenOfTwentyTrials(rows: Int, percent: Int) throws {
        let k = rows * percent / 100
        let cell = try clusterCell(rows: rows, cluster: k, cellSeed: UInt64(rows * 100 + percent + 7_000_000), low: 5.85, width: 0.3)
        print("LARGE-CLUSTER n=\(rows) k=\(k) (\(percent)%): \(cell.passed) of 20 trials showed a cluster row, \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.problems.isEmpty, "\(cell.problems.prefix(3))")
        #expect(cell.passed >= 19,
                "\(rows) text rows, \(k) of them (\(percent)%) on the topic at about mean + 6 SD of the noise: only \(cell.passed) of 20 trials listed a cluster row (at least 19 needed); trials with none: \(cell.missed); list sizes \(cell.listed)")
    }

    @Test(arguments: [200, 1000])
    func twoTopicsOfEightPercentEachShowTheTopicTheDescriptionMatchesInAtLeastNineteenOfTwentyTrials(rows: Int) throws {
        let k = rows * 8 / 100
        let cell = try clusterCell(rows: rows, cluster: k, cellSeed: UInt64(rows * 100 + 8 + 8_000_000), low: 5.85, width: 0.3, extraHigh: k)
        print("TWO-TOPICS n=\(rows) k=\(k)+\(k) (8% + 8%): \(cell.passed) of 20 trials listed a topic A row, \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.problems.isEmpty, "\(cell.problems.prefix(3))")
        #expect(cell.passed >= 19,
                "\(rows) text rows, topic A \(k) rows and another topic of \(k) rows both at about mean + 6 SD: only \(cell.passed) of 20 trials listed a topic A row (at least 19 needed); trials with none: \(cell.missed); list sizes \(cell.listed)")
    }

    // At 5,000 rows the 4 SD cell is REPORTED ONLY (no assertion). Inferred, not measured: the best of 5,000 noise rows is about
    // 3.5 to 3.7 SD above the mean, and the 100-nonsense test below needs a gate above that for at least 98 of 100 queries (about
    // 4.1 SD), while this cluster sits at 3.85 to 4.15 SD. Showing it in 19 of 20 trials and passing the nonsense bar together is not
    // possible with a gate on the dot's z alone, so asserting here would force a failure or a weaker nonsense bar (an owner's decision).
    @Test func aTwelvePercentClusterOnlyFourDeviationsAboveTheNoiseAtFiveThousandRowsIsReportedOnly() throws {
        let cell = try clusterCell(rows: 5000, cluster: 600, cellSeed: UInt64(5000 * 100 + 12 + 9_000_000), low: 3.85, width: 0.3)
        print("FOUR-SD-REPORTED-ONLY n=5000 k=600 (12%): \(cell.passed) of 20 trials showed a cluster row, \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.problems.isEmpty, "\(cell.problems.prefix(3))")
    }

    @Test(arguments: [200, 1000])
    func aTwelvePercentClusterOnlyFourDeviationsAboveTheNoiseIsShownInAtLeastNineteenOfTwentyTrials(rows: Int) throws {
        let k = rows * 12 / 100
        let cell = try clusterCell(rows: rows, cluster: k, cellSeed: UInt64(rows * 100 + 12 + 9_000_000), low: 3.85, width: 0.3)
        print("FOUR-SD n=\(rows) k=\(k) (12%): \(cell.passed) of 20 trials showed a cluster row, \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.problems.isEmpty, "\(cell.problems.prefix(3))")
        #expect(cell.passed >= 19,
                "\(rows) text rows, \(k) of them (12%) at about mean + 4 SD of the noise: only \(cell.passed) of 20 trials listed a cluster row (at least 19 needed); trials with none: \(cell.missed); list sizes \(cell.listed)")
    }

    // MARK: nonsense must not pass the text gate in a big library

    @Test func aHundredNonsenseDescriptionsInAFiveThousandRowTextLibraryShowAPdfOrDocumentRowAtMostTwice() throws {
        var queries = SplitMix64(seed: 77_031)
        let vectors = (0..<100).map { _ in randomUnit(&queries) }
        try withTextLibrary(rows: 5000, seed: 4_242_001) { search, _ in
            var shown: [(number: Int, text: String, paths: [String])] = []
            for (number, query) in vectors.enumerated() {
                let text = nonsense(number)
                let list = try ranked(search, text, query)
                let textRows = list.filter { $0.path.hasSuffix(".pdf") || $0.path.hasSuffix(".docx") }
                if !textRows.isEmpty { shown.append((number, text, textRows.map(\.path))) }
            }
            #expect(shown.count <= 2,
                    "\(shown.count) of 100 nonsense descriptions listed a PDF or document row (at most 2 allowed): \(shown.prefix(8).map { "#\($0.number) \"\($0.text)\" -> \($0.paths)" })")
        }
    }

    // MARK: a real match is still found first, whatever the size of the library (green controls)

    @Test(arguments: [63, 5000, 20_000])
    func aPlantedPassageSixDeviationsAboveTheNoiseIsFoundFirstByItsDescription(rows: Int) throws {
        var queries = SplitMix64(seed: UInt64(900 + rows))
        let query = randomUnit(&queries)
        try withTextLibrary(rows: rows, seed: UInt64(5_000_000 + rows), planting: query) { search, planted in
            let planted = try #require(planted)
            #expect(planted.dot > planted.mean + 5.9 * planted.deviation && planted.dot < planted.mean + 6.1 * planted.deviation,
                    "setup: the planted dot \(planted.dot) is not 6 deviations above the mean \(planted.mean) (deviation \(planted.deviation))")
            let list = try ranked(search, "invoice from landlord", query)
            #expect(list.first == Found(path: planted.path, passageID: planted.passageID),
                    "\(rows) text rows: expected the planted page first, got \(list.prefix(5).map(\.path)) of \(list.count) rows")
        }
    }
}
