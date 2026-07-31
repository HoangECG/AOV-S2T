import Foundation
import SQLite3
import OSLog

/// A small native SQLite repository. Payloads are Codable so evolving domain
/// models do not require a fragile column-per-field migration for this MVP.
public actor SQLiteTranscriptRepository: TranscriptRepository {
    private let connection: SQLiteConnection

    public init(databaseURL: URL? = nil, fileManager: FileManager = .default) throws {
        let url: URL
        if let databaseURL {
            url = databaseURL
        } else {
            let root = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = root.appendingPathComponent("MacSpeechTranslator/Data", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("sessions.sqlite")
        }
        connection = try SQLiteConnection(url: url)
        try connection.execute("PRAGMA foreign_keys = ON;")
        try connection.execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);")
        try connection.execute("CREATE TABLE IF NOT EXISTS segments (id TEXT PRIMARY KEY NOT NULL, session_id TEXT NOT NULL, payload BLOB NOT NULL, FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE);")
        try connection.execute("CREATE INDEX IF NOT EXISTS segments_session_index ON segments(session_id);")
        DiagnosticsLogger.storage.notice("Local transcript storage opened.")
    }

    public func createSession(_ session: TranscriptionSession) throws {
        try connection.upsert(table: "sessions", id: session.id.uuidString, sessionID: nil, payload: try JSONEncoder().encode(session))
    }

    public func sessions(query: String? = nil) throws -> [TranscriptionSession] {
        let records = try connection.payloads(sql: "SELECT payload FROM sessions;")
        let decoded = try records.map { try JSONDecoder().decode(TranscriptionSession.self, from: $0) }
        let filtered: [TranscriptionSession]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = decoded.filter {
                $0.title.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query)
            }
        } else {
            filtered = decoded
        }
        return filtered.sorted { $0.createdAt > $1.createdAt }
    }

    public func saveFinalSegment(_ segment: TranscriptSegment) throws {
        guard segment.isFinal else { return }
        try connection.upsert(
            table: "segments",
            id: segment.id.uuidString,
            sessionID: segment.sessionID.uuidString,
            payload: try JSONEncoder().encode(segment)
        )
    }

    public func segments(for sessionID: UUID) throws -> [TranscriptSegment] {
        let records = try connection.payloads(
            sql: "SELECT payload FROM segments WHERE session_id = ?;",
            bindings: [sessionID.uuidString]
        )
        return try records
            .map { try JSONDecoder().decode(TranscriptSegment.self, from: $0) }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime { return lhs.createdAt < rhs.createdAt }
                return lhs.startTime < rhs.startTime
            }
    }

    public func updateSegment(_ segment: TranscriptSegment) throws {
        try saveFinalSegment(segment)
    }

    public func deleteSession(id: UUID) throws {
        try connection.execute("DELETE FROM segments WHERE session_id = ?;", bindings: [id.uuidString])
        try connection.execute("DELETE FROM sessions WHERE id = ?;", bindings: [id.uuidString])
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    private var database: OpaquePointer?

    init(url: URL) throws {
        var database: OpaquePointer?
        let status = url.path.withCString {
            sqlite3_open_v2($0, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw MacSpeechTranslatorError.storageFailed("Unable to open the local transcript database.")
        }
        self.database = database
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    func execute(_ sql: String, bindings: [String] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func upsert(table: String, id: String, sessionID: String?, payload: Data) throws {
        let sql: String
        if sessionID == nil {
            sql = "INSERT INTO \(table) (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload;"
        } else {
            sql = "INSERT INTO \(table) (id, session_id, payload) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET session_id = excluded.session_id, payload = excluded.payload;"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, to: statement)
        if let sessionID {
            try bind(sessionID, at: 2, to: statement)
            try bind(payload, at: 3, to: statement)
        } else {
            try bind(payload, at: 2, to: statement)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func payloads(sql: String, bindings: [String] = []) throws -> [Data] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var values: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            values.append(Data(bytes: bytes, count: count))
        }
        let status = sqlite3_errcode(database)
        guard status == SQLITE_OK || status == SQLITE_DONE else { throw databaseError() }
        return values
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw MacSpeechTranslatorError.storageFailed("The local database is closed.") }
        var statement: OpaquePointer?
        let status = sql.withCString { sqlite3_prepare_v2(database, $0, -1, &statement, nil) }
        guard status == SQLITE_OK, let statement else { throw databaseError() }
        return statement
    }

    private func bind(_ values: [String], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            try bind(value, at: Int32(offset + 1), to: statement)
        }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
        guard status == SQLITE_OK else { throw databaseError() }
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        let status = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
        }
        guard status == SQLITE_OK else { throw databaseError() }
    }

    private func databaseError() -> MacSpeechTranslatorError {
        let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error."
        return .storageFailed(message)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
