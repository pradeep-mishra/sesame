import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t24, tester step. Written from the t24 entry (Tests: paragraph), the spec (a damaged or password-protected file
// "is skipped, listed in Settings as could not read, and never stops the indexing of other files"), plan-2 R2 (a photo the
// process cannot open ends `needs_permission`) and design section 1; no product source read.
//
// `CouldNotReadList` is the pure value behind the "could not read" list of Settings (mockup F3, verify K20): an empty-state
// text when there is nothing to list, and one row per file, read as "<name>, <reason>". It is built from what
// `IndexReader.couldNotRead()` returns (sealed in IndexReaderCountsTests), so each test here goes the whole way: rows
// written through `IndexStore` in a throwaway HOME, read through `IndexReader`, shown through `CouldNotReadList`.
//
// API SHAPES these tests pin (new; the entry names `CouldNotReadList`, the empty text and the row form, and fixes no
// signatures; if one is wrong, ask for a test change rather than guessing):
//   `CouldNotReadList(files: reader.couldNotRead())`   built from exactly what the reader returns (the row type is not
//                                                      named here; the initialiser takes it, or is generic over it)
//   `var emptyText: String?`   nil when there is at least one file; else "Nothing here. Files Sesame could not read are
//                              listed here."
//   `var rows: [String]`       one text per file in the order given (the reader sorts by path), each "<name>, <reason>"
//                              where <name> is the file name and <reason> the reason ("damaged", "needs permission", ...).
//                              The row text is also what a screen reader says, so it holds no path.
//
// Suite placement: HOME is process-wide, so the suite is nested inside `ModelDownloadTests` like the other HOME-setting
// suites; `swift test --filter ModelDownloadTests` also runs it.

private let cnrEmptyText = "Nothing here. Files Sesame could not read are listed here."

private func cnrAddFile(_ store: IndexStore, _ path: String, kind: String, status: String, inode: Int64) throws {
    _ = try store.addFile(path: path, kind: kind, size: 100, mtimeNs: 1_700_000_000_000_000_000, inode: inode,
                          device: 1, status: status)
}

/// A photo row that ended `could_not_read` with `reason`, made the way the helper makes one (read from the queue as
/// `pending`, then marked with `IndexStore.markCouldNotRead(_:reason:)`).
private func cnrAddCouldNotRead(_ store: IndexStore, _ path: String, reason: String, inode: Int64) throws {
    try cnrAddFile(store, path, kind: "photo", status: "pending", inode: inode)
    let queue = try store.pendingPhotos(limit: 50)
    let row = try #require(queue.first { $0.path == path }, "setup: pendingPhotos does not list \(path)")
    _ = try store.markCouldNotRead(row, reason: reason)
}

extension ModelDownloadTests {
    @Suite("CouldNotReadListTests", .serialized)
    struct CouldNotReadListTests {

        @MainActor
        @Test func withNoIndexFileTheListShowsTheEmptyText() async throws {
            try await spWithHome { _ in
                let reader = IndexReader()
                defer { reader.close() }
                let list = CouldNotReadList(files: reader.couldNotRead())
                #expect(list.emptyText == cnrEmptyText, "empty text is \(String(describing: list.emptyText))")
                #expect(list.rows.isEmpty, "rows: \(list.rows)")
            }
        }

        @MainActor
        @Test func anIndexWhereEveryFileWasReadShowsTheEmptyTextToo() async throws {
            try await spWithHome { _ in
                let store = try IndexStore()
                defer { store.close() }
                try cnrAddFile(store, "/photos/done.jpg", kind: "photo", status: "done", inode: 1)
                try cnrAddFile(store, "/photos/waiting.jpg", kind: "photo", status: "pending", inode: 2)
                try cnrAddFile(store, "/docs/long.pdf", kind: "pdf", status: "partial", inode: 3)
                let reader = IndexReader()
                defer { reader.close() }

                let list = CouldNotReadList(files: reader.couldNotRead())

                #expect(list.emptyText == cnrEmptyText, "empty text is \(String(describing: list.emptyText))")
                #expect(list.rows.isEmpty, "a done, pending or partial file was listed: \(list.rows)")
            }
        }

        @MainActor
        @Test func eachUnreadableFileIsOneRowNameCommaReasonAndTheEmptyTextIsGone() async throws {
            try await spWithHome { _ in
                let store = try IndexStore()
                defer { store.close() }
                try cnrAddCouldNotRead(store, "/photos/trip/broken.jpg", reason: "damaged", inode: 1)
                try cnrAddCouldNotRead(store, "/photos/huge.jpg", reason: "needed too much memory", inode: 2)
                try cnrAddFile(store, "/photos/locked.jpg", kind: "photo", status: "needs_permission", inode: 3)
                try cnrAddFile(store, "/docs/private.pdf", kind: "pdf", status: "needs_permission", inode: 4)
                try cnrAddFile(store, "/photos/fine.jpg", kind: "photo", status: "done", inode: 5)
                let reader = IndexReader()
                defer { reader.close() }

                let list = CouldNotReadList(files: reader.couldNotRead())

                // by path: /docs/private.pdf, /photos/huge.jpg, /photos/locked.jpg, /photos/trip/broken.jpg
                #expect(list.rows == ["private.pdf, needs permission",
                                      "huge.jpg, needed too much memory",
                                      "locked.jpg, needs permission",
                                      "broken.jpg, damaged"],
                        "rows: \(list.rows)")
                #expect(list.emptyText == nil, "the empty text is shown beside \(list.rows.count) rows: \(String(describing: list.emptyText))")
            }
        }

        @MainActor
        @Test func twoFilesWithTheSameNameInDifferentFoldersAreTwoRowsInPathOrder() async throws {
            try await spWithHome { _ in
                let store = try IndexStore()
                defer { store.close() }
                try cnrAddCouldNotRead(store, "/b-folder/scan.jpg", reason: "damaged", inode: 1)
                try cnrAddFile(store, "/a-folder/scan.jpg", kind: "photo", status: "needs_permission", inode: 2)
                let reader = IndexReader()
                defer { reader.close() }

                let list = CouldNotReadList(files: reader.couldNotRead())

                #expect(list.rows == ["scan.jpg, needs permission", "scan.jpg, damaged"], "rows: \(list.rows)")
            }
        }

        @MainActor
        @Test func aRowHoldsTheNameAndTheReasonButNoFolderPath() async throws {
            try await spWithHome { _ in
                let store = try IndexStore()
                defer { store.close() }
                try cnrAddFile(store, "/secret-client/contracts/lease.pdf", kind: "pdf", status: "needs_permission", inode: 1)
                let reader = IndexReader()
                defer { reader.close() }

                let list = CouldNotReadList(files: reader.couldNotRead())

                #expect(list.rows == ["lease.pdf, needs permission"], "rows: \(list.rows)")
                #expect(list.rows.allSatisfy { !$0.contains("/") }, "a row holds a path: \(list.rows)")
            }
        }

        @MainActor
        @Test func theListFollowsTheIndexWhenTheHelperRetriesALockedFile() async throws {
            try await spWithHome { _ in
                let store = try IndexStore()
                defer { store.close() }
                try cnrAddFile(store, "/photos/locked.jpg", kind: "photo", status: "needs_permission", inode: 1)
                let reader = IndexReader()
                defer { reader.close() }
                #expect(CouldNotReadList(files: reader.couldNotRead()).rows == ["locked.jpg, needs permission"])

                // the helper's retry (plan-2-t2) turns the row back to pending: it is no longer "could not read"
                _ = try store.retryNeedsPermission()
                let after = CouldNotReadList(files: reader.couldNotRead())
                #expect(after.rows.isEmpty, "rows after the retry: \(after.rows)")
                #expect(after.emptyText == cnrEmptyText, "empty text after the retry: \(String(describing: after.emptyText))")
            }
        }
    }
}
