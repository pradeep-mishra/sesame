import Foundation
import Testing
import SesameEngine

// plan-2-t15, tester step: the Estimator, the honest time estimate the setup, Settings and the menu show.
// Written from plan-2-tasks.md (entry t15, whose Tests paragraph holds the wording rule and the rows), design sections 2,
// 3 and 8 ("counts times seconds per kind measured by `index bench`"), spec S6 and S7, and the plan-1 tests as the one
// place the settings types are read. No product source was read; every expected value below is written by hand from
// the rule, never computed by the code under test.
//
// THE SHAPE THESE TESTS PIN (new API; today `Estimator` does not exist, so this file does not compile until it does).
// The entry names the two calls and the two result fields `seconds` and `text`; the argument types are this file's pick,
// taken from the places the values already live (`FolderCounts.summary`, `settings.json`'s `speeds` and `kindsOn`):
//
//     public enum Estimator {   // or a struct; only the two static calls are used
//         public static func estimate(counts: [String: Int], speeds: [String: Double],
//                                     kindsOn: [String: Bool], modelWhole: Bool) -> <result>
//         public static func left(remaining: [String: Int], speeds: [String: Double],
//                                 kindsOn: [String: Bool]) -> <result>
//     }
//     <result> has `seconds` (a number of seconds; read here through Double(...)) and `text` (String).
//
// - Kinds are the plan-1 strings "photo", "pdf", "doc", "audio", "video". `speeds` is seconds per file per kind;
//   a kind with no entry has no measured speed. `kindsOn` names all five kinds in the tests up to the plan-5-t8 section at the
//   end of the suite; that section's tests leave keys out on purpose (a kind counts unless its key is false).
//
// THE RULE (the entry's pick), which the tables below are written from by hand:
//   total seconds = sum over kinds of count x speed, only for a kind that is on in `kindsOn` AND has a measured speed.
//   - the model not whole                          -> "after the model download", whatever the speeds
//   - the model whole, no speed for photos yet     -> "measuring speed"
//   - zero seconds, a speed measured               -> "nothing to read"
//   - under 60 s                                   -> "under a minute"
//   - 60 s up to but not including 3,570 s         -> "about N min", N = seconds / 60 rounded half up
//   - 3,570 s and over                             -> total minutes rounded to the nearest 5, then "about H h M min",
//                                                     or "about H h" when M is 0

private let allKinds = ["photo", "pdf", "doc", "audio", "video"]

private func on(_ kinds: String...) -> [String: Bool] {
    Dictionary(uniqueKeysWithValues: allKinds.map { ($0, kinds.contains($0)) })
}

private let everythingOn = on("photo", "pdf", "doc", "audio", "video")

private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

// One photo per second: `files` photos at 1.0 s give exactly `files` seconds, so each row is the edge it names.
private let photoAtOneSecond: [String: Double] = ["photo": 1.0]

// Hand-written: (seconds, text). Seconds are given as a count of photos at 1.0 s each.
private let edgeRows: [(seconds: Int, text: String)] = [
    (1, "under a minute"),
    (30, "under a minute"),
    (59, "under a minute"),
    (60, "about 1 min"),
    (89, "about 1 min"),       // 1.48 min rounds down
    (90, "about 2 min"),       // 1.5 min rounds half up
    (149, "about 2 min"),      // 2.48
    (150, "about 3 min"),      // 2.5 half up
    (600, "about 10 min"),
    (3540, "about 59 min"),
    (3569, "about 59 min"),    // 59.48 min, still the minutes form
    (3570, "about 1 h"),       // 59.5 min is 60 to the nearest 5: the hours form, M is 0
    (3600, "about 1 h"),
    (3660, "about 1 h"),       // 61 min -> 60
    (3720, "about 1 h"),       // 62 min -> 60
    (3780, "about 1 h 5 min"), // 63 min -> 65
    (3900, "about 1 h 5 min"), // 65 min
    (5400, "about 1 h 30 min"),
    (7020, "about 1 h 55 min"), // 117 min -> 115
    (7080, "about 2 h"),        // 118 min -> 120
    (7200, "about 2 h"),
    (7800, "about 2 h 10 min"), // 130 min
    (9000, "about 2 h 30 min"), // 150 min
    (86400, "about 24 h"),      // 1,440 min
    (100_000, "about 27 h 45 min"), // 1,666.7 min -> 1,665
]

