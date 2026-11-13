import Foundation

var saved: [String: (body: Data, storedAt: Date)] = [:]

/// Returns the stored copy of a response while it is still fresh instead of asking the server again.
func cachedResponse(for url: String, maxAge: TimeInterval) -> Data? {
    guard let entry = saved[url] else { return nil }
    return Date().timeIntervalSince(entry.storedAt) < maxAge ? entry.body : nil
}
