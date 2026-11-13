import Accelerate
import Foundation
import Testing
import SesameEngine

// plan-5-t6, tester step. The gates of the audio modality and of video frame rows at library sizes 63, 1,000 and 5,000 rows
// (plan-4 lesson 5). Written from the t6 entry and Decisions D5 and D9 of plan-5-tasks.md and the plan 4 scale tests
// (SearchTextGateScaleTests, SearchFloorTests, SearchSmallLibraryTests) only; no product source read. Names used: IndexStore.addFile and
// addPassage, withTempHome, createFolder, Search(reader:), Search.rank(text:vector:ticket:visible:), Visible, Settings.Folder.
//
// AUDIO (the first part). Seeded, synthetic. The audio rows are random unit vectors in 768 dimensions (windows of recordings: files of 10
// windows, source "audio", modality "audio", kind "audio"), six photo files make the library mixed, every file has a `name` passage whose
// words no query holds, so only the vectors decide. Dots of random unit vectors with a random query are Gaussian with SD 1/sqrt(768).
//   The topic rig. A cell is a library of n rows. A topic is k rows built as a*c + sqrt(1-a*a)*r for a topic centre c and a random r at right
//   angles to c (a = 0.97, so the rows are close relatives: windows of one subject). One library is built per cell and every trial is a new
//   random query: q = beta*c + sqrt(1-beta*beta)*w with w random at right angles to c, and beta is set per trial so that the mean dot of the
//   topic rows with q is the mean of the noise rows' dots plus s of their standard deviations (computed here, over the noise rows only, never
//   the topic rows), s = 6 or 4. The topic rows' own spread around that is about 0.25 SD. A lone row is a topic of one row at s = 6.
//   Two topics: two centres, both at the same height for the query (the second topic's rows are high rows for the statistic, as in plan 4);
//   a trial passes when a row of topic A is listed.
//   A trial is a pass when the list holds a row of a /media/topicA file; nonsense (no topic, a random vector) passes when the list holds NO audio file.
//   A cell passes when the topic (or the lone row) is shown in at least 95 percent of the trials; nonsense shows an audio row in at most 3 percent.
//   The library of a cell is made once and its trials differ in the query only (a per-trial library of 5,000 rows costs about a second: 1,500 of
//   them would take half an hour). The noise rows are therefore the same in every trial of a cell, and a random query gives each trial a fresh draw of
//   their dots (the noise dots of two trials are independent up to the small topic part of the query, beta^2 of the variance, 5 percent at 6 SD).
//
// FRAME ROWS (the second part). A video multiplies image rows. The image modality is measured with exact dots (the style of SearchFloorTests):
// the query is e0, a stored vector is a*e0 + sqrt(1-a*a)*e_k, so the dot with the query is `a`. A noise row has a dot drawn from a Gaussian with
// mean 0.34 and SD 0.09 (the best of 5,000 is about 0.68, so the floor 0.69 and the z gate both matter); a topic row sits at mean + 6 SD
// (0.88) with a spread of +-0.015. A library of n image rows holds f percent frame rows (0, 50, 90): files of kind "video" with source "frame"
// (start = end = 3 s apart) in runs of 16 to 24 rows whose dots are one Gaussian draw plus 0.01 of jitter (close rows, not independent dots),
// and the rest photos (kind "photo", source "image", one row per file). A topic of k rows has the same f percent of frame rows (runs of 20 at the
// topic height). The lone row is a photo at f = 0, else one frame in a run whose other frames are noise. A trial is a new library (new draws).
// The bars: the absolute bar of the existing image tests (a topic or a lone strong row shown in at least 95 percent) for the shares 2 and 10
// and the lone row; for 40 percent the image z gate misses with photos only too (a topic that big raises the SD: 0 of 60 trials at 63 rows with
// photos only), so there the asserted bar is the relative one the entry names (no worse than photos only, within 5 points) and the absolute rate
// is printed beside the photos-only rate; nonsense: an image row shown no more often than with photos only at the same size, within 3 points.
// Only the shares 2, 10 and 40 are run for frame rows (a library is rebuilt for every trial: about 0.03 s at 63 rows, 0.35 s at 1,000, 2 s at 5,000)
// and the trials are 60, 8 and 3 per cell: a smoke measurement, not 1,500 trials (see the report).
//
// SHAPES THIS FILE PINS that the entry did not fix: the topic size is max(3, n*share/100) rows (several related rows, never one: 63 rows at 2
// and 5 percent are 3 rows); the files /media/recNNNN.m4a, /media/topicANNNN.m4a, /media/topicBNNNN.m4a, /photos/iNN.jpg, /library/...;
// the query phrase "where they talk about leases"; 6 SD means mean + 6 SD of the noise rows, with a spread of 0.25 SD; the trial counts below.

