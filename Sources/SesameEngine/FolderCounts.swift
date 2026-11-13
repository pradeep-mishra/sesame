import Foundation

/// How many files of each kind lie under the folders a person picked, from names, sizes and extensions alone.
/// Counting opens no file, reads no `.gitignore` and runs no git; `Rules.admit` is the one rule, through `Walker`.
public struct FolderCounts {
    /// Picked folder path, as passed, to kind to the files under it. A kind with no file is absent.
    public let perFolder: [String: [String: Int]]
    /// Kind to files, each file once (by path) over all the folders.
    public let summary: [String: Int]
    /// The unique total: the sum of `summary`.
    public let total: Int
    /// Folders that exist but could not be listed, each once, as the walk spelled them.
    public let unreadable: [String]

    /// Synchronous and never throws: a folder it cannot list is reported in `unreadable` and the rest is counted.
    public static func count(folders: [String]) -> FolderCounts {
        var perFolder: [String: [String: Int]] = [:]
        var seen = Set<String>()
        var summary: [String: Int] = [:]
        var unreadable: [String] = []
        var unreadableSeen = Set<String>()
        for folder in folders where perFolder[folder] == nil {
            let result = Walker.scan(root: folder, mode: .count)
            var kinds: [String: Int] = [:]
            for file in result.files {
                kinds[file.kind, default: 0] += 1
                if seen.insert(file.path).inserted { summary[file.kind, default: 0] += 1 }
            }
            perFolder[folder] = kinds
            for path in result.unreadable where unreadableSeen.insert(path).inserted { unreadable.append(path) }
        }
        return FolderCounts(perFolder: perFolder, summary: summary, total: seen.count, unreadable: unreadable)
    }
}
