import Foundation
import Testing

// plan-5-t3, tester step. The rig of MediaRigVideo.swift tested against its own independent witnesses (`ffprobe` and `ffmpeg`), with no product code:
// the video tests of this task (VideoReaderTests, HelperVideoTests, HelperVideoModelTests, HelperPauseLatencyTests) take their expected values from
// what the rig draws, so the rig has to be right before they can say anything. Needs `ffprobe` and `ffmpeg` (outside the sandbox).

@Suite("MediaRigVideoTests", .serialized)
struct MediaRigVideoTests {

    @Test func aClipHasTheDurationTheStreamsAndTheShotShadesTheTestsExpectAsFfprobeAndFfmpegSeeThem() throws {
        try mrWithDir { dir in
            let list = MediaRig.shots([12, 10, 10, 10, 10, 10, 10, 10])
            let path = dir.file("rig.mp4")
            try MediaRig.writeVideo(path, shots: list)
            let duration = try #require(MediaRig.probeSeconds(path), "ffprobe cannot read the clip the rig wrote")
            #expect(abs(duration - 82) < 0.6, "ffprobe reads a duration of \(duration), the rig wrote 82 s")
            let streams = try #require(MediaRig.probeStreams(path), "ffprobe cannot list the streams")
            #expect(streams.video == 1 && streams.audio == 0, "the rig's clip has \(streams.video) video and \(streams.audio) audio streams, expected 1 and 0")
            // 41 is the shot that started at 32 (index 3), 42 the shot that starts there (index 4), 22 the shot that starts there (index 2)
            for (second, index) in [(41.0, 3), (42.0, 4), (22.0, 2), (21.0, 1), (81.0, 7), (0.0, 0)] {
                let mean = try #require(MediaRig.ffmpegMean(path, at: second), "ffmpeg cannot decode a frame at \(second)")
                #expect(MediaRig.nearestShade(mean) == index, "ffmpeg's frame at \(second) s is nearest shade \(MediaRig.nearestShade(mean)), the rig drew shot \(index)")
            }
            // a pattern is a row of a Hadamard matrix: 32 cells lit, and two different rows differ in 32 cells
            #expect((0..<64).filter { MediaRig.isLit(row: list[3].row, cell: $0, flips: []) }.count == 32, "a shot should light 32 cells of 64")
            let distance = (0..<64).filter { MediaRig.isLit(row: list[3].row, cell: $0, flips: []) != MediaRig.isLit(row: list[4].row, cell: $0, flips: []) }.count
            #expect(distance == 32, "two consecutive shots differ in \(distance) cells, expected 32")
        }
    }

    @Test func aClipWithASoundtrackHasAnAudioStreamAndOneWithoutHasNone() throws {
        try mrWithDir { dir in
            let wav = dir.file("sound.wav")
            try MediaRig.writeWav(wav, rate: 44100, [.silence(5), .tone(5, db: -20, hz: 440)])
            let with = dir.file("with.mp4"), without = dir.file("without.mp4"), mov = dir.file("clip.mov"), m4v = dir.file("clip.m4v")
            try MediaRig.writeVideo(with, shots: MediaRig.shots([10]), soundtrack: wav)
            try MediaRig.writeVideo(without, shots: MediaRig.shots([10]))
            try MediaRig.writeVideo(mov, shots: MediaRig.shots([4]))
            try MediaRig.writeVideo(m4v, shots: MediaRig.shots([4]))
            let streams = try #require(MediaRig.probeStreams(with), "ffprobe cannot list the streams of the clip with sound")
            #expect(streams.video == 1 && streams.audio == 1, "the clip with a soundtrack has \(streams.video) video and \(streams.audio) audio streams, expected 1 and 1")
            #expect(MediaRig.probeStreams(without)?.audio == 0, "the clip without one has audio")
            #expect(abs((MediaRig.probeSeconds(with) ?? 0) - 10) < 0.6, "the clip with sound lasts \(MediaRig.probeSeconds(with) ?? 0) s, expected 10")
            for path in [mov, m4v] { #expect(MediaRig.probeSeconds(path) != nil, "ffprobe cannot read \((path as NSString).lastPathComponent)") }
        }
    }

    @Test func aCutCopyIsUnreadableToFfprobeBecauseTheIndexIsAtTheEndOfTheFile() throws {
        try mrWithDir { dir in
            let whole = dir.file("whole.mp4"), cut = dir.file("cut.mp4")
            try MediaRig.writeVideo(whole, shots: MediaRig.shots([6, 6, 6, 6]))
            try MediaRig.cutCopy(of: whole, to: cut, fraction: 0.4)
            #expect(MediaRig.probeSeconds(whole) != nil, "control: ffprobe reads the whole clip")
            #expect(MediaRig.probeSeconds(cut) == nil, "ffprobe still reads the cut copy: a cut mp4 would not be a damaged file")
        }
    }
}
