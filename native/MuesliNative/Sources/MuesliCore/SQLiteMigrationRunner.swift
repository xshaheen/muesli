import Foundation
import SQLite3

/// Runs ordered SQLite schema migrations one transaction at a time.
///
/// Each version is recorded only after its changes and postconditions succeed.
/// A failed checkpoint is intentionally treated like any other migration error,
/// which gives tests a deterministic way to prove rollback and retry behavior.
struct SQLiteMigrationRunner {
    struct Migration {
        let version: Int32
        let apply: (OpaquePointer?) throws -> Void
        let validate: (OpaquePointer?) throws -> Void
    }

    enum Checkpoint: Equatable, Sendable {
        case transactionBegan(version: Int32)
        case changesApplied(version: Int32)
        case postconditionsValidated(version: Int32)
        case versionRecorded(version: Int32)
        case willCommit(version: Int32)
    }

    typealias CheckpointHook = (Checkpoint) throws -> Void

    enum RunnerError: Error, LocalizedError {
        case invalidMigrationOrder
        case databaseVersionIsNewer(found: Int32, latestSupported: Int32)
        case foreignKeyViolation(table: String, rowID: Int64, parent: String, constraint: Int32)

        var errorDescription: String? {
            switch self {
            case .invalidMigrationOrder:
                return "SQLite migrations must have unique, strictly increasing positive versions."
            case .databaseVersionIsNewer(let found, let latestSupported):
                return "Database schema version \(found) is newer than supported version \(latestSupported)."
            case .foreignKeyViolation(let table, let rowID, let parent, let constraint):
                return "Foreign-key check failed for \(table) row \(rowID), parent \(parent), constraint \(constraint)."
            }
        }
    }

    let db: OpaquePointer?
    let migrations: [Migration]
    var checkpoint: CheckpointHook?

    func run() throws {
        guard migrations.map(\.version) == migrations.map(\.version).sorted(),
              Set(migrations.map(\.version)).count == migrations.count,
              migrations.allSatisfy({ $0.version > 0 }) else {
            throw RunnerError.invalidMigrationOrder
        }

        let latestVersion = migrations.last?.version ?? 0
        var currentVersion = try readUserVersion()
        guard currentVersion <= latestVersion else {
            throw RunnerError.databaseVersionIsNewer(found: currentVersion, latestSupported: latestVersion)
        }

        for migration in migrations where migration.version > currentVersion {
            try execute("BEGIN IMMEDIATE")
            do {
                try checkpoint?(.transactionBegan(version: migration.version))
                try migration.apply(db)
                try checkpoint?(.changesApplied(version: migration.version))
                try migration.validate(db)
                try validateForeignKeys()
                try checkpoint?(.postconditionsValidated(version: migration.version))
                try execute("PRAGMA user_version = \(migration.version)")
                try checkpoint?(.versionRecorded(version: migration.version))
                try checkpoint?(.willCommit(version: migration.version))
                try execute("COMMIT")
                currentVersion = migration.version
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }

        // A current database is still checked on every open. This detects schema
        // damage without replaying data repairs or DDL that already has a version.
        if let currentMigration = migrations.last, currentVersion == currentMigration.version {
            try currentMigration.validate(db)
            try validateForeignKeys()
        }
    }

    private func readUserVersion() throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError()
        }
        return sqlite3_column_int(statement, 0)
    }

    private func validateForeignKeys() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA foreign_key_check", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }

        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return
        case SQLITE_ROW:
            throw RunnerError.foreignKeyViolation(
                table: textColumn(statement, index: 0),
                rowID: sqlite3_column_int64(statement, 1),
                parent: textColumn(statement, index: 2),
                constraint: sqlite3_column_int(statement, 3)
            )
        default:
            throw sqliteError()
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func sqliteError() -> NSError {
        NSError(
            domain: "MuesliDBMigration",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }

    private func textColumn(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }
}
