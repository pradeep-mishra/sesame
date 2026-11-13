import Foundation
import Testing
import SesameEngine

// plan-5-t6, tester step. How the audio-window rows and the video-frame rows of the index are listed by the real Search. Written from the t6
// entry and Decisions D5, D6 and D9 of plan-5-tasks.md and the plan 1 to 4 tests (SearchFloorTests, SearchSmallLibraryTests,
// SearchExactTierTests) only; no product source read. Names used: IndexStore.addFile and addPassage, withTempHome, createFolder,
// Search(reader:), Search.rank(text:vector:ticket:visible:), Search.exactHits(text:visible:), Hit.path and Hit.passageID, Visible,
// Settings.Folder.
//
// THE LIBRARIES. Hand-made, the style of SearchFloorTests: the query is e0 = (1, 0, 0, ...) and a stored vector is a*e0 + sqrt(1-a^2)*e_k, so
// its dot with the query is exactly `a` (stored as half floats: within 0.0003). A video file is kind "video" with `frame` passages (modality
// image, start = end = the second) and `audio` passages (modality audio, start and end whole seconds: its soundtrack windows); an audio file
// is kind "audio" with `audio` passages; every file has a `name` passage. No stored word is in any query that is typed in a ranking test, so
// only the dots decide. Noise rows are seeded Gaussian dots (written here) with a mean and an SD per modality: a noise row is never listed.
//
// THE RULES THESE TESTS PIN.
//   (1) One row per file. A video that holds frame rows and audio-window rows, or a recording with 100 windows, is ONE row of the list, and its
//       Hit.passageID is the id of its best passage (the window's id for an audio hit, the frame's id for a frame hit; never the name passage).
//   (2) A query that matches only the soundtrack lists the video by its window; one that matches only its frames lists it by its frame.
//   (3) When both a frame and a window of one file pass their gates, the best passage is the one with the higher z-score WITHIN ITS OWN
//       MODALITY, not the higher raw dot (decided by this file, as the entry says: "if raw dots mislead"). Two libraries are built so that the raw
//       dot and the z-score name different passages, one each way.
//   (4) Each modality is judged against its own rows: an audio row is not judged by the image floor 0.69 (a window at 0.45 is shown), a frame
//       row is (a frame at 0.68 is not shown, at 0.70 it is), nonsense with 63 audio rows and 40 image rows lists nothing, and an audio row
//       whose dot is high against the audio rows is shown although the library's text rows are wide (its z is not taken over the text rows).
//   (5) A kind switched off in Visible removes the files of that kind only; the others are listed as before.
//   (6) The exact file name of an audio or video file typed whole is first (tier 1) with its name passage, whatever the dots of its windows and
//       frames, and a decoy with the same kind of name and a far higher dot is listed below it.
// What is NOT pinned, on purpose: the order of two different files that both pass; the passage of a video whose soundtrack matches when the
// Audio switch is off (printed only).

private let dimension = 768
private let query: [Float] = (0..<dimension).map { $0 == 0 ? 1 : 0 }
private let description = "where they talk about the harbour"

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

private func vector(dot a: Double, noise k: Int) -> [Float] {
    let clipped = min(max(a, -0.999), 0.999)
    var v = [Float](repeating: 0, count: dimension)
    v[0] = Float(clipped)
    v[k] = Float((1 - clipped * clipped).squareRoot())
    return v
}

private func storableAtOrAbove(_ x: Double) -> Double { (x * 2048).rounded(.up) / 2048 }
private func storableBelow(_ x: Double) -> Double { ((x * 2048).rounded(.up) - 1) / 2048 }

private let allKinds: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]

private func visible(_ kinds: [String: Bool] = allKinds) -> Visible {
    Visible(folders: ["/media", "/lib", "/photos", "/docs"].map { Settings.Folder(path: $0, code: false, reading: true) },
            codeSearchOn: true, kindsOn: kinds)
}

private struct Part {
    let source: String
    let modality: String
    let start: Double
    let end: Double
    let dot: Double
}