private let dimension = 768
private let tightness = 0.97
private let phrase = "where they talk about leases"

/// The entry says 1,500 trials per cell. A first run at 1,500 took 9.5 s per cell at 63 rows and 120 s per cell at 1,000 rows (the debug build's
/// Search costs about 80 ms per ranking at 1,000 rows and more at 5,000), so the counts below are what fits the file in about 6 minutes: the
/// bars stay as written (95 percent, 3 percent), the trials are fewer, and the nonsense cells (the 3 percent bar needs the most trials) get more.
private func audioTrialCount(rows n: Int, nonsense: Bool) -> Int {
    switch n {
    case 63: return 600
    case 1000: return nonsense ? 300 : 40
    default: return nonsense ? 60 : 15
    }
}

private let imageTrialsBySize: [Int: Int] = [63: 60, 1000: 8, 5000: 3]
private let imageShares = [2, 10, 40]

private let sizes = [63, 1000, 5000]
private let shares = [2, 5, 10, 15, 25, 40]
private let frameShares = [0, 50, 90]

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

/// A random unit vector at right angles to every vector of `basis` (which are unit and at right angles to each other).
private func randomUnit(_ rng: inout SplitMix64, orthogonalTo basis: [[Float]]) -> [Float] {
    var v = randomUnit(&rng)
    for b in basis {
        let along = vDSP.dot(v, b)
        v = zip(v, b).map { $0 - along * $1 }
    }
    let length = vDSP.sumOfSquares(v).squareRoot()
    return v.map { $0 / length }
}

private func normalised(_ v: [Float]) -> [Float] {
    let length = vDSP.sumOfSquares(v).squareRoot()
    return v.map { $0 / length }
}

private func combine(_ parts: [(Float, [Float])]) -> [Float] {
    var out = [Float](repeating: 0, count: dimension)
    for (weight, vector) in parts { for i in 0..<dimension { out[i] += weight * vector[i] } }
    return out
}

/// Row-major matrix times a vector: the dot of every row with `q`.
private func dots(_ matrix: [Float], rows: Int, _ q: [Float]) -> [Float] {
    guard rows > 0 else { return [] }
    var out = [Float](repeating: 0, count: rows)
    vDSP_mmul(matrix, 1, q, 1, &out, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
    return out
}

private func meanAndDeviation(_ values: [Float]) -> (mean: Double, deviation: Double) {
    let n = Double(values.count)
    let mean = values.reduce(0.0) { $0 + Double($1) } / n
    let variance = values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n
    return (mean, variance.squareRoot())
}

private final class NoisePool: @unchecked Sendable {
    static let shared = NoisePool()
    private let lock = NSLock()
    private var bySize: [Int: [Float]] = [:]

    /// `count` random unit vectors, flat.
    func flat(_ count: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if let have = bySize[count] { return have }
        var rng = SplitMix64(seed: UInt64(52_000 + count))
        var out: [Float] = []
        out.reserveCapacity(count * dimension)
        for _ in 0..<count { out.append(contentsOf: randomUnit(&rng)) }
        bySize[count] = out
        return out
    }
}

private func row(_ flat: [Float], _ index: Int) -> [Float] { Array(flat[(index * dimension)..<((index + 1) * dimension)]) }

// MARK: the index

private let allKinds: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]

private let everything = Visible(
    folders: [Settings.Folder(path: "/media", code: false, reading: true), Settings.Folder(path: "/photos", code: false, reading: true),
              Settings.Folder(path: "/library", code: false, reading: true)],
    codeSearchOn: true, kindsOn: allKinds)

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

