import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// A value that can be bound to a statement parameter.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// One result row. Columns are addressed by name.
public struct Row {
    let values: [String: SQLValue]

    public func int(_ column: String) -> Int64? {
        switch values[column] {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        default: return nil
        }
    }
    public func double(_ column: String) -> Double? {
        switch values[column] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    public func string(_ column: String) -> String? {
        if case .text(let v) = values[column] { return v }
        return nil
    }
    public func data(_ column: String) -> Data? {
        if case .blob(let v) = values[column] { return v }
        return nil
    }
    public func date(_ column: String) -> Date? {
        double(column).map(Date.init(timeIntervalSince1970:))
    }
    public func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, thread-safe wrapper around a single SQLite connection.
///
/// All access is serialized through a recursive lock so the connection can be
/// shared between actors. SQLite work here is short; long-running scans page
/// through results instead of holding the lock.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: msg)
        }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
    }

    deinit { sqlite3_close_v2(handle) }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Executes one or more statements without parameters.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let message = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw SQLiteError(code: rc, message: message)
        }
    }

    /// Runs a parameterized statement that returns no rows. Returns the change count.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLBindable] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try withStatement(sql, params) { stmt in
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
        }
        return Int(sqlite3_changes(handle))
    }

    /// Inserts and returns the new rowid.
    public func insert(_ sql: String, _ params: [SQLBindable] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try run(sql, params)
        return sqlite3_last_insert_rowid(handle)
    }

    public func query(_ sql: String, _ params: [SQLBindable] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var rows: [Row] = []
        try withStatement(sql, params) { stmt in
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw error(rc) }
                rows.append(readRow(stmt))
            }
        }
        return rows
    }

    public func queryOne(_ sql: String, _ params: [SQLBindable] = []) throws -> Row? {
        try query(sql, params).first
    }

    public func scalarInt(_ sql: String, _ params: [SQLBindable] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var result: Int64 = 0
        try withStatement(sql, params) { stmt in
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { result = sqlite3_column_int64(stmt, 0) }
            else if rc != SQLITE_DONE { throw error(rc) }
        }
        return result
    }

    private var savepointDepth = 0

    /// Runs `body` inside an immediate transaction; rolls back if it throws.
    ///
    /// Nested calls (a repository method that uses a transaction, called from another one) become
    /// savepoints: an inner failure rolls back only the inner work, and nothing is durable until
    /// the outermost transaction commits.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_get_autocommit(handle) != 0 else { return try savepoint(body) }
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func savepoint<T>(_ body: () throws -> T) throws -> T {
        savepointDepth += 1
        defer { savepointDepth -= 1 }
        let name = "sp_\(savepointDepth)"
        try execute("SAVEPOINT \(name)")
        do {
            let value = try body()
            try execute("RELEASE \(name)")
            return value
        } catch {
            // ROLLBACK TO undoes the savepoint's work but leaves it open; RELEASE closes it.
            try? execute("ROLLBACK TO \(name); RELEASE \(name)")
            throw error
        }
    }

    private func withStatement(_ sql: String, _ params: [SQLBindable], _ body: (OpaquePointer) throws -> Void) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        defer { sqlite3_finalize(stmt) }
        for (index, param) in params.enumerated() {
            let i = Int32(index + 1)
            let bindRC: Int32
            switch param.sqlValue {
            case .null: bindRC = sqlite3_bind_null(stmt, i)
            case .int(let v): bindRC = sqlite3_bind_int64(stmt, i, v)
            case .double(let v): bindRC = sqlite3_bind_double(stmt, i, v)
            case .text(let v): bindRC = sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                bindRC = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, i, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                }
            }
            guard bindRC == SQLITE_OK else { throw error(bindRC) }
        }
        try body(stmt)
    }

    private func readRow(_ stmt: OpaquePointer) -> Row {
        var values: [String: SQLValue] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, i))
            case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(stmt, i))
                if let ptr = sqlite3_column_blob(stmt, i), count > 0 {
                    values[name] = .blob(Data(bytes: ptr, count: count))
                } else {
                    values[name] = .blob(Data())
                }
            default: values[name] = .null
            }
        }
        return Row(values: values)
    }

    public func integrityCheck() throws -> Bool {
        try queryOne("PRAGMA quick_check")?.string("quick_check") == "ok"
    }
}
