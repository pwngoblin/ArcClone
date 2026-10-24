import Foundation
import SQLite3

/// Reads another browser's SQLite database without touching it: the file (and its write-ahead
/// log) is copied into a private temporary folder, and the copy is opened with
/// `SQLITE_OPEN_READONLY`. A running browser's locks can't block the import, and nothing is ever
/// written to the original. Only fixed queries written here run; nothing from the database or the
/// user is ever put into SQL. (SQLite's C interface hands back C strings, which are copied into
/// Swift strings immediately; that's the only pointer use here.)
struct SQLiteReader {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static let maxDatabaseBytes: Int64 = 1_000_000_000

    /// Runs `query` on a private read-only copy of `database`, calling `row` for each result row.
    static func read(_ database: URL, query: String, row: (Row) -> Void) throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("arcclone-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }

        let size = (try? database.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= maxDatabaseBytes else { throw Failure(reason: "The database is too large to import.") }
        let copy = workspace.appendingPathComponent("db.sqlite")
        try FileManager.default.copyItem(at: database, to: copy)
        let wal = URL(fileURLWithPath: database.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            try? FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw Failure(reason: "The database couldn't be opened.")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(reason: "The database has an unexpected format. Quit the browser and try again.")
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw Failure(reason: "The database couldn't be read. Quit the browser and try again.") }
            row(Row(statement: statement))
        }
    }

    /// One result row; columns are read by position.
    struct Row {
        fileprivate let statement: OpaquePointer

        func string(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    }
}
