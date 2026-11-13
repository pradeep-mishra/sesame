/// One Retry per model download failure. A failure is recorded when it happens; `shouldRetry` answers true for the first
/// press while that failure still stands and the model is not whole, and uses it up, so a second press of the same
/// failure (a stale menu, the window's button and the menu's within two seconds) answers false and starts no second fetch.
struct RetryGuard {
    private var armed = false

    /// A failure now stands. Recording twice before a press is still one failure.
    mutating func recordFailure() {
        armed = true
    }

    mutating func shouldRetry(failureStands: Bool, isWhole: Bool) -> Bool {
        guard armed, failureStands, !isWhole else { return false }
        armed = false
        return true
    }
}
