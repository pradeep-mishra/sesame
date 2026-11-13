import Foundation
import SQLite3

/// Why an index call failed.
public enum IndexError: Error, Equatable {
    /// SQLite said no: the call, SQLite's message, its result code.
    case sqlite(String, String, Int32)
    /// Another `IndexStore` holds the file: there is one writer.
    case alreadyOpen
    /// A vector is not 768 numbers.
    case badVector(Int)
    /// The store was closed.
    case closed
}

/// The shape of `index.sqlite` (design section 1). No column for a query, an open, a count or a history:
/// nothing about searches or opens is ever stored.
enum Schema {
    static let version = "1"
    static let indexFileName = "index.sqlite"
    /// Side file for the one-writer exclusion; SQLite holds the lock, so a dead writer frees it.
    static let lockFileName = "index.lock"
    static let vectorLength = 768
    static let tokenizer = "porter unicode61 remove_diacritics 2"

    /// Both names are read from HOME at each call, as `SesameFolder.url` is.
    static var indexPath: String { SesameFolder.url.appendingPathComponent(indexFileName).path }
    static var lockPath: String { SesameFolder.url.appendingPathComponent(lockFileName).path }

    static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime_ns INTEGER NOT NULL,
            inode INTEGER NOT NULL,
            device INTEGER NOT NULL,
            status TEXT NOT NULL,
            reason TEXT,
            read_to INTEGER,
            tries INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS passages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            source TEXT NOT NULL,
            start REAL NOT NULL,
            "end" REAL NOT NULL,
            modality TEXT NOT NULL,
            vec BLOB
        )
        """,
        "CREATE INDEX IF NOT EXISTS passages_file ON passages(file_id)",
        "CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(name, body, tokenize = '\(tokenizer)')",
        "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    ]
}

/// SQLite copies the bound bytes (the C macro SQLITE_TRANSIENT).
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