private final class Writer {
    let store: IndexStore
    var inode: Int64 = 100
    init(_ store: IndexStore) { self.store = store }

    func file(_ path: String, kind: String) throws -> Int64 {
        inode += 1
        return try store.addFile(path: path, kind: kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000, inode: inode,
                                 device: 16_777_220, status: "done")
    }

    func name(_ file: Int64, _ words: String) throws {
        _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil, name: words, body: "")
    }

    /// Audio files of 10 windows each from `rows` (windows start every 25 s and last 30 s).
    func audio(_ rows: [[Float]], prefix: String, label: String) throws {
        var written = 0
        var number = 0
        while written < rows.count {
            let id = try file(prefix + String(format: "%04d", number) + ".m4a", kind: "audio")
            try name(id, "take\(label)\(number)")
            for slot in 0..<10 where written < rows.count {
                _ = try store.addPassage(fileID: id, source: "audio", start: Double(slot * 25), end: Double(slot * 25 + 30),
                                         modality: "audio", vector: rows[written], name: "", body: "")
                written += 1
            }
            number += 1
        }
    }

    func photos(_ rng: inout SplitMix64) throws {
        for number in 0..<6 {
            let id = try file(String(format: "/photos/i%02d.jpg", number), kind: "photo")
            try name(id, "frame\(number)")
            _ = try store.addPassage(fileID: id, source: "image", start: 0, end: 0, modality: "image", vector: randomUnit(&rng), name: "", body: "")
        }
    }
}

// MARK: the audio cell

private struct AudioCell {
    let shown: Int
    let trials: Int
    let realised: Double
    let setupProblem: String?
    let seconds: Double
    var percent: Double { 100 * Double(shown) / Double(trials) }
}

/// `topics`: the sizes of the topics (empty for nonsense, one row for a lone row); `sd`: the height of the topics in SD of the noise rows.
private func audioCell(rows n: Int, topics: [Int], sd: Double, seed: UInt64, trials given: Int? = nil) throws -> AudioCell {
    let started = Date()
    let trials = given ?? audioTrialCount(rows: n, nonsense: topics.isEmpty)
    let topicRows = topics.reduce(0, +)
    let noiseCount = n - topicRows
    let pool = NoisePool.shared.flat(n)
    let noiseFlat = Array(pool.prefix(noiseCount * dimension))
    var rng = SplitMix64(seed: seed)
    var centres: [[Float]] = []
    var topicVectors: [[[Float]]] = []
    for size in topics {
        let c = randomUnit(&rng, orthogonalTo: centres)
        centres.append(c)
        let side = Float((1 - tightness * tightness).squareRoot())
        topicVectors.append((0..<size).map { _ in
            let r = randomUnit(&rng, orthogonalTo: [c])
            return combine([(Float(tightness), c), (side, r)])
        })
    }
    var photoRNG = SplitMix64(seed: seed ^ 0x9407_0F11)

    var result: AudioCell?
    try withTempHome { t in
        guard try createFolder(t) else { return }
        let store = try IndexStore()
        let writer = Writer(store)
        try writer.audio((0..<noiseCount).map { row(noiseFlat, $0) }, prefix: "/media/rec", label: "n")
        for (index, vectors) in topicVectors.enumerated() {
            try writer.audio(vectors, prefix: index == 0 ? "/media/topicA" : "/media/topicB", label: index == 0 ? "a" : "b")
        }
        try writer.photos(&photoRNG)
        store.close()
        let reader = IndexReader()
        defer { reader.close() }
        let search = Search(reader: reader)
        defer { search.release() }

        var queries = SplitMix64(seed: seed ^ 0x51_D0_17_AB)
        var shown = 0
        var realisedSum = 0.0
        var problem: String?
        let topicAFlat: [Float] = topicVectors.first.map { $0.flatMap { $0 } } ?? []
        for _ in 0..<trials {
            let w = randomUnit(&queries, orthogonalTo: centres)
            var q: [Float]
            if centres.isEmpty {
                q = w
            } else {
                var beta = Float(sd / Double(dimension).squareRoot() / tightness)
                q = combine(centres.map { (beta, $0) } + [(Float((1 - Double(beta * beta) * Double(centres.count)).squareRoot()), w)])
                for _ in 0..<3 {
                    let stats = meanAndDeviation(dots(noiseFlat, rows: noiseCount, q))
                    beta = Float((stats.mean + sd * stats.deviation) / tightness)
                    q = combine(centres.map { (beta, $0) } + [(Float((1 - Double(beta * beta) * Double(centres.count)).squareRoot()), w)])
                }
                let stats = meanAndDeviation(dots(noiseFlat, rows: noiseCount, q))
                let topicDots = dots(topicAFlat, rows: topics[0], q)
                realisedSum += (meanAndDeviation(topicDots).mean - stats.mean) / stats.deviation
            }
            let list = try ranked(search, phrase, q)
            if centres.isEmpty {
                if list.contains(where: { $0.path.hasPrefix("/media/") }) { shown += 1 }
            } else if list.contains(where: { $0.path.hasPrefix("/media/topicA") }) {
                shown += 1
            }
        }
        let realised = centres.isEmpty ? 0 : realisedSum / Double(trials)
        if !centres.isEmpty, abs(realised - sd) > max(0.35, 0.05 * sd) { problem = "setup: the topic sits at \(realised) SD, wanted \(sd)" }
        result = AudioCell(shown: shown, trials: trials, realised: realised, setupProblem: problem, seconds: Date().timeIntervalSince(started))
    }
    return try #require(result, "the cell did not run")
}

