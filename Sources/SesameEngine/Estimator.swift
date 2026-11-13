import Foundation

/// The honest time estimate: counts times measured seconds per file, per kind.
/// A kind with no measured speed, or whose `kindsOn` entry is false, adds nothing; a kind with no entry counts, so a
/// default settings file that names only `photo` leaves no other kind out.
public enum Estimator {
    public struct Result: Equatable, Sendable {
        public let seconds: Double
        public let text: String
    }

    public static func estimate(counts: [String: Int], speeds: [String: Double],
                                kindsOn: [String: Bool], modelWhole: Bool) -> Result {
        if !modelWhole { return Result(seconds: 0, text: "after the model download") }
        return timed(counts, speeds, kindsOn)
    }

    public static func left(remaining: [String: Int], speeds: [String: Double],
                            kindsOn: [String: Bool]) -> Result {
        timed(remaining, speeds, kindsOn)
    }

    private static func timed(_ counts: [String: Int], _ speeds: [String: Double],
                              _ kindsOn: [String: Bool]) -> Result {
        guard speeds["photo"] != nil else { return Result(seconds: 0, text: "measuring speed") }
        var total = 0.0
        for (kind, speed) in speeds where kindsOn[kind] != false {
            total += Double(counts[kind] ?? 0) * speed
        }
        return Result(seconds: total, text: words(total))
    }

    private static func words(_ seconds: Double) -> String {
        if seconds <= 0 { return "nothing to read" }
        if seconds < 60 { return "under a minute" }
        if seconds < 3570 { return "about \(Int((seconds / 60 + 0.5).rounded(.down))) min" }
        let minutes = Int((seconds / 60 / 5 + 0.5).rounded(.down)) * 5
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "about \(h) h" : "about \(h) h \(m) min"
    }
}