@Suite("EstimatorTests")
struct EstimatorTests {

    // MARK: the entry's own rows

    @Test func fiveThousandPhotosAtThreeTenthsOfASecondTakeAboutTwentyFiveMinutes() {
        let r = Estimator.estimate(counts: ["photo": 5000], speeds: ["photo": 0.3], kindsOn: everythingOn, modelWhole: true)
        #expect(r.text == "about 25 min", "got \(r.text)")
        #expect(close(Double(r.seconds), 1500), "got \(r.seconds) s, want 1500")
    }

    @Test func twentySixThousandPhotosAtThreeTenthsTakeAboutTwoHoursTenMinutes() {
        let r = Estimator.estimate(counts: ["photo": 26_000], speeds: ["photo": 0.3], kindsOn: everythingOn, modelWhole: true)
        #expect(r.text == "about 2 h 10 min", "got \(r.text)")
        #expect(close(Double(r.seconds), 7800), "got \(r.seconds) s, want 7800")
    }

    @Test func aHundredPhotosAtThreeTenthsAreUnderAMinute() {
        let r = Estimator.estimate(counts: ["photo": 100], speeds: ["photo": 0.3], kindsOn: everythingOn, modelWhole: true)
        #expect(r.text == "under a minute", "got \(r.text)")
        #expect(close(Double(r.seconds), 30), "got \(r.seconds) s, want 30")
    }

    // MARK: the edges of the wording rule

    @Test func everyEdgeOfTheWordingRuleGivesItsHandWrittenText() {
        for row in edgeRows {
            let r = Estimator.estimate(counts: ["photo": row.seconds], speeds: photoAtOneSecond, kindsOn: everythingOn, modelWhole: true)
            #expect(r.text == row.text, "\(row.seconds) s: got \"\(r.text)\", want \"\(row.text)\"")
            #expect(close(Double(r.seconds), Double(row.seconds)), "\(row.seconds) s: seconds came back as \(r.seconds)")
        }
    }

    @Test func halfASecondPerPhotoCrossesTheMinuteBetweenOneHundredNineteenAndOneHundredTwenty() {
        let under = Estimator.estimate(counts: ["photo": 119], speeds: ["photo": 0.5], kindsOn: everythingOn, modelWhole: true)
        #expect(under.text == "under a minute", "59.5 s: got \(under.text)")
        #expect(close(Double(under.seconds), 59.5), "got \(under.seconds)")
        let over = Estimator.estimate(counts: ["photo": 120], speeds: ["photo": 0.5], kindsOn: everythingOn, modelWhole: true)
        #expect(over.text == "about 1 min", "60 s: got \(over.text)")
    }

    // MARK: nothing to read, measuring, and the model not whole

    @Test func zeroSecondsWithAMeasuredSpeedIsNothingToRead() {
        for counts: [String: Int] in [[:], ["photo": 0], Dictionary(uniqueKeysWithValues: allKinds.map { ($0, 0) })] {
            let r = Estimator.estimate(counts: counts, speeds: ["photo": 0.3], kindsOn: everythingOn, modelWhole: true)
            #expect(r.text == "nothing to read", "counts \(counts): got \(r.text)")
            #expect(close(Double(r.seconds), 0), "counts \(counts): seconds \(r.seconds)")
        }
    }

    @Test func theModelWholeAndNoPhotoSpeedYetIsMeasuringSpeed() {
        let none = Estimator.estimate(counts: ["photo": 5000], speeds: [:], kindsOn: everythingOn, modelWhole: true)
        #expect(none.text == "measuring speed", "no speeds: got \(none.text)")
        // a speed for another kind is not a speed for photos
        let other = Estimator.estimate(counts: ["photo": 100, "pdf": 40], speeds: ["pdf": 2.0], kindsOn: everythingOn, modelWhole: true)
        #expect(other.text == "measuring speed", "only a pdf speed: got \(other.text)")
    }