private func window(_ start: Double, _ dot: Double) -> Part { Part(source: "audio", modality: "audio", start: start, end: start + 30, dot: dot) }
private func frame(_ second: Double, _ dot: Double) -> Part { Part(source: "frame", modality: "image", start: second, end: second, dot: dot) }
private func photo(_ dot: Double) -> Part { Part(source: "image", modality: "image", start: 0, end: 0, dot: dot) }
private func chunk(_ dot: Double) -> Part { Part(source: "chunk", modality: "text", start: 0, end: 0, dot: dot) }

private struct Entry {
    let path: String
    let kind: String
    let name: String
    let parts: [Part]
    init(_ path: String, kind: String, name: String? = nil, _ parts: [Part]) {
        self.path = path
        self.kind = kind
        self.name = name ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: "") + "x"
        self.parts = parts
    }
}

/// `count` audio files of 8 windows each: noise dots Gaussian(mean 0, sd).
private func audioNoise(files count: Int, sd: Double, seed: UInt64) -> [Entry] {
    var rng = SplitMix64(seed: seed)
    return (0..<count).map { number in
        Entry(String(format: "/media/noise%03d.m4a", number), kind: "audio", name: "take\(number)",
              (0..<8).map { slot in window(Double(slot * 25), sd * rng.gaussian()) })
    }
}

/// `count` photos: one image row each, Gaussian(mean, sd).
private func imageNoise(count: Int, mean: Double, sd: Double, seed: UInt64) -> [Entry] {
    var rng = SplitMix64(seed: seed)
    return (0..<count).map { number in
        Entry(String(format: "/photos/noise%03d.jpg", number), kind: "photo", name: "scan\(number)", [photo(mean + sd * rng.gaussian())])
    }
}

/// `count` document files of one text chunk each, Gaussian(mean, sd).
private func textNoise(count: Int, mean: Double, sd: Double, seed: UInt64) -> [Entry] {
    var rng = SplitMix64(seed: seed)
    return (0..<count).map { number in
        Entry(String(format: "/docs/t%03d.txt", number), kind: "doc", name: "note\(number)", [chunk(mean + sd * rng.gaussian())])
    }
}

private struct Found: Hashable {
    let path: String
    let passageID: Int64
}

private struct Library {
    let search: Search
    let nameID: [String: Int64]
    let partIDs: [String: [Int64]]

    /// The hit of `path` whose best passage is its `part`-th (0-based, in the order the entry was written).
    func found(_ path: String, part: Int) -> Found { Found(path: path, passageID: partIDs[path]![part]) }
    func foundName(_ path: String) -> Found { Found(path: path, passageID: nameID[path]!) }
}

private func withLibrary(_ entries: [Entry], _ body: (Library) throws -> Void) throws {
    try withTempHome { t in
        guard try createFolder(t) else { return }
        let store = try IndexStore()
        var nameID: [String: Int64] = [:]
        var partIDs: [String: [Int64]] = [:]
        var vectorNumber = 0
        for (number, entry) in entries.enumerated() {
            let file = try store.addFile(path: entry.path, kind: entry.kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                         inode: Int64(100 + number), device: 16_777_220, status: "done")
            nameID[entry.path] = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                                      name: entry.name, body: "")
            for part in entry.parts {
                vectorNumber += 1
                let id = try store.addPassage(fileID: file, source: part.source, start: part.start, end: part.end, modality: part.modality,
                                              vector: vector(dot: part.dot, noise: 1 + vectorNumber % 700), name: "", body: "")
                partIDs[entry.path, default: []].append(id)
            }
        }
        store.close()
        let reader = IndexReader()
        defer { reader.close() }
        let search = Search(reader: reader)
        defer { search.release() }
        try body(Library(search: search, nameID: nameID, partIDs: partIDs))
    }
}

private func ranked(_ lib: Library, _ text: String = description, _ filter: Visible = visible()) throws -> [Found] {
    let ticket = lib.search.newTicket()
    let hits = try #require(lib.search.rank(text: text, vector: query, ticket: ticket, visible: filter), "the newest ticket must get a list")
    return hits.map { Found(path: $0.path, passageID: $0.passageID) }
}

