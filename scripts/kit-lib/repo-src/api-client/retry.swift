import Foundation

/// Calls the operation again after a growing pause until it works or the attempts run out.
func retryWithBackoff(attempts: Int, baseDelay: Double, operation: () throws -> Data) throws -> Data {
    var delay = baseDelay
    var lastError: Error = ClientError.exhausted
    for _ in 0..<attempts {
        do { return try operation() } catch { lastError = error }
        Thread.sleep(forTimeInterval: delay)
        delay *= 2
    }
    throw lastError
}