    @Test func theModelNotWholeIsAfterTheModelDownloadWhateverTheSpeeds() {
        let speedTables: [[String: Double]] = [
            [:],
            ["photo": 0.3],
            ["photo": 0.3, "pdf": 1.5, "doc": 2.0, "audio": 4.0, "video": 10.0, "code": 0.25],
        ]
        let countTables: [[String: Int]] = [
            ["photo": 5000],
            ["photo": 100, "pdf": 12],
            ["photo": 26_000, "pdf": 900, "doc": 40, "audio": 3, "video": 2],
        ]
        for speeds in speedTables {
            for counts in countTables {
                let r = Estimator.estimate(counts: counts, speeds: speeds, kindsOn: everythingOn, modelWhole: false)
                #expect(r.text == "after the model download", "speeds \(speeds), counts \(counts): got \(r.text)")
            }
        }
    }

    // MARK: the sum is counts times speeds per kind; unread kinds never inflate it

    @Test func theSumIsCountsTimesSpeedsPerKind() {
        let counts = ["photo": 1000, "pdf": 200, "doc": 100, "audio": 50, "video": 10]
        let speeds = ["photo": 0.3, "pdf": 1.5, "doc": 2.0, "audio": 4.0, "video": 10.0, "code": 0.25]
        let r = Estimator.estimate(counts: counts, speeds: speeds, kindsOn: everythingOn, modelWhole: true)
        #expect(close(Double(r.seconds), 1100), "got \(r.seconds) s, want 1100")
        #expect(r.text == "about 18 min", "got \(r.text)")
    }

    @Test func aProductNotASumOfCountsAndSpeedsSeparately() {
        // 7 x 12.5 = 87.5 and 3 x 20 = 60: 147.5 s, 2.46 min
        let r = Estimator.estimate(counts: ["photo": 7, "pdf": 3], speeds: ["photo": 12.5, "pdf": 20.0], kindsOn: everythingOn, modelWhole: true)
        #expect(close(Double(r.seconds), 147.5), "got \(r.seconds) s, want 147.5")
        #expect(r.text == "about 2 min", "got \(r.text)")
    }

    @Test func kindsWithNoMeasuredSpeedContributeZero() {
        let counts = ["photo": 1000, "pdf": 9000, "doc": 4000, "audio": 5000, "video": 3000]
        let r = Estimator.estimate(counts: counts, speeds: ["photo": 0.3], kindsOn: everythingOn, modelWhole: true)
        #expect(close(Double(r.seconds), 300), "got \(r.seconds) s, want 300")
        #expect(r.text == "about 5 min", "got \(r.text)")
    }

    @Test func aKindSwitchedOffInKindsOnContributesZeroEvenWithASpeed() {
        let counts = ["photo": 1000, "pdf": 500]
        let speeds = ["photo": 0.3, "pdf": 2.0]
        let pdfOff = Estimator.estimate(counts: counts, speeds: speeds, kindsOn: on("photo", "doc", "audio", "video"), modelWhole: true)
        #expect(close(Double(pdfOff.seconds), 300), "pdf off: got \(pdfOff.seconds) s, want 300")
        #expect(pdfOff.text == "about 5 min", "pdf off: got \(pdfOff.text)")
        let photoOff = Estimator.estimate(counts: counts, speeds: speeds, kindsOn: on("pdf", "doc", "audio", "video"), modelWhole: true)
        #expect(close(Double(photoOff.seconds), 1000), "photo off: got \(photoOff.seconds) s, want 1000")
        #expect(photoOff.text == "about 17 min", "photo off: got \(photoOff.text)")   // 16.67 min
        let bothOn = Estimator.estimate(counts: counts, speeds: speeds, kindsOn: everythingOn, modelWhole: true)
        #expect(close(Double(bothOn.seconds), 1300), "both on: got \(bothOn.seconds) s, want 1300")
        #expect(bothOn.text == "about 22 min", "both on: got \(bothOn.text)")       // 21.67 min
    }