private func paths(_ list: [Found]) -> [String] { list.map(\.path) }

/// The rows of the list that belong to one file (one row per file means exactly one).
private func rowsOf(_ list: [Found], _ path: String) -> [Found] { list.filter { $0.path == path } }

@Suite("SearchMediaRowsTests", .serialized)
struct SearchMediaRowsTests {

    // MARK: (1) and (2): one row per file, with the best passage

    // The soundtrack matches (window at 0.45, 9 SD above the audio noise); the frames are image noise (0.30), under the floor.
    @Test func aQueryThatMatchesOnlyTheSoundtrackListsTheVideoOnceByItsAudioWindow() throws {
        let trip = Entry("/lib/trip.mp4", kind: "video", name: "trip",
                         [frame(0, 0.30), frame(3, 0.31), frame(6, 0.29), window(0, 0.02), window(25, 0.45), window(50, 0.01)])
        try withLibrary(audioNoise(files: 10, sd: 0.05, seed: 1) + imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 2) + [trip]) { lib in
            let list = try ranked(lib)
            #expect(rowsOf(list, "/lib/trip.mp4") == [lib.found("/lib/trip.mp4", part: 4)],
                    "expected the video once, with its audio window at 25 s as the best passage, got \(list)")
        }
    }

    // The frames match (a frame at 0.80, 10 SD above the image noise and over the floor); the soundtrack is audio noise.
    @Test func aQueryThatMatchesOnlyTheFramesListsTheVideoOnceByItsFrame() throws {
        let trip = Entry("/lib/trip.mp4", kind: "video", name: "trip",
                         [frame(0, 0.30), frame(3, 0.31), frame(42, 0.80), frame(45, 0.33), window(0, 0.02), window(25, 0.03)])
        try withLibrary(audioNoise(files: 10, sd: 0.05, seed: 1) + imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 2) + [trip]) { lib in
            let list = try ranked(lib)
            #expect(rowsOf(list, "/lib/trip.mp4") == [lib.found("/lib/trip.mp4", part: 2)],
                    "expected the video once, with its frame at 42 s as the best passage, got \(list)")
        }
    }

    // A recording of 100 windows is one row (ten windows are on the topic, the best at 1250 s).
    @Test func aRecordingWithAHundredWindowsIsOneRowWithItsBestWindow() throws {
        var windows = (0..<100).map { window(Double($0 * 25), 0.01 * Double($0 % 5 - 2)) }
        for slot in [10, 11, 12, 13, 14, 60, 61, 62, 63] { windows[slot] = window(Double(slot * 25), 0.42) }
        windows[50] = window(1250, 0.50)
        let long = Entry("/media/long-talk.m4a", kind: "audio", name: "longtalk", windows)
        try withLibrary(audioNoise(files: 10, sd: 0.05, seed: 3) + [long]) { lib in
            let list = try ranked(lib)
            #expect(rowsOf(list, "/media/long-talk.m4a") == [lib.found("/media/long-talk.m4a", part: 50)],
                    "expected one row with the window at 1250 s, got \(list)")
        }
    }

    // Two files, each by its own kind of row, one row each.
    @Test func anAudioFileAndAVideoFileThatBothMatchAreOneRowEachWithTheirOwnPassage() throws {
        let talk = Entry("/media/harbour-talk.m4a", kind: "audio", name: "harbourtalk", [window(0, 0.01), window(25, 0.46), window(50, 0.02)])
        let trip = Entry("/lib/trip.mp4", kind: "video", name: "trip", [frame(0, 0.30), frame(12, 0.82), window(0, 0.01)])
        try withLibrary(audioNoise(files: 10, sd: 0.05, seed: 1) + imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 2) + [talk, trip]) { lib in
            let list = try ranked(lib)
            #expect(rowsOf(list, "/media/harbour-talk.m4a") == [lib.found("/media/harbour-talk.m4a", part: 1)], "the recording: got \(list)")
            #expect(rowsOf(list, "/lib/trip.mp4") == [lib.found("/lib/trip.mp4", part: 1)], "the video: got \(list)")
        }
    }

    // MARK: (3): the z-score within the modality, not the raw dot

    // Raw says the frame (0.74 against 0.40); the z-scores say the window (0.40 is 20 SD above audio noise of SD 0.02, the frame 4.4 SD above image noise of SD 0.10).
    @Test func whenBothPassTheWindowWithTheHigherZInItsOwnModalityWinsOverAFrameWithTheHigherRawDot() throws {
        let trip = Entry("/lib/trip.mp4", kind: "video", name: "trip", [frame(30, 0.74), window(25, 0.40)])
        try withLibrary(audioNoise(files: 10, sd: 0.02, seed: 4) + imageNoise(count: 40, mean: 0.30, sd: 0.10, seed: 5) + [trip]) { lib in
            let list = try ranked(lib)
            #expect(rowsOf(list, "/lib/trip.mp4") == [lib.found("/lib/trip.mp4", part: 1)],
                    "frame 0.74 is z 4.4 in image noise of SD 0.10, window 0.40 is z 20 in audio noise of SD 0.02: expected the window, got \(list)")
        }
    }

    // Raw says the window (0.90 against 0.78); the z-scores say the frame (0.78 is 12 SD above image noise of SD 0.04, the window 7.5 SD above audio noise of SD 0.12).
    @Test func whenBothPassTheFrameWithTheHigherZInItsOwnModalityWinsOverAWindowWithTheHigherRawDot() throws {
        let trip = Entry("/lib/trip.mp4", kind: "video", name: "trip", [frame(30, 0.78), window(25, 0.90)])
        try withLibrary(audioNoise(files: 10, sd: 0.12, seed: 6) + imageNoise(count: 40, mean: 0.30, sd: 0.04, seed: 7) + [trip]) { lib in
            let list = try ranked(lib)
            #expect(rowsOf(list, "/lib/trip.mp4") == [lib.found("/lib/trip.mp4", part: 0)],
                    "window 0.90 is z 7.5 in audio noise of SD 0.12, frame 0.78 is z 12 in image noise of SD 0.04: expected the frame, got \(list)")
        }
    }

    // MARK: (4): each modality on its own gate

    // 80 audio rows and 40 image rows of noise and no target: nothing is listed (the audio gate is as strict as the text gate).
    @Test func sixDifferentNonsenseDescriptionsListNoAudioRowAndNoFrameRowInANoiseOnlyLibrary() throws {
        let video = Entry("/lib/idle.mp4", kind: "video", name: "idle", (0..<10).map { frame(Double($0 * 3), 0.30 + 0.01 * Double($0 % 3)) } + [window(0, 0.02)])
        try withLibrary(audioNoise(files: 8, sd: 0.05, seed: 8) + imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 9) + [video]) { lib in
            for text in ["flurbo wazzik", "mrrgl tszzkq", "glorp snazzle quibbet", "yepnoh vlorbx drazzit", "blorf tszzk yepnoh vlimmer", "quazzle frimbo oglax dwemp"] {
                let list = try ranked(lib, text)
                #expect(list.isEmpty, "\"\(text)\": expected no rows in a library of noise, got \(paths(list))")
            }
        }
    }

    // The image floor 0.69 holds for a frame (0.68 hidden, 0.70 shown) and does not hold for a window (0.45 shown).
    @Test func aFrameBelowTheImageFloorIsNotListedAndOneAboveItIs() throws {
        let below = storableBelow(0.69)
        let above = storableAtOrAbove(0.69)
        #expect(below < 0.69 && above >= 0.69)
        try withLibrary(imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 10) + [Entry("/lib/low.mp4", kind: "video", name: "low", [frame(9, below)])]) { lib in
            let list = try ranked(lib)
            #expect(list.isEmpty, "a frame at \(below) is under the floor, got \(list)")
        }
        try withLibrary(imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 10) + [Entry("/lib/high.mp4", kind: "video", name: "high", [frame(9, above)])]) { lib in
            let list = try ranked(lib)
            #expect(list == [lib.found("/lib/high.mp4", part: 0)], "a frame at \(above) is at the floor, got \(list)")
        }
    }

    @Test func anAudioWindowAtZeroPointFourFiveIsListedAlthoughItIsUnderTheImageFloor() throws {
        let talk = Entry("/media/talk.m4a", kind: "audio", name: "talk", [window(0, 0.01), window(25, 0.45)])
        try withLibrary(audioNoise(files: 10, sd: 0.05, seed: 11) + imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 12) + [talk]) { lib in
            let list = try ranked(lib)
            #expect(rowsOf(list, "/media/talk.m4a") == [lib.found("/media/talk.m4a", part: 1)], "a window at 0.45 is 9 SD above the audio rows, got \(list)")
            #expect(paths(list) == ["/media/talk.m4a"], "only the recording with the window at 0.45 is listed, got \(paths(list))")
        }
    }

    // The window is 9 SD above the other audio rows; the 80 text rows are wide (SD 0.25), so a z taken over every non-image row would be 1.8.
    @Test func anAudioRowIsJudgedAgainstTheAudioRowsAndNotAgainstTheTextRows() throws {
        let talk = Entry("/media/talk.m4a", kind: "audio", name: "talk", [window(0, 0.01), window(25, 0.45)])
        try withLibrary(audioNoise(files: 10, sd: 0.05, seed: 13) + textNoise(count: 80, mean: 0.10, sd: 0.25, seed: 14)
                        + imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 15) + [talk]) { lib in
            let list = try ranked(lib)
            #expect(list.contains(lib.found("/media/talk.m4a", part: 1)), "the window is 9 SD above the audio rows but is not listed: \(paths(list))")
        }
    }

    // MARK: (5): kinds switched off in Visible

    @Test func aKindSwitchedOffRemovesThatKindsFilesAndTheOthersStayListed() throws {
        let talk = Entry("/media/talk.m4a", kind: "audio", name: "talk", [window(0, 0.01), window(25, 0.45)])
        let trip = Entry("/lib/trip.mp4", kind: "video", name: "trip", [frame(0, 0.30), frame(12, 0.82), window(0, 0.01)])
        let still = Entry("/photos/harbour.jpg", kind: "photo", name: "harbour", [photo(0.84)])
        try withLibrary(audioNoise(files: 10, sd: 0.05, seed: 1) + imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 2) + [talk, trip, still]) { lib in
            let all = try ranked(lib)
            #expect(Set(paths(all)) == ["/media/talk.m4a", "/lib/trip.mp4", "/photos/harbour.jpg"], "with every kind on: \(paths(all))")
            func on(_ off: String) -> Visible {
                var kinds = allKinds
                kinds[off] = false
                return visible(kinds)
            }
            let audioOff = try ranked(lib, description, on("audio"))
            #expect(Set(paths(audioOff)) == ["/lib/trip.mp4", "/photos/harbour.jpg"], "with Audio off: \(paths(audioOff))")
            let videoOff = try ranked(lib, description, on("video"))
            #expect(Set(paths(videoOff)) == ["/media/talk.m4a", "/photos/harbour.jpg"], "with Video off: \(paths(videoOff))")
            let photoOff = try ranked(lib, description, on("photo"))
            #expect(Set(paths(photoOff)) == ["/media/talk.m4a", "/lib/trip.mp4"], "with Photo off: \(paths(photoOff))")
            var none = allKinds
            none["audio"] = false
            none["video"] = false
            none["photo"] = false
            let nothing = try ranked(lib, description, visible(none))
            #expect(nothing.isEmpty, "with Audio, Video and Photo off nothing of this library is left, got \(paths(nothing))")
        }
    }

    // Printed only: the soundtrack of a video that matches only by its soundtrack, with Audio off and with Video off.
    @Test func reportWhatAVideoWhoseSoundtrackMatchesDoesWhenAudioIsOff() throws {
        let trip = Entry("/lib/trip.mp4", kind: "video", name: "trip", [frame(0, 0.30), window(25, 0.45)])
        try withLibrary(audioNoise(files: 10, sd: 0.05, seed: 1) + imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 2) + [trip]) { lib in
            var audioOff = allKinds
            audioOff["audio"] = false
            var videoOff = allKinds
            videoOff["video"] = false
            let a = try ranked(lib, description, visible(audioOff))
            let v = try ranked(lib, description, visible(videoOff))
            print("MEDIA-ROWS soundtrack-only video with Audio off lists \(paths(a)); with Video off lists \(paths(v))")
            #expect(v.isEmpty, "with Video off the video file is not listed: \(paths(v))")
        }
    }

    // MARK: (6): exact file names

    @Test func theExactNameOfAnAudioFileIsFirstWithItsNamePassageAndADecoyWithAFarHigherDotIsBelowIt() throws {
        let exact = Entry("/media/sleep-interview.m4a", kind: "audio", name: "sleep-interview.m4a", [window(0, 0.01), window(130, 0.02)])
        let decoy = Entry("/media/sleep-podcast.m4a", kind: "audio", name: "sleep-podcast.m4a", [window(0, 0.01), window(40, 0.48)])
        try withLibrary(audioNoise(files: 10, sd: 0.05, seed: 16) + [decoy, exact]) { lib in
            let hits = lib.search.exactHits(text: "sleep-interview.m4a", visible: visible())
            #expect(hits.map(\.path) == ["/media/sleep-interview.m4a"], "exactHits: \(hits.map(\.path))")
            let list = try ranked(lib, "sleep-interview.m4a")
            #expect(list.first == lib.foundName("/media/sleep-interview.m4a"), "the exact name is first with its name passage, got \(list)")
            #expect(list.contains(lib.found("/media/sleep-podcast.m4a", part: 1)), "the decoy (a window at 0.48) is listed below it, got \(list)")
            #expect(list.filter { $0.path == "/media/sleep-interview.m4a" }.count == 1, "the exact file is listed once: \(list)")
        }
    }

    @Test func theExactNameOfAVideoFileIsFirstWithItsNamePassageAndADecoyWithAFarHigherDotIsBelowIt() throws {
        let exact = Entry("/lib/safari-zebra.mp4", kind: "video", name: "safari-zebra.mp4", [frame(0, 0.30), frame(42, 0.31), window(0, 0.01)])
        let decoy = Entry("/lib/safari-giraffe.mp4", kind: "video", name: "safari-giraffe.mp4", [frame(0, 0.30), frame(20, 0.84)])
        try withLibrary(imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 17) + [decoy, exact]) { lib in
            let hits = lib.search.exactHits(text: "safari-zebra.mp4", visible: visible())
            #expect(hits.map(\.path) == ["/lib/safari-zebra.mp4"], "exactHits: \(hits.map(\.path))")
            let list = try ranked(lib, "safari-zebra.mp4")
            #expect(list.first == lib.foundName("/lib/safari-zebra.mp4"), "the exact name is first with its name passage, got \(list)")
            #expect(list.contains(lib.found("/lib/safari-giraffe.mp4", part: 1)), "the decoy (a frame at 0.84) is listed below it, got \(list)")
        }
    }

    // The name rows of a recording and a video are found by the words of the name typed alone (a file name has no space: one token, so the
    // relaxed top 5 may follow the exact file; only the first place is pinned).
    @Test func aNameTypedAloneFindsTheAudioAndTheVideoFileByTheirNamePassages() throws {
        let talk = Entry("/media/interview-raw-take3.wav", kind: "audio", name: "interview-raw-take3.wav", [window(0, 0.01)])
        let trip = Entry("/lib/ocean-trip.mov", kind: "video", name: "ocean-trip.mov", [frame(0, 0.30)])
        try withLibrary(audioNoise(files: 10, sd: 0.05, seed: 18) + imageNoise(count: 40, mean: 0.30, sd: 0.05, seed: 19) + [talk, trip]) { lib in
            let audio = try ranked(lib, "interview-raw-take3.wav")
            #expect(audio.first == lib.foundName("/media/interview-raw-take3.wav"), "got \(audio)")
            let video = try ranked(lib, "ocean-trip.mov")
            #expect(video.first == lib.foundName("/lib/ocean-trip.mov"), "got \(video)")
        }
    }
}