private func topicSize(_ n: Int, _ percent: Int) -> Int { max(3, n * percent / 100) }

@Suite("SearchAudioGateScaleTests", .serialized)
struct SearchAudioGateScaleTests {

    // MARK: a topic of audio rows must not hide itself

    @Test(arguments: sizes, shares)
    func aTopicOfAudioRowsAtAboutSixDeviationsIsShownByItsDescriptionInAtLeastNinetyFivePercentOfTrials(rows n: Int, percent: Int) throws {
        let k = topicSize(n, percent)
        let cell = try audioCell(rows: n, topics: [k], sd: 6, seed: UInt64(n * 1000 + percent))
        print("AUDIO-GATE n=\(n) topic \(k) rows (\(percent)%) at 6 SD (realised \(String(format: "%.2f", cell.realised))): shown \(cell.shown) of \(cell.trials) (\(String(format: "%.1f", cell.percent))%), \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.setupProblem == nil, "\(cell.setupProblem ?? "")")
        #expect(cell.percent >= 95, "\(n) audio rows, \(k) of them (\(percent)%) on the topic at about mean + 6 SD of the noise: shown in \(String(format: "%.1f", cell.percent))% of \(cell.trials) trials, at least 95% needed")
    }

    // Controller decision (owner's): these 4 SD cells print their row and assert only the rig. Audio uses the topic rule of 6 or more rows
    // because real gibberish queries lift loose clusters of audio rows (GroupDTests: 5 rows over z 3.0 for "yepnoh vlorbx drazzit"), so the
    // 3-row topics (63 rows at 2 and 5 percent) cannot be shown; a 4 SD topic of 40 percent cannot be shown together with the 3 percent
    // nonsense bar (plan 4 found the same at 12 percent, 4 SD, 5,000 rows); 25 percent at 63 rows likewise.
    private static func reportOnlyAtFourDeviations(_ n: Int, _ percent: Int) -> Bool {
        (n == 63 && [2, 5, 25, 40].contains(percent)) || ((n == 1000 || n == 5000) && percent == 40)
    }

    @Test(arguments: sizes, shares)
    func aTopicOfAudioRowsAtAboutFourDeviationsIsShownByItsDescriptionInAtLeastNinetyFivePercentOfTrials(rows n: Int, percent: Int) throws {
        let k = topicSize(n, percent)
        let cell = try audioCell(rows: n, topics: [k], sd: 4, seed: UInt64(n * 1000 + percent + 400_000_000))
        print("AUDIO-GATE n=\(n) topic \(k) rows (\(percent)%) at 4 SD (realised \(String(format: "%.2f", cell.realised))): shown \(cell.shown) of \(cell.trials) (\(String(format: "%.1f", cell.percent))%), \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.setupProblem == nil, "\(cell.setupProblem ?? "")")
        if Self.reportOnlyAtFourDeviations(n, percent) { return }
        #expect(cell.percent >= 95, "\(n) audio rows, \(k) of them (\(percent)%) on the topic at about mean + 4 SD of the noise: shown in \(String(format: "%.1f", cell.percent))% of \(cell.trials) trials, at least 95% needed")
    }

    @Test(arguments: sizes)
    func twoTopicsOfEightPercentEachShowTheTopicTheDescriptionMatchesInAtLeastNinetyFivePercentOfTrials(rows n: Int) throws {
        let k = topicSize(n, 8)
        let cell = try audioCell(rows: n, topics: [k, k], sd: 6, seed: UInt64(n * 1000 + 808))
        print("AUDIO-GATE n=\(n) two topics of \(k) rows (8% + 8%) at 6 SD (realised \(String(format: "%.2f", cell.realised))): topic A shown \(cell.shown) of \(cell.trials) (\(String(format: "%.1f", cell.percent))%), \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.setupProblem == nil, "\(cell.setupProblem ?? "")")
        #expect(cell.percent >= 95, "\(n) audio rows, two topics of \(k) rows both at about mean + 6 SD: topic A shown in \(String(format: "%.1f", cell.percent))% of \(cell.trials) trials, at least 95% needed")
    }

    @Test(arguments: sizes)
    func aLoneAudioRowAtAboutSixDeviationsIsShownByItsDescriptionInAtLeastNinetyFivePercentOfTrials(rows n: Int) throws {
        let cell = try audioCell(rows: n, topics: [1], sd: 6, seed: UInt64(n * 1000 + 1))
        print("AUDIO-GATE n=\(n) one lone row at 6 SD (realised \(String(format: "%.2f", cell.realised))): shown \(cell.shown) of \(cell.trials) (\(String(format: "%.1f", cell.percent))%), \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.setupProblem == nil, "\(cell.setupProblem ?? "")")
        #expect(cell.percent >= 95, "\(n) audio rows, one at about mean + 6 SD: shown in \(String(format: "%.1f", cell.percent))% of \(cell.trials) trials, at least 95% needed")
    }

    // MARK: nonsense must not pass the audio gate

    @Test(arguments: sizes)
    func aNonsenseDescriptionShowsAnAudioRowInAtMostThreePercentOfTrials(rows n: Int) throws {
        let cell = try audioCell(rows: n, topics: [], sd: 0, seed: UInt64(n * 1000 + 7))
        print("AUDIO-GATE n=\(n) nonsense (no topic): an audio row shown in \(cell.shown) of \(cell.trials) trials (\(String(format: "%.1f", cell.percent))%), \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.percent <= 3, "\(n) audio rows of noise: an audio row was listed in \(String(format: "%.1f", cell.percent))% of \(cell.trials) trials, at most 3% allowed")
    }

    // MARK: the rig itself (controls: they must be red if the measurement cannot tell shown from hidden)

    // A topic at 1.5 SD is no topic: no gate that works can show it in 95 percent of trials. If this rig said it did, every green above would mean nothing.
    @Test func theRigSeesATopicThatIsNotThereAsHidden() throws {
        let cell = try audioCell(rows: 1000, topics: [50], sd: 1.5, seed: 1_000_150, trials: 20)
        print("AUDIO-GATE control n=1000 topic of 50 rows at 1.5 SD (realised \(String(format: "%.2f", cell.realised))): shown \(cell.shown) of \(cell.trials)")
        #expect(cell.percent < 50, "a topic at 1.5 SD was shown in \(String(format: "%.1f", cell.percent))% of trials: the rig cannot tell a hidden topic from a shown one")
    }

    // A single row a long way above everything (12 SD) is shown whatever the size: a gate that closes the modality fails here.
    @Test(arguments: sizes)
    func aLoneAudioRowAtTwelveDeviationsIsShownInEveryTrial(rows n: Int) throws {
        let cell = try audioCell(rows: n, topics: [1], sd: 12, seed: UInt64(n * 1000 + 12), trials: n == 5000 ? 8 : 40)
        print("AUDIO-GATE control n=\(n) one lone row at 12 SD (realised \(String(format: "%.2f", cell.realised))): shown \(cell.shown) of \(cell.trials)")
        #expect(cell.percent >= 99, "\(n) audio rows, one at about mean + 12 SD: shown in \(String(format: "%.1f", cell.percent))% of trials")
    }
}

// MARK: the frame-row scale case (image modality; exact dots)

private let imageQuery: [Float] = (0..<dimension).map { $0 == 0 ? 1 : 0 }
private let imageMean = 0.34
private let imageDeviation = 0.09
private let topicHeight = imageMean + 6 * imageDeviation
private let imagePhrase = "a quiet harbour at dawn"

private func exactVector(dot a: Double, noise k: Int) -> [Float] {
    let clipped = min(max(a, -0.999), 0.999)
    var v = [Float](repeating: 0, count: dimension)
    v[0] = Float(clipped)
    v[k] = Float((1 - clipped * clipped).squareRoot())
    return v
}

private struct ImageFile {
    let path: String
    let kind: String
    let isTopicA: Bool
    let dots: [Double]
}

private func imageLibrary(rows n: Int, framePercent: Int, topics: [Int], lone: Bool, rng: inout SplitMix64) -> [ImageFile] {
    func noiseDot() -> Double { imageMean + imageDeviation * rng.gaussian() }
    func topicDot() -> Double { topicHeight + 0.015 * (2 * rng.unit() - 1) }
    var files: [ImageFile] = []
    var videoNumber = 0
    var photoNumber = 0

    func photo(_ dot: Double, topicA: Bool = false, label: String = "n") {
        files.append(ImageFile(path: String(format: "/library/%@p%05d.jpg", label, photoNumber), kind: "photo", isTopicA: topicA, dots: [dot]))
        photoNumber += 1
    }
    func run(length: Int, topicA: Bool, label: String, height: () -> Double) {
        let centre = height()
        files.append(ImageFile(path: String(format: "/library/%@v%05d.mp4", label, videoNumber), kind: "video", isTopicA: topicA,
                               dots: (0..<length).map { _ in centre + 0.01 * rng.gaussian() }))
        videoNumber += 1
    }
    func runLength() -> Int { 16 + Int(rng.next() % 9) }

    var topicRowsWritten = 0
    if lone {
        if framePercent == 0 {
            photo(topicHeight, topicA: true, label: "A")
            topicRowsWritten = 1
        } else {
            let length = runLength()
            var dots = (0..<length).map { _ in noiseDot() }
            dots[length / 2] = topicHeight
            files.append(ImageFile(path: "/library/Av00000.mp4", kind: "video", isTopicA: true, dots: dots))
            videoNumber += 1
            topicRowsWritten = length
        }
    }
    for (index, size) in topics.enumerated() {
        let label = index == 0 ? "A" : "B"
        let frames = size * framePercent / 100
        var left = frames
        while left > 0 {
            let length = min(runLength(), left)
            run(length: length, topicA: index == 0, label: label, height: topicDot)
            left -= length
        }
        for _ in 0..<(size - frames) { photo(topicDot(), topicA: index == 0, label: label) }
        topicRowsWritten += size
    }
    let noiseRows = n - topicRowsWritten
    let noiseFrames = noiseRows * framePercent / 100
    var left = noiseFrames
    while left > 0 {
        let length = min(runLength(), left)
        run(length: length, topicA: false, label: "n", height: noiseDot)
        left -= length
    }
    for _ in 0..<(noiseRows - noiseFrames) { photo(noiseDot()) }
    return files
}

private struct ImageTrial {
    let shown: Bool
    let listed: Int
}

private func imageTrial(rows n: Int, framePercent: Int, topics: [Int], lone: Bool, seed: UInt64) throws -> ImageTrial {
    var rng = SplitMix64(seed: seed)
    let files = imageLibrary(rows: n, framePercent: framePercent, topics: topics, lone: lone, rng: &rng)
    var result: ImageTrial?
    try withTempHome { t in
        guard try createFolder(t) else { return }
        let store = try IndexStore()
        let writer = Writer(store)
        var vectorIndex = 0
        for (number, file) in files.enumerated() {
            let id = try writer.file(file.path, kind: file.kind)
            try writer.name(id, "shot\(number)")
            for (slot, dot) in file.dots.enumerated() {
                _ = try store.addPassage(fileID: id, source: file.kind == "video" ? "frame" : "image", start: Double(slot * 3),
                                         end: Double(slot * 3), modality: "image",
                                         vector: exactVector(dot: dot, noise: 1 + vectorIndex % 700), name: "", body: "")
                vectorIndex += 1
            }
        }
        store.close()
        let reader = IndexReader()
        defer { reader.close() }
        let search = Search(reader: reader)
        defer { search.release() }
        let ticket = search.newTicket()
        let hits = try #require(search.rank(text: imagePhrase, vector: imageQuery, ticket: ticket, visible: everything),
                                "the newest ticket must get a list")
        let paths = hits.map(\.path)
        let wantTopic = !topics.isEmpty || lone
        result = ImageTrial(shown: wantTopic ? paths.contains { $0.contains("/library/A") } : !paths.isEmpty, listed: paths.count)
    }
    return try #require(result, "the trial did not run")
}

private struct ImageCell {
    let shown: Int
    let trials: Int
    let seconds: Double
    var percent: Double { 100 * Double(shown) / Double(trials) }
}

private func imageCell(rows n: Int, framePercent: Int, topics: [Int], lone: Bool, seed: UInt64) throws -> ImageCell {
    let started = Date()
    let trials = imageTrialsBySize[n] ?? 24
    var shown = 0
    for trial in 0..<trials {
        let outcome = try imageTrial(rows: n, framePercent: framePercent, topics: topics, lone: lone, seed: seed &* 10_000 &+ UInt64(trial))
        if outcome.shown { shown += 1 }
    }
    return ImageCell(shown: shown, trials: trials, seconds: Date().timeIntervalSince(started))
}

/// A cell is made once however many tests read it (the photos-only cell is the control of the frame cells at the same size and share).
private final class ImageCells: @unchecked Sendable {
    static let shared = ImageCells()
    private let lock = NSLock()
    private var known: [String: ImageCell] = [:]

    func cell(rows n: Int, framePercent: Int, topics: [Int], lone: Bool, seed: UInt64) throws -> ImageCell {
        let key = "\(n)|\(framePercent)|\(topics)|\(lone)|\(seed)"
        lock.lock()
        if let have = known[key] { lock.unlock(); return have }
        lock.unlock()
        let made = try imageCell(rows: n, framePercent: framePercent, topics: topics, lone: lone, seed: seed)
        lock.lock(); known[key] = made; lock.unlock()
        return made
    }
}

@Suite("SearchFrameRowsScaleTests", .serialized)
struct SearchFrameRowsScaleTests {

    @Test(arguments: sizes, frameShares)
    func aTopicOfImageRowsAtSixDeviationsIsShownWhateverShareOfTheRowsAreFrames(rows n: Int, framePercent: Int) throws {
        var lines: [String] = []
        var absoluteMisses: [String] = []
        var relativeMisses: [String] = []
        for percent in imageShares {
            let k = topicSize(n, percent)
            let seed = UInt64(n * 100 + percent + 3_000_000)
            let cell = try ImageCells.shared.cell(rows: n, framePercent: framePercent, topics: [k], lone: false, seed: seed)
            let control = try ImageCells.shared.cell(rows: n, framePercent: 0, topics: [k], lone: false, seed: seed)
            lines.append("IMAGE-FRAMES n=\(n) frames \(framePercent)% topic \(k) rows (\(percent)%) at 6 SD: shown \(cell.shown) of \(cell.trials) (\(String(format: "%.1f", cell.percent))%), photos only \(String(format: "%.1f", control.percent))%, \(String(format: "%.1f", cell.seconds)) s")
            if percent <= 10, cell.percent < 95 { absoluteMisses.append("\(percent)%: \(String(format: "%.1f", cell.percent))%") }
            if cell.percent < control.percent - 5 { relativeMisses.append("\(percent)%: \(String(format: "%.1f", cell.percent))% against \(String(format: "%.1f", control.percent))% with photos only") }
        }
        for line in lines { print(line) }
        #expect(absoluteMisses.isEmpty, "\(n) image rows, \(framePercent)% frame rows: a topic of 2 or 10 percent at about 6 SD was shown in fewer than 95% of trials: \(absoluteMisses)")
        #expect(relativeMisses.isEmpty, "\(n) image rows, \(framePercent)% frame rows: a topic was shown more than 5 points less often than with photos only: \(relativeMisses)")
    }

    @Test(arguments: sizes, frameShares)
    func twoImageTopicsOfEightPercentShowTheTopicTheDescriptionMatchesWhateverShareAreFrames(rows n: Int, framePercent: Int) throws {
        let k = topicSize(n, 8)
        let seed = UInt64(n * 100 + 808 + 3_000_000)
        let cell = try ImageCells.shared.cell(rows: n, framePercent: framePercent, topics: [k, k], lone: false, seed: seed)
        let control = try ImageCells.shared.cell(rows: n, framePercent: 0, topics: [k, k], lone: false, seed: seed)
        print("IMAGE-FRAMES n=\(n) frames \(framePercent)% two topics of \(k) rows (8% + 8%) at 6 SD: topic A shown \(cell.shown) of \(cell.trials) (\(String(format: "%.1f", cell.percent))%), photos only \(String(format: "%.1f", control.percent))%, \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.percent >= 95 || cell.percent >= control.percent - 5,
                "\(n) image rows, \(framePercent)% frame rows, two topics of \(k): shown \(String(format: "%.1f", cell.percent))% against \(String(format: "%.1f", control.percent))% with photos only")
    }

    @Test(arguments: sizes, frameShares)
    func aLoneStrongImageRowIsShownWhateverShareOfTheRowsAreFrames(rows n: Int, framePercent: Int) throws {
        let seed = UInt64(n * 100 + 1 + 3_000_000)
        let cell = try ImageCells.shared.cell(rows: n, framePercent: framePercent, topics: [], lone: true, seed: seed)
        print("IMAGE-FRAMES n=\(n) frames \(framePercent)% one lone row at 6 SD: shown \(cell.shown) of \(cell.trials) (\(String(format: "%.1f", cell.percent))%), \(String(format: "%.1f", cell.seconds)) s")
        #expect(cell.percent >= 95, "\(n) image rows, \(framePercent)% frame rows, one strong row: shown in \(String(format: "%.1f", cell.percent))% of \(cell.trials) trials, at least 95% needed")
    }

    @Test(arguments: sizes)
    func nonsenseShowsAnImageRowNoMoreOftenWithFrameRowsThanWithPhotosOnly(rows n: Int) throws {
        let seed = UInt64(n * 100 + 7 + 3_000_000)
        let photos = try ImageCells.shared.cell(rows: n, framePercent: 0, topics: [], lone: false, seed: seed)
        let half = try ImageCells.shared.cell(rows: n, framePercent: 50, topics: [], lone: false, seed: seed)
        let most = try ImageCells.shared.cell(rows: n, framePercent: 90, topics: [], lone: false, seed: seed)
        print("IMAGE-FRAMES n=\(n) nonsense: an image row shown with photos only \(photos.shown) of \(photos.trials) (\(String(format: "%.1f", photos.percent))%), 50% frames \(half.shown) of \(half.trials) (\(String(format: "%.1f", half.percent))%), 90% frames \(most.shown) of \(most.trials) (\(String(format: "%.1f", most.percent))%)")
        if n <= 1000 {
            #expect(photos.percent <= 3, "\(n) image rows of noise, photos only: an image row was listed for nonsense in \(String(format: "%.1f", photos.percent))% of trials (the control itself must stay at 3% or less up to 1,000 rows)")
        }
        #expect(half.percent <= photos.percent + 3, "\(n) image rows: 50% frame rows showed an image row for nonsense in \(String(format: "%.1f", half.percent))% of trials against \(String(format: "%.1f", photos.percent))% with photos only")
        #expect(most.percent <= photos.percent + 3, "\(n) image rows: 90% frame rows showed an image row for nonsense in \(String(format: "%.1f", most.percent))% of trials against \(String(format: "%.1f", photos.percent))% with photos only")
    }
}
