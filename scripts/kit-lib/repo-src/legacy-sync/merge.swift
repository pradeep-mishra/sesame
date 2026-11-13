import Foundation

/// Combines records that were not updated for a long time with the fresh ones from the other store.
func mergeStaleRecords(stale: [String: String], fresh: [String: String]) -> [String: String] {
    stale.merging(fresh) { _, newer in newer }
}
