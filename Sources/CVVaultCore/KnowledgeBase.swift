import CryptoKit
import Darwin
import Foundation
import SQLite3

public final class KnowledgeBase: Sendable {
    public static var defaultDataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["CV_VAULT_HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("CV Vault", isDirectory: true)
    }

    public static var defaultDatabaseURL: URL {
        defaultDataDirectory.appendingPathComponent("knowledge.sqlite3", isDirectory: false)
    }

    public let databaseURL: URL

    public init(databaseURL: URL = KnowledgeBase.defaultDatabaseURL) throws {
        guard databaseURL.isFileURL, databaseURL.path.hasPrefix("/") else {
            throw KnowledgeBaseError.invalidDatabaseURL
        }
        self.databaseURL = databaseURL.standardizedFileURL
        try FileManager.default.createDirectory(
            at: self.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.protectDatabaseFile(at: self.databaseURL)

        let database = try connect()
        let version = try database.query("PRAGMA user_version") { $0.integer(0) }.first
        guard version == 0 || version == 1 else { throw KnowledgeBaseError.databaseVersion }
        if version == 0 {
            try database.transaction {
                let current = try database.query("PRAGMA user_version") { $0.integer(0) }.first
                if current == 1 { return }
                guard current == 0 else { throw KnowledgeBaseError.databaseVersion }
                try database.execute(Self.schema)
                try database.execute("PRAGMA user_version = 1")
            }
        }
    }

    private static func protectDatabaseFile(at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw KnowledgeBaseError.databaseAccess }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              fchmod(descriptor, mode_t(0o600)) == 0
        else { throw KnowledgeBaseError.databaseAccess }
    }

