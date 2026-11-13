/// Text recognition failed twice in a row. It holds no path, file name or text from the error underneath: the helper
/// stops its run on it and a fresh process tries the file again.
public struct RecognitionFailed: Error, CustomStringConvertible {
    public init() {}

    public var description: String { "text recognition failed" }
}

/// One retry for Vision: a picture with no text is an empty result, never a failure, so only a throw is repeated.
public enum RecognitionRetry {
    /// Calls `attempt` once and returns its result. If it throws, calls it exactly once more; if that throws too, throws
    /// `RecognitionFailed`.
    public static func run(_ attempt: () throws -> String) throws -> String {
        if let first = try? attempt() { return first }
        do { return try attempt() } catch { throw RecognitionFailed() }
    }
}

/// What the helper does when Vision fails on a file (after `RecognitionRetry`'s one retry), kept for one helper run.
/// Once any recognition has worked in the run, Vision itself works and only that file is the problem: skip it. Until
/// then Vision may be down for the whole run: stop. Either way the failed attempt stays counted on the file (the store's
/// `tries`), and a file Vision failed on in `giveUpAfterFailedRuns` runs is given up as `could_not_read`, so a failing
/// file never blocks the older files for good.
public struct RecognitionPolicy {
    public enum Verdict: Equatable {
        case skipFile
        case stopRun
    }

    public static let giveUpAfterFailedRuns = 2

    private var succeeded = false

    public init() {}

    /// A recognition (a photo's text or a scan page's, empty text included) worked.
    public mutating func recordSuccess() {
        succeeded = true
    }

    /// A recognition failed. Changes nothing: only a success changes the next verdict.
    public mutating func recordFailure() -> Verdict {
        succeeded ? .skipFile : .stopRun
    }
}