    @Test func everythingSwitchedOffOrUnreadIsNothingToRead() {
        let counts = ["photo": 5000, "pdf": 800]
        let off = Estimator.estimate(counts: counts, speeds: ["photo": 0.3], kindsOn: on(), modelWhole: true)
        #expect(off.text == "nothing to read", "all off: got \(off.text)")
        #expect(close(Double(off.seconds), 0), "all off: seconds \(off.seconds)")
        let photosOff = Estimator.estimate(counts: counts, speeds: ["photo": 0.3], kindsOn: on("pdf", "doc", "audio", "video"), modelWhole: true)
        #expect(photosOff.text == "nothing to read", "photos off, pdf has no speed: got \(photosOff.text)")
        #expect(close(Double(photosOff.seconds), 0), "photos off: seconds \(photosOff.seconds)")
    }

    // MARK: left(remaining:speeds:kindsOn:), the same rule for the time left while indexing

    @Test func leftGivesTheEntrysRowsToo() {
        let a = Estimator.left(remaining: ["photo": 5000], speeds: ["photo": 0.3], kindsOn: everythingOn)
        #expect(a.text == "about 25 min", "got \(a.text)")
        #expect(close(Double(a.seconds), 1500), "got \(a.seconds)")
        let b = Estimator.left(remaining: ["photo": 26_000], speeds: ["photo": 0.3], kindsOn: everythingOn)
        #expect(b.text == "about 2 h 10 min", "got \(b.text)")
        let c = Estimator.left(remaining: ["photo": 100], speeds: ["photo": 0.3], kindsOn: everythingOn)
        #expect(c.text == "under a minute", "got \(c.text)")
    }

    @Test func leftHasTheSameEdgesAsEstimate() {
        for row in edgeRows {
            let r = Estimator.left(remaining: ["photo": row.seconds], speeds: photoAtOneSecond, kindsOn: everythingOn)
            #expect(r.text == row.text, "\(row.seconds) s left: got \"\(r.text)\", want \"\(row.text)\"")
            #expect(close(Double(r.seconds), Double(row.seconds)), "\(row.seconds) s left: seconds came back as \(r.seconds)")
        }
    }

    @Test func leftWithNothingRemainingIsNothingToRead() {
        for remaining: [String: Int] in [[:], ["photo": 0]] {
            let r = Estimator.left(remaining: remaining, speeds: ["photo": 0.3], kindsOn: everythingOn)
            #expect(r.text == "nothing to read", "remaining \(remaining): got \(r.text)")
            #expect(close(Double(r.seconds), 0), "remaining \(remaining): seconds \(r.seconds)")
        }
    }

    @Test func leftSumsPerKindAndSkipsUnreadKinds() {
        let sum = Estimator.left(remaining: ["photo": 1000, "pdf": 200, "doc": 100, "audio": 50, "video": 10],
                                 speeds: ["photo": 0.3, "pdf": 1.5, "doc": 2.0, "audio": 4.0, "video": 10.0, "code": 0.25],
                                 kindsOn: everythingOn)
        #expect(close(Double(sum.seconds), 1100), "got \(sum.seconds) s, want 1100")
        #expect(sum.text == "about 18 min", "got \(sum.text)")

        let noSpeed = Estimator.left(remaining: ["photo": 1000, "pdf": 9000, "audio": 5000], speeds: ["photo": 0.3], kindsOn: everythingOn)
        #expect(close(Double(noSpeed.seconds), 300), "kinds with no speed: got \(noSpeed.seconds) s, want 300")
        #expect(noSpeed.text == "about 5 min", "kinds with no speed: got \(noSpeed.text)")

        let pdfOff = Estimator.left(remaining: ["photo": 1000, "pdf": 500], speeds: ["photo": 0.3, "pdf": 2.0],
                                    kindsOn: on("photo", "doc", "audio", "video"))
        #expect(close(Double(pdfOff.seconds), 300), "pdf off: got \(pdfOff.seconds) s, want 300")
        #expect(pdfOff.text == "about 5 min", "pdf off: got \(pdfOff.text)")

        let allOff = Estimator.left(remaining: ["photo": 5000], speeds: ["photo": 0.3], kindsOn: on())
        #expect(allOff.text == "nothing to read", "all off: got \(allOff.text)")
    }

