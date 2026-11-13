import Foundation

/// The numbers that decide what `Search` lists, in one place.
public enum RankingWeights {
    /// A row passes when its dot stands at this many standard deviations above the mean of its modality.
    public static let gate = 2.0
    /// A description (2 or more words) whose best image dot is below this shows no image rows.
    /// Basis: 53 real-model queries on the 40 golden photos with Q8_0: the golden minimum was 0.7166 and the
    /// nonsense maximum 0.6778. The margins are thin: re-measure on a bigger realistic library, with documents,
    /// and for any other quantization.
    public static let imageFloor = 0.69
    /// The text gate for a description (2 or more words) when the library holds more than `smallLibraryCount` text passages
    /// (up to that, z cannot discriminate and `gate` stays). z is taken against the noise of the text rows' dots
    /// (`trimmedNoise`), and a text row passes when
    ///  - its z reaches `textGateZ(rows:)` = `max(textGate, textGateBase + textGateSlope * sqrt(2 ln n))` for n text passages
    ///    (the best z of pure noise grows with n like sqrt(2 ln n), so a fixed z lets a nonsense description through in a big
    ///    library), or
    ///  - at least `textTopicRows` text rows reach `textTopicGateZ(rows:)` = `max(textTopicFloor, sqrt(2 ln n) - textTopicOffset)`:
    ///    a topic of the library (a lease among a thousand passages, a book among five thousand, one or two topics of 2 to 40
    ///    percent of the rows) is many rows high together, which noise is not. A topic at 4 SD cannot clear the first gate
    ///    without letting nonsense through, and clears this one.
    /// The noise is not measured on all rows, because the rows on the query's own topic would widen the spread and hide
    /// themselves: `trimmedNoise` measures the lowest `textNoiseKeep` of the rows.
    /// How the constants were measured (random Gaussian dots, which random unit vectors in 768 dimensions give; 1,500 to 2,000
    /// trials per cell, 300 at 20,000):
    ///  - `textGate` 3.2: the real-model queries of GroupCTests on the whole-folder index (40 golden photos, 20 PDFs, 6
    ///    documents; 63 text rows). It is the floor below the formula (the formula is above it at every size).
    ///  - `textNoiseKeep` 0.5 gave the least noisy estimate of the lowest 30, 40 and 50 percent. The 99th percentile of the best
    ///    z of pure noise under it, for n = 63, 200, 1000, 5000, 20000, was 4.35, 4.25, 4.38, 4.54, 4.87 (sqrt(2 ln n) = 2.88,
    ///    3.26, 3.72, 4.13, 4.45; the lowest 30 percent gave 5.91, 4.78, 4.46, 4.67, 4.86 and the lowest 40 percent 4.91, 4.37,
    ///    4.35, 4.62, 4.81). `textGateBase` 3.4 and `textGateSlope` 0.33 are a line through these: 4.35, 4.47, 4.63, 4.76, 4.87.
    ///  - `textTopicRows` 3, `textTopicFloor` 3.0, `textTopicOffset` 0.25: with them noise showed a text row in 2.6, 3.9, 1.1,
    ///    0.9 and 1.0 percent of queries at n = 63, 200, 1000, 5000, 20000; a topic of 2, 5, 10, 15, 25 and 40 percent at 6 SD,
    ///    two topics of 8 percent, and 12 percent at 4 SD were shown in at least 97.8 percent of trials at n = 200, 1000 and
    ///    5000, and a lone row at 6 SD in at least 95 percent at 63 rows and in every trial at 1,000 and 5,000.
    /// The margins are thin: re-measure on a bigger realistic library and for any other quantization.
    public static let textGate = 3.2
    public static let textGateBase = 3.4
    public static let textGateSlope = 0.33
    public static let textNoiseKeep = 0.5
    public static let textTopicRows = 3
    public static let textTopicFloor = 3.0
    public static let textTopicOffset = 0.25
    /// A row this many SDs above the noise is counted as topic when `trimmedNoise` works out which noise quantile its cut is.
    static let topicZ = 3.5

    /// The z a single text row must reach, when the library holds `textRows` text passages.
    public static func textGateZ(rows textRows: Int) -> Double {
        guard textRows > 1 else { return textGate }
        return max(textGate, textGateBase + textGateSlope * (2 * log(Double(textRows))).squareRoot())
    }

    /// The z at which `textTopicRows` text rows together are a topic, when the library holds `textRows` text passages.
    public static func textTopicGateZ(rows textRows: Int) -> Double {
        guard textRows > 1 else { return textTopicFloor }
        return max(textTopicFloor, (2 * log(Double(textRows))).squareRoot() - textTopicOffset)
    }

