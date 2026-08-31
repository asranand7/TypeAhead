import Foundation
import SQLite3

/// A small typed wrapper over sqlite3.
///
/// Deliberately thin: the store needs prepared statements, bound parameters and
/// transactions, and nothing else. Pulling in a full ORM for six tables would be
/// more code than it saves, and the export format is "the database file itself",
/// so the schema needs to stay something a person can read with `sqlite3`.
public final class Database {
    public enum Error: Swift.Error, CustomStringConvertible {
        case open(String)
        case prepare(String, sql: String)
        case step(String, sql: String)

        public var description: String {
            switch self {
            case .open(let message): return "sqlite open failed: \(message)"
            case .prepare(let message, let sql): return "sqlite prepare failed: \(message)\n\(sql)"
            case .step(let message, let sql): return "sqlite step failed: \(message)\n\(sql)"
            }
        }
    }

    /// SQLITE_TRANSIENT — tells sqlite to copy bound strings rather than hold a
    /// pointer to memory Swift is about to reclaim.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.typeahead.database")

    public let path: String

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw Error.open(message)
        }
        self.handle = handle

        // WAL keeps reads (prediction, on the keystroke path) from blocking on
        // writes (learning). NORMAL synchronous is the right trade for a cache of
        // typing statistics: a crash could lose the last few words, not the file.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: - Values

    public enum Value {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
    }

    public struct Row {
        private let columns: [String: Value]

        init(columns: [String: Value]) {
            self.columns = columns
        }

        public func int(_ name: String) -> Int64? {
            if case .integer(let value)? = columns[name] { return value }
            return nil
        }

        public func double(_ name: String) -> Double? {
            switch columns[name] {
            case .real(let value): return value
            case .integer(let value): return Double(value)
            default: return nil
            }
        }

        public func string(_ name: String) -> String? {
            if case .text(let value)? = columns[name] { return value }
            return nil
        }
    }

    // MARK: - Execution

    public func execute(_ sql: String, _ parameters: [Value] = []) throws {
        try queue.sync { try runLocked(sql, parameters) { _ in } }
    }

    @discardableResult
    public func query(_ sql: String, _ parameters: [Value] = []) throws -> [Row] {
        try queue.sync {
            var rows: [Row] = []
            try runLocked(sql, parameters) { statement in
                rows.append(Database.readRow(statement))
            }
            return rows
        }
    }

    /// Runs `body` inside a transaction, rolling back on any thrown error.
    /// Import and merge depend on this: a half-merged memory store would be worse
    /// than a failed import.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try queue.sync {
            try runLocked("BEGIN IMMEDIATE", []) { _ in }
            do {
                let result = try body()
                try runLocked("COMMIT", []) { _ in }
                return result
            } catch {
                try? runLocked("ROLLBACK", []) { _ in }
                throw error
            }
        }
    }

    /// The transaction body runs while the queue is already held, so it needs an
    /// unsynchronised path. Only call from inside `transaction`.
    public func executeInTransaction(_ sql: String, _ parameters: [Value] = []) throws {
        try runLocked(sql, parameters) { _ in }
    }

    public func queryInTransaction(_ sql: String, _ parameters: [Value] = []) throws -> [Row] {
        var rows: [Row] = []
        try runLocked(sql, parameters) { statement in
            rows.append(Database.readRow(statement))
        }
        return rows
    }

    private func runLocked(_ sql: String,
                           _ parameters: [Value],
                           _ onRow: (OpaquePointer) -> Void) throws {
        guard let handle else { throw Error.open("database is closed") }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Error.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let value):
                sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                sqlite3_bind_double(statement, index, value)
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, Database.transient)
            }
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let statement { onRow(statement) }
            case SQLITE_DONE:
                return
            default:
                throw Error.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
            }
        }
    }

    private static func readRow(_ statement: OpaquePointer) -> Row {
        var columns: [String: Value] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                columns[name] = .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT:
                columns[name] = .real(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                if let text = sqlite3_column_text(statement, index) {
                    columns[name] = .text(String(cString: text))
                }
            default:
                columns[name] = .null
            }
        }
        return Row(columns: columns)
    }

    /// Copies the live database to `destination` atomically. This is the export:
    /// one statement, consistent even while the app keeps writing.
    public func vacuum(into destination: String) throws {
        try? FileManager.default.removeItem(atPath: destination)
        try execute("VACUUM INTO ?", [.text(destination)])
    }

    public var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?.int("user_version")).flatMap { $0 }.map(Int.init) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }
}
