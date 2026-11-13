import Foundation

/// The pause rule for whole-system CPU apart from Sesame, fed one sample a second (design section 8).
/// Pause: above 70 percent for 10 samples in a row. Resume, once paused: below 50 percent for 30 samples in a row.
/// Samples from 50 to 70 hold the state. It knows nothing of the pause set, files or the clock.
struct CPURule {
    enum Event: Equatable { case pause, resume }

    static let pauseAbove = 70.0
    static let pauseSamples = 10
    static let resumeBelow = 50.0
    static let resumeSamples = 30

    private var paused = false
    private var run = 0

    /// One sample, `percent` in 0...100. The timestamp is not used: samples are counted, one per second.
    mutating func feed(_ percent: Double, at time: Date) -> Event? {
        if paused {
            guard percent < Self.resumeBelow else { run = 0; return nil }
            run += 1
            guard run >= Self.resumeSamples else { return nil }
            paused = false
            run = 0
            return .resume
        }
        guard percent > Self.pauseAbove else { run = 0; return nil }
        run += 1
        guard run >= Self.pauseSamples else { return nil }
        paused = true
        run = 0
        return .pause
    }
}