    /// The audio modality uses the text gate and topic rule with a noise estimate that is then refined (`trimmedNoise` with
    /// `refinedFraction`): once the share of the rows on a topic is known, the lowest `audioNoiseFraction` of the other rows are
    /// used instead of the lowest half, which is a much steadier estimate at 63 rows (a topic of 3 rows at 4 SD among 63 was shown
    /// in 89 percent of trials with the text estimate, in 99 percent with this one; nonsense showed an audio row in 2.8 percent of
    /// trials at 63 rows with the text estimate, 0.9 percent with this one). `audioTopicZ` is the z (against the first estimate)
    /// from which a row counts as topic in that share; with the text value 3.5 a topic of 25 percent at 4 SD hid itself at 1,000 rows.
    /// Measured on random Gaussian dots as for the text constants, 20,000 trials of nonsense at 63 rows, 4,000 at 1,000, 1,000 at 5,000,
    /// and 3,000, 400 and 150 for the topic cells: the plan 4 gates and topic rule kept, `audioNoiseFraction` 0.8 and `audioTopicZ` 3.0
    /// against 0.7 and 0.9, 2.5, 3.5 (0.7 and 3.5 hid a 4 SD topic of 25 percent at 1,000 rows; 0.9 lost 15 percent of 4 SD topics at 63 rows).
    public static let audioNoiseFraction = 0.8
    public static let audioTopicZ = 3.0
    /// Owner's decision (plan-5-t6): the audio topic rule needs 6 rows, the text rule stays at `textTopicRows` (3). Real audio rows
    /// are correlated, so a nonsense description lifts a loose cluster: on the golden index "yepnoh vlorbx drazzit" put 5 audio
    /// rows at z 3.10 to 4.17 and listed 4 recordings. Do not lower it to 3 without re-running GroupDTests' nonsense strings.
    public static let audioTopicRows = 6

    /// The mean and SD of the noise in `dots`, from the lowest `textNoiseKeep` of them only. Those rows are noise cut at its
    /// quantile `keep / (1 - topic share)`, which is taken from the rows far above the noise (found in a few passes), and the
    /// mean and SD of a normal distribution cut there are put back. With `refinedFraction` the same is done again, a few passes
    /// more, with the lowest `refinedFraction` of the rows that are not topic in place of the lowest half.
    static func trimmedNoise(of dots: [Double], topicZ: Double = RankingWeights.topicZ, refinedFraction: Double? = nil) -> (mean: Double, deviation: Double) {
        let sorted = dots.sorted()
        let count = Double(sorted.count)
        func fit(keeping kept: Int, of share: Double, topic: Double, ceiling: Double) -> (mean: Double, deviation: Double) {
            let keptMean = sorted[0..<kept].reduce(0, +) / Double(kept)
            let keptVariance = sorted[0..<kept].reduce(0) { $0 + ($1 - keptMean) * ($1 - keptMean) } / Double(kept)
            let quantile = min(ceiling, share / (1 - topic))
            let cut = normalQuantile(quantile)
            let pull = normalDensity(cut) / quantile
            let cutVariance = 1 - cut * pull - pull * pull
            let deviation = (keptVariance / cutVariance).squareRoot()
            return (keptMean + pull * deviation, deviation)
        }
        func share(of noise: (mean: Double, deviation: Double)) -> Double {
            let high = sorted.filter { ($0 - noise.mean) / noise.deviation > topicZ }.count
            return min(1 - textNoiseKeep / 0.95, Double(high) / count)
        }
        let kept = min(sorted.count, max(3, Int((textNoiseKeep * count).rounded(.up))))
        var topic = 0.0
        var noise = (mean: 0.0, deviation: 0.0)
        for _ in 0..<4 {
            noise = fit(keeping: kept, of: textNoiseKeep, topic: topic, ceiling: 0.95)
            topic = share(of: noise)
        }
        if let refinedFraction {
            for _ in 0..<3 {
                let rows = min(sorted.count, max(3, Int((refinedFraction * (1 - topic) * count).rounded(.up))))
                noise = fit(keeping: rows, of: Double(rows) / count, topic: topic, ceiling: 0.97)
                topic = share(of: noise)
            }
        }
        return noise
    }

    private static func normalDensity(_ x: Double) -> Double {
        exp(-x * x / 2) / (2 * Double.pi).squareRoot()
    }

    /// The x at which the standard normal distribution reaches `p`, by bisection.
    private static func normalQuantile(_ p: Double) -> Double {
        var low = -8.0
        var high = 8.0
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if 0.5 * erfc(-middle / 2.0.squareRoot()) < p { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// With this many image passages or fewer the z gate cannot be trusted (the largest z of n values is (n - 1) / sqrt(n),
    /// under 2 until n = 6; a few real matches among 8 to 30 flat rows also leave z under 2), so a description keeps the
    /// image rows at or above the floor. At 31 and above the z gate decides.
    public static let smallLibraryCount = 30
    /// How many closest rows a lone token with no exact hit shows, and the cap on image rows in a small library.
    public static let relaxedCount = 5
    /// Typed text is cut at this many characters.
    public static let clamp = 500
}