    public func importPDF(at url: URL) throws -> PDFImportResult {
        let data = try PDFImporter.read(at: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let database = try connect()
        if let existing = try findSource(in: database, where: "sha256 = ?", value: hash) {
            return PDFImportResult(source: existing, isDuplicate: true)
        }

        let id = UUID().uuidString
        let pages = try PDFImporter.extractPages(from: data, sourceID: id)
        let facts = PDFImporter.facts(from: pages)
        let name = url.lastPathComponent
        let date = Date()
        let unreadable = pages.filter { $0.method == .unreadable }.count
        let linkEncoder = JSONEncoder()

        return try database.transaction {
            if let existing = try findSource(in: database, where: "sha256 = ?", value: hash) {
                return PDFImportResult(source: existing, isDuplicate: true)
            }
            try database.run(
                """
                INSERT INTO sources (id, name, sha256, imported_at, page_count, unreadable_page_count, pdf)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(id), .text(name), .text(hash), .real(date.timeIntervalSince1970),
                 .integer(pages.count), .integer(unreadable), .blob(data)]
            )
            for page in pages {
                try database.run(
                    "INSERT INTO pages (source_id, number, text, links, method) VALUES (?, ?, ?, ?, ?)",
                    [.text(id), .integer(page.number), .text(page.text),
                     .blob(try linkEncoder.encode(page.links)), .text(page.method.rawValue)]
                )
            }
            for (position, fact) in facts.enumerated() {
                try database.run(
                    """
                    INSERT INTO facts (id, source_id, page, position, category, text, evidence, status, search_text)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(fact.id), .text(id), .integer(fact.page), .integer(position), .text(fact.category.rawValue),
                     .text(fact.text), .text(fact.evidence), .text(fact.status.rawValue),
                     .text(Self.searchText(for: fact.text, evidence: fact.evidence))]
                )
            }
            return PDFImportResult(
                source: CVSource(
                    id: id, name: name, sha256: hash, importedAt: date,
                    pageCount: pages.count, factCount: facts.count, unreadablePageCount: unreadable,
                    pendingFactCount: facts.count
                ),
                isDuplicate: false
            )
        }
    }

    public func listSources(limit: Int = 100, offset: Int = 0) throws -> [CVSource] {
        try Self.validateRange(limit: limit, offset: offset)
        return try connect().query(
            Self.sourceSelect + " ORDER BY s.imported_at DESC, s.id LIMIT ? OFFSET ?",
            [.integer(limit), .integer(offset)], map: Self.readSource
        )
    }

    public func source(id: String) throws -> CVSource? {
        try findSource(in: connect(), where: "id = ?", value: id)
    }

    public func pages(sourceID: String, startPage: Int = 1, limit: Int = 100) throws -> [CVPage] {
        guard startPage >= 1 else { throw KnowledgeBaseError.invalidRange }
        try Self.validateRange(limit: limit, offset: 0)
        let decoder = JSONDecoder()
        return try connect().query(
            """
            SELECT source_id, number, text, links, method
            FROM pages WHERE source_id = ? AND number >= ? ORDER BY number LIMIT ?
            """,
            [.text(sourceID), .integer(startPage), .integer(limit)]
        ) { row in
            guard let method = PageMethod(rawValue: row.text(4)) else {
                throw KnowledgeBaseError.database("Unknown page extraction method.")
            }
            return CVPage(
                sourceID: row.text(0), number: row.integer(1), text: row.text(2),
                links: try decoder.decode([String].self, from: row.blob(3)), method: method
            )
        }
    }

    public func originalPDF(sourceID: String) throws -> Data? {
        try connect().query("SELECT pdf FROM sources WHERE id = ?", [.text(sourceID)]) { $0.blob(0) }.first
    }

    public func searchFacts(
        query: String = "", category: FactCategory? = nil, status: FactStatus? = nil,
        sourceID: String? = nil, limit: Int = 100, offset: Int = 0
    ) throws -> [CVFact] {
        try Self.validateRange(limit: limit, offset: offset)
        guard query.count <= 512 else { throw KnowledgeBaseError.invalidQuery }
        let terms = query.normalizedForSearch.split(whereSeparator: \.isWhitespace)
        guard terms.count <= 16 else { throw KnowledgeBaseError.invalidQuery }

        let filters: [(String, String?)] = [
            ("f.category = ?", category?.rawValue), ("f.status = ?", status?.rawValue),
            ("f.source_id = ?", sourceID)
        ]
        var predicates: [String] = []
        var bindings: [SQLValue] = []
        for (predicate, value) in filters {
            if let value {
                predicates.append(predicate)
                bindings.append(.text(value))
            }
        }
        for term in terms {
            predicates.append("instr(f.search_text, ?) > 0")
            bindings.append(.text(String(term)))
        }
        let whereClause = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        let tail = " ORDER BY s.imported_at DESC, f.source_id, f.position LIMIT ? OFFSET ?"
        return try connect().query(
            Self.factSelect + " JOIN sources s ON s.id = f.source_id" + whereClause + tail,
            bindings + [.integer(limit), .integer(offset)], map: Self.readFact
        )
    }

    public func fact(id: String) throws -> CVFact? {
        try lookupFact(id: id, in: connect())
    }

    /// Returns matching facts in request order. Missing IDs are omitted.
    public func facts(ids: [String]) throws -> [CVFact] {
        guard ids.count <= 1_000 else { throw KnowledgeBaseError.invalidRange }
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try connect().query(
            Self.factSelect + " WHERE f.id IN (" + placeholders + ")", ids.map(SQLValue.text), map: Self.readFact
        )
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    public func updateFact(id: String, text: String, category: FactCategory, status: FactStatus) throws -> CVFact {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 8_000, !value.contains("\0") else {
            throw KnowledgeBaseError.invalidFactText
        }
        let database = try connect()
        return try database.transaction {
            guard let existing = try lookupFact(id: id, in: database) else { throw KnowledgeBaseError.factNotFound }
            try database.run(
                "UPDATE facts SET text = ?, category = ?, status = ?, search_text = ? WHERE id = ?",
                [.text(value), .text(category.rawValue), .text(status.rawValue),
                 .text(Self.searchText(for: value, evidence: existing.evidence)), .text(id)]
            )
            return CVFact(
                id: existing.id, sourceID: existing.sourceID, page: existing.page,
                category: category, text: value, evidence: existing.evidence, status: status
            )
        }
    }

    public func verifyPendingFacts(sourceID: String) throws -> Int {
        let database = try connect()
        return try database.transaction {
            let sourceExists = try database.query("SELECT 1 FROM sources WHERE id = ?", [.text(sourceID)]) {
                $0.integer(0)
            }.first != nil
            guard sourceExists else { throw KnowledgeBaseError.sourceNotFound }
            return try database.run(
                "UPDATE facts SET status = 'verified' WHERE source_id = ? AND status = 'pending'",
                [.text(sourceID)]
            )
        }
    }

    public func deleteSource(id: String) throws {
        let database = try connect()
        let rows = try database.run("DELETE FROM sources WHERE id = ?", [.text(id)])
        guard rows == 1 else { throw KnowledgeBaseError.sourceNotFound }
    }

    private func connect() throws -> SQLiteConnection {
        let database = try SQLiteConnection(url: databaseURL)
        try database.execute("PRAGMA foreign_keys = ON; PRAGMA secure_delete = ON")
        return database
    }

    private func findSource(in database: SQLiteConnection, where column: String, value: String) throws -> CVSource? {
        try database.query(Self.sourceSelect + " WHERE s." + column, [.text(value)], map: Self.readSource).first
    }

    private func lookupFact(id: String, in database: SQLiteConnection) throws -> CVFact? {
        try database.query(Self.factSelect + " WHERE f.id = ?", [.text(id)], map: Self.readFact).first
    }

    private static func searchText(for text: String, evidence: String) -> String {
        (text + "\n" + evidence).normalizedForSearch
    }

    private static func validateRange(limit: Int, offset: Int) throws {
        guard (1...1_000).contains(limit), offset >= 0 else { throw KnowledgeBaseError.invalidRange }
    }

    private static func readSource(_ row: SQLRow) -> CVSource {
        CVSource(
            id: row.text(0), name: row.text(1), sha256: row.text(2),
            importedAt: Date(timeIntervalSince1970: row.real(3)), pageCount: row.integer(4),
            factCount: row.integer(6), unreadablePageCount: row.integer(5), pendingFactCount: row.integer(7),
            verifiedFactCount: row.integer(8), rejectedFactCount: row.integer(9)
        )
    }

    private static func readFact(_ row: SQLRow) throws -> CVFact {
        guard let category = FactCategory(rawValue: row.text(3)), let status = FactStatus(rawValue: row.text(6)) else {
            throw KnowledgeBaseError.database("Unknown fact category or review status.")
        }
        return CVFact(
            id: row.text(0), sourceID: row.text(1), page: row.integer(2), category: category,
            text: row.text(4), evidence: row.text(5), status: status
        )
    }

    private static let sourceSelect = """
        SELECT s.id, s.name, s.sha256, s.imported_at, s.page_count, s.unreadable_page_count,
               (SELECT COUNT(*) FROM facts WHERE source_id = s.id),
               (SELECT COUNT(*) FROM facts WHERE source_id = s.id AND status = 'pending'),
               (SELECT COUNT(*) FROM facts WHERE source_id = s.id AND status = 'verified'),
               (SELECT COUNT(*) FROM facts WHERE source_id = s.id AND status = 'rejected')
        FROM sources s
        """

    private static let factSelect = "SELECT f.id, f.source_id, f.page, f.category, f.text, f.evidence, f.status FROM facts f"

    private static let schema = """
        CREATE TABLE sources (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            sha256 TEXT NOT NULL UNIQUE,
            imported_at REAL NOT NULL,
            page_count INTEGER NOT NULL CHECK (page_count > 0),
            unreadable_page_count INTEGER NOT NULL CHECK (unreadable_page_count BETWEEN 0 AND page_count),
            pdf BLOB NOT NULL
        ) WITHOUT ROWID;

        CREATE TABLE pages (
            source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            number INTEGER NOT NULL CHECK (number > 0),
            text TEXT NOT NULL,
            links BLOB NOT NULL,
            method TEXT NOT NULL CHECK (method IN ('text', 'ocr', 'unreadable')),
            PRIMARY KEY (source_id, number)
        ) WITHOUT ROWID;

        CREATE TABLE facts (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            page INTEGER NOT NULL,
            position INTEGER NOT NULL CHECK (position >= 0),
            category TEXT NOT NULL CHECK (category IN ('identity', 'contact', 'summary', 'experience', 'education',
                'skills', 'languages', 'certifications', 'projects', 'publications', 'awards', 'other')),
            text TEXT NOT NULL,
            evidence TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('pending', 'verified', 'rejected')),
            search_text TEXT NOT NULL,
            FOREIGN KEY (source_id, page) REFERENCES pages(source_id, number) ON DELETE CASCADE
        ) WITHOUT ROWID;

        CREATE INDEX facts_by_source ON facts(source_id, page);
        CREATE INDEX facts_by_status ON facts(source_id, status);
        """
}

