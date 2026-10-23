// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import SQLite3

public enum DatabaseError: Error, Equatable, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String)
    case migration(version: Int, String)
    case newerSchema(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .open(let m): return "open: \(m)"
        case .prepare(let m, let sql): return "prepare: \(m) [\(sql)]"
        case .step(let m): return "step: \(m)"
        case .migration(let v, let m): return "migration \(v): \(m)"
        case .newerSchema(let f, let s): return "database schema \(f) is newer than supported \(s)"
        }
    }
}

public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct SQLRow {
    let values: [String: SQLValue]
    public subscript(_ column: String) -> SQLValue { values[column] ?? .null }
    public func string(_ c: String) -> String? { if case .text(let s) = self[c] { return s }; return nil }
    public func int(_ c: String) -> Int? {
        switch self[c] {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    public func double(_ c: String) -> Double? {
        switch self[c] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public func data(_ c: String) -> Data? {
        switch self[c] {
        case .blob(let d): return d
        case .text(let s): return Data(s.utf8)
        default: return nil
        }
    }
}

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, serialised wrapper around the system SQLite library.
/// All access goes through one serial queue, so it is safe to share.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "wavelast.sqlite")
    public let path: String

    /// Opens (creating if needed) a database file. Pass ":memory:" for tests.
    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DatabaseError.open(msg)
        }
        handle = db
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" { try execute("PRAGMA journal_mode = WAL") }
    }

    deinit { sqlite3_close(handle) }

    public func execute(_ sql: String, _ args: [SQLBindable] = []) throws {
        _ = try queue.sync { try unsafeRun(sql, args, collect: false) }
    }

    public func query(_ sql: String, _ args: [SQLBindable] = []) throws -> [SQLRow] {
        try queue.sync { try unsafeRun(sql, args, collect: true) }
    }

    /// Runs `body` inside a transaction; rolls back if it throws.
    public func transaction<T>(_ body: (TransactionContext) throws -> T) throws -> T {
        try queue.sync {
            try unsafeRun("BEGIN IMMEDIATE", [], collect: false)
            do {
                let result = try body(TransactionContext(db: self))
                try unsafeRun("COMMIT", [], collect: false)
                return result
            } catch {
                _ = try? unsafeRun("ROLLBACK", [], collect: false)
                throw error
            }
        }
    }

    public struct TransactionContext {
        let db: SQLiteDatabase
        public func execute(_ sql: String, _ args: [SQLBindable] = []) throws { try db.unsafeRun(sql, args, collect: false) }
        public func query(_ sql: String, _ args: [SQLBindable] = []) throws -> [SQLRow] { try db.unsafeRun(sql, args, collect: true) }
    }

    public var userVersion: Int {
        get throws { try query("PRAGMA user_version").first?.int("user_version") ?? 0 }
    }

    @discardableResult
    fileprivate func unsafeRun(_ sql: String, _ args: [SQLBindable], collect: Bool) throws -> [SQLRow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a.sqlValue {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_PTR)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT_PTR) }
            }
        }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DatabaseError.step(String(cString: sqlite3_errmsg(handle))) }
            guard collect else { continue }
            var values: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    values[name] = .blob(n == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, c), count: n))
                default: values[name] = .null
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }
}

/// Ordered schema migrations tracked with `PRAGMA user_version`.
/// Never edit a shipped migration; append a new one.
public struct Migrator {
    public struct Migration {
        public let version: Int
        public let sql: [String]
        public init(_ version: Int, _ sql: [String]) {
            self.version = version
            self.sql = sql
        }
    }

    public let migrations: [Migration]

    public init(_ migrations: [Migration]) {
        self.migrations = migrations.sorted { $0.version < $1.version }
    }

    public var latestVersion: Int { migrations.last?.version ?? 0 }

    /// Applies pending migrations, each in its own transaction.
    /// - Parameter target: stop at this version (tests use it to build old schemas).
    public func migrate(_ db: SQLiteDatabase, upTo target: Int? = nil) throws {
        let current = try db.userVersion
        let goal = target ?? latestVersion
        guard current <= latestVersion else {
            throw DatabaseError.newerSchema(found: current, supported: latestVersion)
        }
        for m in migrations where m.version > current && m.version <= goal {
            do {
                try db.transaction { tx in
                    for s in m.sql { try tx.execute(s) }
                    try tx.execute("PRAGMA user_version = \(m.version)")
                }
            } catch {
                throw DatabaseError.migration(version: m.version, "\(error)")
            }
        }
    }
}
