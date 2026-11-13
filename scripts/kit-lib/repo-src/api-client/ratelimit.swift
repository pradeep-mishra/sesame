import Foundation

/// Sleeps until the rate limit window resets when the server says too many requests were made.
func waitForRateLimit(resetAt: Date) {
    let pause = resetAt.timeIntervalSinceNow
    if pause > 0 { Thread.sleep(forTimeInterval: pause) }
}