private enum SQLValue {
    case text(String)
    case integer(Int)
    case real(Double)
    case blob(Data)
}

private struct SQLRow {
    let statement: OpaquePointer

    func text(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }

    func integer(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    func real(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }

    func blob(_ index: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
    }
}

private final class SQLiteConnection {
    private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var pointer: OpaquePointer?
        let result = url.withUnsafeFileSystemRepresentation { path in
            sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard result == SQLITE_OK, let pointer else {
            let error = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database."
            sqlite3_close_v2(pointer)
            throw KnowledgeBaseError.database(error)
        }

        self.handle = pointer
        sqlite3_busy_timeout(pointer, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    private var error: KnowledgeBaseError {
        .database(String(cString: sqlite3_errmsg(handle)))
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
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

    @discardableResult
    func run(_ sql: String, _ bindings: [SQLValue]) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
        return Int(sqlite3_changes(handle))
    }

    func query<T>(
        _ sql: String, _ bindings: [SQLValue] = [], map: (SQLRow) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try rows.append(map(SQLRow(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw error
            }
        }
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let statement = pointer else {
            sqlite3_finalize(pointer)
            throw error
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString {
                    sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), Self.transient)
                }
            case .integer(let integer): result = sqlite3_bind_int64(statement, index, Int64(integer))
            case .real(let real): result = sqlite3_bind_double(statement, index, real)
            case .blob(let data):
                result = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient)
                }
            }
            guard result == SQLITE_OK else {
                let failure = error
                sqlite3_finalize(statement)
                throw failure
            }
        }
        return statement
    }
}