    // MARK: plan-5-t8, tester step: a kind counts unless `kindsOn[kind] == false`
    //
    // Written from the entry '### plan-5-t8' of plan-5-tasks.md (Tests: EstimatorTests extended, with its amendment reason) and Decision D1.
    // AMENDMENT AND REASON: a kind with no key in `kindsOn` was counted as off, so a default `settings.json` (which holds only `photo`) made the
    // estimate leave out every PDF, document, audio and video file. The rule of the header is now "total = sum over kinds of count x speed, for
    // a kind whose `kindsOn[kind]` is not false (a missing key counts, as in `Visible`) and that has a measured speed". No earlier test in this
    // file is changed: every one of them names all six kinds in `kindsOn`, so none pinned "absent means off"; the header sentence "kindsOn
    // always names all six kinds in these tests" is true of the tests above and is not true of the ones below, which are the point.
    //
    // The counts are the 500-file mix: 220 photos, 120 documents, 100 PDFs, 40 audio files, 20 videos. Speeds (seconds per file) are chosen
    // exactly representable in binary so every sum is exact, and no total sits on a rounding edge:
    //   photo 220 x 0.25 = 55, pdf 100 x 1.5 = 150, doc 120 x 0.5 = 60, audio 40 x 3.0 = 120, video 20 x 7.0 = 140. Sum 525 s = 8.75 min,
    //   so "about 9 min".
    //   Without one kind: no photo 470 s (7.83 min, about 8), no pdf 375 s (6.25, about 6), no doc 465 s (7.75, about 8), no audio 405 s
    //   (6.75, about 7), no video 385 s (6.42, about 6).

    private let mixCounts = ["photo": 220, "doc": 120, "pdf": 100, "audio": 40, "video": 20]
    private let mixSpeeds = ["photo": 0.25, "pdf": 1.5, "doc": 0.5, "audio": 3.0, "video": 7.0]
    private let mixWithout: [(kind: String, seconds: Double, text: String)] = [
        ("photo", 470, "about 8 min"), ("pdf", 375, "about 6 min"), ("doc", 465, "about 8 min"), ("audio", 405, "about 7 min"), ("video", 385, "about 6 min"),
    ]

    @Test func theMixCountedWithEveryKindExplicitlyOnIsTheHandSum() {
        // GUARD: holds before the change (every key is present and true).
        let r = Estimator.estimate(counts: mixCounts, speeds: mixSpeeds, kindsOn: everythingOn, modelWhole: true)
        #expect(close(Double(r.seconds), 525), "got \(r.seconds) s, want 525 (55 + 150 + 60 + 120 + 140)")
        #expect(r.text == "about 9 min", "got \(r.text)")
    }

    @Test func aDefaultSettingsFileThatHoldsOnlyPhotoStillCountsEveryOtherKindOfTheMix() {
        let r = Estimator.estimate(counts: mixCounts, speeds: mixSpeeds, kindsOn: ["photo": true], modelWhole: true)
        #expect(close(Double(r.seconds), 525), "kindsOn holds only photo: got \(r.seconds) s, want 525; the PDFs, documents, audio and video were left out")
        #expect(r.text == "about 9 min", "kindsOn holds only photo: got \(r.text)")
    }

    @Test func aKindsOnWithNoKeysAtAllCountsEveryKind() {
        let r = Estimator.estimate(counts: mixCounts, speeds: mixSpeeds, kindsOn: [:], modelWhole: true)
        #expect(close(Double(r.seconds), 525), "kindsOn is empty: got \(r.seconds) s, want 525")
        #expect(r.text == "about 9 min", "kindsOn is empty: got \(r.text)")
    }

