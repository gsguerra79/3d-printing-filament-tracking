//
//  FilamentDatabase.swift
//  Creality K2 Filament Tracker and Inventory
//
//  A small, dependency-free SQLite layer built on the system libsqlite3
//  (imported directly — no SPM package needed). Mirrors the schema from
//  the original Python app's init_db() so the existing inventory can be
//  migrated in as-is.
//
//  Storage location: unlike the old app (which kept filament_inventory.sqlite3
//  next to app.py in the project folder), this app keeps its database in the
//  standard per-app Application Support location:
//    ~/Library/Application Support/<bundle id>/FilamentInventory.sqlite3
//
//  On first launch, if that file doesn't exist yet, we look for the legacy
//  Python app's database at a well-known path and copy it in so existing
//  spool data carries over automatically.
//

import Foundation
import SQLite3

enum FilamentDatabaseError: Error, LocalizedError {
    case openFailed(String)
    case sqlError(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "Could not open database: \(message)"
        case .sqlError(let message): return "Database error: \(message)"
        }
    }
}

/// Outcome of the one-time legacy-database migration, kept around so the UI
/// can show *why* the inventory is empty instead of just showing zero spools
/// with no explanation.
enum LegacyMigrationResult: CustomStringConvertible {
    case notNeeded(existingPath: String)
    case noLegacyFileFound(checkedPath: String)
    case copied(from: String, to: String)
    case copyFailed(from: String, error: String)

    var description: String {
        switch self {
        case .notNeeded(let path):
            return "Using existing database at \(path); legacy import skipped."
        case .noLegacyFileFound(let path):
            return "No legacy database found at \(path). Starting with an empty inventory."
        case .copied(let from, let to):
            return "Migrated legacy database from \(from) to \(to)."
        case .copyFailed(let from, let error):
            return "Found legacy database at \(from) but could not copy it: \(error). " +
                "This is very likely macOS blocking file access outside the app sandbox " +
                "(System Settings > Privacy & Security > Files and Folders, or Full Disk Access)."
        }
    }
}

final class FilamentDatabase {
    private var db: OpaquePointer?
    let path: URL

    /// Outcome of the one-time legacy-database migration for *this*
    /// instance. Deliberately an instance property, not `static` — a
    /// `static var` here would be nonisolated global mutable state, which
    /// Swift 6's strict concurrency checking rejects outright.
    private(set) var migrationResult: LegacyMigrationResult?

    /// Path to the old Python app's database, used only for a one-time
    /// migration on first launch. Update this if the old project folder
    /// ever moves.
    static let legacyDatabasePath = URL(
        fileURLWithPath: "/Users/gabriel/Documents/3D Printing Filament Tracking/filament_inventory.sqlite3"
    )

    static func defaultDatabaseURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser

        let bundleId = Bundle.main.bundleIdentifier ?? "FilamentTracker"
        let dir = base.appendingPathComponent(bundleId, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("FilamentInventory.sqlite3")
    }