    @Test func theKeyOfOnlyOtherKindsDoesNotLeaveTheMissingOnesOut() {
        // photo has no key here at all; pdf is the only key, true; code is false and has no count
        let r = Estimator.estimate(counts: mixCounts, speeds: mixSpeeds, kindsOn: ["pdf": true, "code": false], modelWhole: true)
        #expect(close(Double(r.seconds), 525), "kindsOn holds pdf and code only: got \(r.seconds) s, want 525")
    }

    @Test func aKindSetToFalseIsTheOnlyWayToLeaveItOutWhenTheOtherKindsHaveNoKey() {
        for item in mixWithout {
            let r = Estimator.estimate(counts: mixCounts, speeds: mixSpeeds, kindsOn: [item.kind: false], modelWhole: true)
            #expect(close(Double(r.seconds), item.seconds), "only \(item.kind) is false: got \(r.seconds) s, want \(item.seconds)")
            #expect(r.text == item.text, "only \(item.kind) is false: got \"\(r.text)\", want \"\(item.text)\"")
        }
    }

    @Test func aKindSetToFalseAmongKindsSetToTrueLeavesOutJustThatKind() {
        // GUARD: holds before the change (every key is present).
        for item in mixWithout {
            var kindsOn = everythingOn
            kindsOn[item.kind] = false
            let r = Estimator.estimate(counts: mixCounts, speeds: mixSpeeds, kindsOn: kindsOn, modelWhole: true)
            #expect(close(Double(r.seconds), item.seconds), "\(item.kind) false, the rest true: got \(r.seconds) s, want \(item.seconds)")
            #expect(r.text == item.text, "\(item.kind) false, the rest true: got \"\(r.text)\", want \"\(item.text)\"")
        }
    }

    @Test func everyKindOfTheMixSetToFalseIsNothingToRead() {
        let allFalse = Dictionary(uniqueKeysWithValues: ["photo", "pdf", "doc", "audio", "video"].map { ($0, false) })
        let r = Estimator.estimate(counts: mixCounts, speeds: mixSpeeds, kindsOn: allFalse, modelWhole: true)
        #expect(r.text == "nothing to read", "all five false: got \(r.text)")
        #expect(close(Double(r.seconds), 0), "all five false: seconds \(r.seconds)")
    }

    @Test func aKindWithNoMeasuredSpeedAddsNothingEvenWhenItsKeyIsMissing() {
        // no speed for video: 55 + 150 + 60 + 120 = 385 s, 6.42 min
        let noVideo = ["photo": 0.25, "pdf": 1.5, "doc": 0.5, "audio": 3.0]
        let r = Estimator.estimate(counts: mixCounts, speeds: noVideo, kindsOn: ["photo": true], modelWhole: true)
        #expect(close(Double(r.seconds), 385), "no video speed: got \(r.seconds) s, want 385")
        #expect(r.text == "about 6 min", "no video speed: got \(r.text)")
        // only the photo speed: 55 s, under a minute
        let onlyPhoto = Estimator.estimate(counts: mixCounts, speeds: ["photo": 0.25], kindsOn: ["photo": true], modelWhole: true)
        #expect(close(Double(onlyPhoto.seconds), 55), "only a photo speed: got \(onlyPhoto.seconds) s, want 55")
        #expect(onlyPhoto.text == "under a minute", "only a photo speed: got \(onlyPhoto.text)")
    }

    @Test func theMixAtMeasuredLookingSpeedsIsTheHandSum() {
        // 220 x 0.3 = 66, 100 x 1.5 = 150, 120 x 0.2 = 24, 40 x 3.0 = 120, 20 x 12.5 = 250: 610 s, 10.17 min, about 10
        let speeds = ["photo": 0.3, "pdf": 1.5, "doc": 0.2, "audio": 3.0, "video": 12.5]
        let r = Estimator.estimate(counts: mixCounts, speeds: speeds, kindsOn: ["photo": true], modelWhole: true)
        #expect(close(Double(r.seconds), 610), "got \(r.seconds) s, want 610")
        #expect(r.text == "about 10 min", "got \(r.text)")
    }

    @Test func theModelNotWholeAndNoPhotoSpeedKeepTheirWordsWithADefaultKindsOn() {
        let download = Estimator.estimate(counts: mixCounts, speeds: mixSpeeds, kindsOn: ["photo": true], modelWhole: false)
        #expect(download.text == "after the model download", "model not whole: got \(download.text)")
        let measuring = Estimator.estimate(counts: mixCounts, speeds: ["pdf": 1.5, "doc": 0.5, "audio": 3.0, "video": 7.0], kindsOn: ["photo": true], modelWhole: true)
        #expect(measuring.text == "measuring speed", "no photo speed: got \(measuring.text)")
    }

    // The entry names `estimate`; `left` is the same rule for the time left (the menu's second line). Pinned here as a shape the entry did not fix:
    // a kind with no key counts in `left` as it does in `estimate`.
    @Test func leftCountsAKindWithNoKeyAsEstimateDoes() {
        let a = Estimator.left(remaining: mixCounts, speeds: mixSpeeds, kindsOn: ["photo": true])
        #expect(close(Double(a.seconds), 525), "kindsOn holds only photo: got \(a.seconds) s, want 525")
        #expect(a.text == "about 9 min", "kindsOn holds only photo: got \(a.text)")
        let b = Estimator.left(remaining: mixCounts, speeds: mixSpeeds, kindsOn: [:])
        #expect(close(Double(b.seconds), 525), "kindsOn is empty: got \(b.seconds) s, want 525")
        let c = Estimator.left(remaining: mixCounts, speeds: mixSpeeds, kindsOn: ["audio": false])
        #expect(close(Double(c.seconds), 405), "only audio is false: got \(c.seconds) s, want 405")
        #expect(c.text == "about 7 min", "only audio is false: got \(c.text)")
    }

    @Test func anOldCodeSpeedWithNoCodeCountAddsNothingToEstimate() {
        let withOld = Estimator.estimate(counts: ["photo": 1000], speeds: ["photo": 0.3, "code": 0.25], kindsOn: everythingOn, modelWhole: true)
        #expect(close(Double(withOld.seconds), 300), "photo and an old code speed: got \(withOld.seconds) s, want 300")
        #expect(withOld.text == "about 5 min", "photo and an old code speed: got \(withOld.text)")
        let kindsWithOldKey = Estimator.estimate(counts: ["photo": 1000], speeds: ["photo": 0.3, "code": 0.25], kindsOn: ["photo": true, "code": true], modelWhole: true)
        #expect(close(Double(kindsWithOldKey.seconds), 300), "old code key in kindsOn: got \(kindsWithOldKey.seconds) s, want 300")
    }

    @Test func anOldCodeSpeedWithNoCodeCountAddsNothingToLeft() {
        let a = Estimator.left(remaining: ["photo": 1000, "pdf": 200], speeds: ["photo": 0.3, "pdf": 1.5, "code": 0.25], kindsOn: everythingOn)
        #expect(close(Double(a.seconds), 600), "got \(a.seconds) s, want 600")
        #expect(a.text == "about 10 min", "got \(a.text)")
    }

    @Test func anOldCodeSpeedAloneIsStillMeasuringSpeedBecauseThePhotoSpeedIsMissing() {
        let r = Estimator.estimate(counts: ["photo": 500], speeds: ["code": 0.25], kindsOn: everythingOn, modelWhole: true)
        #expect(r.text == "measuring speed", "got \(r.text)")
    }

    @Test func anOldCodeSpeedChangesNeitherTheDownloadNorTheNothingToReadWords() {
        let download = Estimator.estimate(counts: ["photo": 500], speeds: ["photo": 0.3, "code": 0.25], kindsOn: everythingOn, modelWhole: false)
        #expect(download.text == "after the model download", "got \(download.text)")
        let nothing = Estimator.estimate(counts: [:], speeds: ["photo": 0.3, "code": 0.25], kindsOn: everythingOn, modelWhole: true)
        #expect(nothing.text == "nothing to read", "got \(nothing.text)")
        #expect(close(Double(nothing.seconds), 0), "seconds \(nothing.seconds)")
    }
}