    init(path: URL = FilamentDatabase.defaultDatabaseURL()) throws {
        self.path = path
        self.migrationResult = Self.migrateLegacyDatabaseIfNeeded(to: path)

        if sqlite3_open(path.path, &db) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw FilamentDatabaseError.openFailed(message)
        }
        try exec("PRAGMA foreign_keys = ON;")
        try createSchemaIfNeeded()
        var usageColumns = Set<String>()
        try query("PRAGMA table_info(usage_events)") { row in
            if let name = row.stringColumn(1) { usageColumns.insert(name) }
        }
        if !usageColumns.contains("material_at_use") {
            try exec("ALTER TABLE usage_events ADD COLUMN material_at_use TEXT")
        }
        if !usageColumns.contains("color_at_use") {
            try exec("ALTER TABLE usage_events ADD COLUMN color_at_use TEXT")
        }
        try exec("""
            CREATE TRIGGER IF NOT EXISTS snapshot_usage_labels AFTER INSERT ON usage_events
            BEGIN
                UPDATE usage_events
                SET material_at_use = COALESCE(NEW.material_at_use,
                        (SELECT material FROM spools WHERE id = NEW.spool_id)),
                    color_at_use = COALESCE(NEW.color_at_use,
                        (SELECT color_name FROM spools WHERE id = NEW.spool_id))
                WHERE id = NEW.id;
            END;
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    private static func migrateLegacyDatabaseIfNeeded(to newPath: URL) -> LegacyMigrationResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: newPath.path) {
            return .notNeeded(existingPath: newPath.path)
        }
        guard fm.fileExists(atPath: legacyDatabasePath.path) else {
            return .noLegacyFileFound(checkedPath: legacyDatabasePath.path)
        }
        do {
            try fm.copyItem(at: legacyDatabasePath, to: newPath)
            return .copied(from: legacyDatabasePath.path, to: newPath.path)
        } catch {
            return .copyFailed(from: legacyDatabasePath.path, error: error.localizedDescription)
        }
    }

    // MARK: - Low-level helpers

    func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw FilamentDatabaseError.sqlError(message)
        }
    }

    /// Prepares a statement, binds parameters positionally, and hands the
    /// live statement to `body` for row-by-row processing. The statement is
    /// finalized automatically afterward.
    @discardableResult
    func query(
        _ sql: String,
        bind: [SQLiteBindable] = [],
        body: (OpaquePointer) throws -> Void
    ) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw FilamentDatabaseError.sqlError(message)
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bind.enumerated() {
            value.bind(to: statement, at: Int32(index + 1))
        }

        var rowCount = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rowCount += 1
                try body(statement!)
            } else if result == SQLITE_DONE {
                break
            } else {
                let message = String(cString: sqlite3_errmsg(db))
                throw FilamentDatabaseError.sqlError(message)
            }
        }
        return rowCount
    }

    /// Runs an INSERT/UPDATE/DELETE with bound parameters.
    func run(_ sql: String, bind: [SQLiteBindable] = []) throws {
        _ = try query(sql, bind: bind) { _ in }
    }

    var lastInsertRowId: Int64 {
        sqlite3_last_insert_rowid(db)
    }

    /// Number of rows the most recent INSERT/UPDATE/DELETE touched. Used to
    /// tell "UPDATE matched an existing usage_events row" apart from
    /// "nothing matched, need to INSERT instead" (mirrors checking
    /// cursor.rowcount in the Python app).
    var lastChangeCount: Int {
        Int(sqlite3_changes(db))
    }

    // MARK: - Schema

    private func createSchemaIfNeeded() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS locations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL CHECK (kind IN ('cfs', 'dryer', 'storage', 'retired')),
            sort_order INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS spools (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            barcode TEXT,
            material TEXT NOT NULL,
            brand TEXT NOT NULL,
            color_name TEXT NOT NULL,
            color_hex TEXT NOT NULL DEFAULT '#888888',
            diameter TEXT NOT NULL DEFAULT '1.75mm',
            original_weight_g INTEGER NOT NULL DEFAULT 1000,
            remaining_weight_g INTEGER NOT NULL DEFAULT 1000,
            status TEXT NOT NULL CHECK (status IN ('sealed', 'open', 'loaded', 'retired')),
            location_id INTEGER REFERENCES locations(id) ON DELETE SET NULL,
            cfs_slot_name TEXT,
            purchased_at TEXT,
            opened_at TEXT,
            notes TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            creality_filament_id INTEGER REFERENCES creality_filaments(id) ON DELETE SET NULL,
            creality_brand TEXT,
            creality_type TEXT,
            creality_name TEXT,
            cfs_material_code TEXT,
            cfs_color_code TEXT
        );

        CREATE TABLE IF NOT EXISTS usage_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            spool_id INTEGER NOT NULL REFERENCES spools(id) ON DELETE CASCADE,
            grams_used INTEGER NOT NULL,
            project TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS pending_usage_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            slot_name TEXT NOT NULL,
            signature TEXT NOT NULL,
            filename TEXT NOT NULL DEFAULT '',
            grams_pending INTEGER NOT NULL DEFAULT 0,
            basis TEXT NOT NULL DEFAULT '',
            state TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(slot_name, signature)
        );

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS creality_filaments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_key TEXT NOT NULL UNIQUE,
            filament_id TEXT,
            brand TEXT NOT NULL,
            type TEXT NOT NULL,
            name TEXT NOT NULL,
            cfs_material_code TEXT,
            source_path TEXT,
            raw_json TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_creality_filaments_brand ON creality_filaments (brand);
        CREATE INDEX IF NOT EXISTS idx_creality_filaments_type ON creality_filaments (type);
        CREATE INDEX IF NOT EXISTS idx_creality_filaments_name ON creality_filaments (name);
        CREATE INDEX IF NOT EXISTS idx_spools_barcode ON spools (barcode);
        CREATE INDEX IF NOT EXISTS idx_spools_creality_filament ON spools (creality_filament_id);
        """)

        var count = 0
        try query("SELECT COUNT(*) FROM locations") { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        if count == 0 {
            for entry in DefaultLocations.all {
                try run(
                    "INSERT OR IGNORE INTO locations (name, kind, sort_order) VALUES (?, ?, ?)",
                    bind: [entry.name, entry.kind.rawValue, entry.sortOrder]
                )
            }
        }
    }
}

// MARK: - Parameter binding

/// A value that knows how to bind itself into a prepared SQLite statement.
protocol SQLiteBindable {
    func bind(to statement: OpaquePointer?, at index: Int32)
}

extension String: SQLiteBindable {
    func bind(to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, self, -1, SQLITE_TRANSIENT)
    }
}

extension Int: SQLiteBindable {
    func bind(to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_int64(statement, index, Int64(self))
    }
}

extension Int64: SQLiteBindable {
    func bind(to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_int64(statement, index, self)
    }
}

extension Double: SQLiteBindable {
    func bind(to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_double(statement, index, self)
    }
}

extension Optional: SQLiteBindable where Wrapped: SQLiteBindable {
    func bind(to statement: OpaquePointer?, at index: Int32) {
        switch self {
        case .none:
            sqlite3_bind_null(statement, index)
        case .some(let value):
            value.bind(to: statement, at: index)
        }
    }
}

/// SQLITE_TRANSIENT tells sqlite3 to copy the string immediately, since
/// Swift's `self` pointer isn't guaranteed to stay alive for sqlite3's use.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Row decoding helpers

extension OpaquePointer {
    func stringColumn(_ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(self, index) else { return nil }
        return String(cString: cString)
    }

    func intColumn(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(self, index))
    }

    func optionalIntColumn(_ index: Int32) -> Int64? {
        sqlite3_column_type(self, index) == SQLITE_NULL ? nil : sqlite3_column_int64(self, index)
    }

    func doubleColumn(_ index: Int32) -> Double {
        sqlite3_column_double(self, index)
    }
}
