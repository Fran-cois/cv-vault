import Foundation

public enum FactCategory: String, CaseIterable, Codable, Sendable {
    case identity, contact, summary, experience, education, skills, languages
    case certifications, projects, publications, awards, other
}

public enum FactStatus: String, CaseIterable, Codable, Sendable {
    case pending, verified, rejected
}

public enum PageMethod: String, CaseIterable, Codable, Sendable {
    case text, ocr, unreadable
}

public struct CVSource: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let sha256: String
    public let importedAt: Date
    public let pageCount: Int
    public let factCount: Int
    public let unreadablePageCount: Int
    public let pendingFactCount: Int
    public let verifiedFactCount: Int
    public let rejectedFactCount: Int

    public init(
        id: String, name: String, sha256: String, importedAt: Date, pageCount: Int,
        factCount: Int, unreadablePageCount: Int, pendingFactCount: Int = 0,
        verifiedFactCount: Int = 0, rejectedFactCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.sha256 = sha256
        self.importedAt = importedAt
        self.pageCount = pageCount
        self.factCount = factCount
        self.unreadablePageCount = unreadablePageCount
        self.pendingFactCount = pendingFactCount
        self.verifiedFactCount = verifiedFactCount
        self.rejectedFactCount = rejectedFactCount
    }
}

public struct CVPage: Identifiable, Codable, Sendable, Equatable {
    public var id: Int { number }
    public let sourceID: String
    public let number: Int
    public let text: String
    public let links: [String]
    public let method: PageMethod

    public init(sourceID: String, number: Int, text: String, links: [String], method: PageMethod) {
        self.sourceID = sourceID
        self.number = number
        self.text = text
        self.links = links
        self.method = method
    }
}

public struct CVFact: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let sourceID: String
    public let page: Int
    public let category: FactCategory
    public let text: String
    public let evidence: String
    public let status: FactStatus

    public init(
        id: String, sourceID: String, page: Int, category: FactCategory,
        text: String, evidence: String, status: FactStatus
    ) {
        self.id = id
        self.sourceID = sourceID
        self.page = page
        self.category = category
        self.text = text
        self.evidence = evidence
        self.status = status
    }
}

public struct PDFImportResult: Codable, Sendable, Equatable {
    public let source: CVSource
    public let isDuplicate: Bool

    public init(source: CVSource, isDuplicate: Bool) {
        self.source = source
        self.isDuplicate = isDuplicate
    }
}

public enum KnowledgeBaseError: LocalizedError {
    case invalidPDF
    case lockedPDF
    case fileTooLarge
    case tooManyPages
    case invalidDatabaseURL
    case databaseAccess
    case databaseVersion
    case database(String)
    case invalidRange
    case invalidQuery
    case invalidFactText
    case sourceNotFound
    case factNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidPDF: "The file could not be read as a PDF."
        case .lockedPDF: "Unlock the PDF in Preview before importing it."
        case .fileTooLarge: "The PDF exceeds the 50 MiB import limit."
        case .tooManyPages: "The PDF exceeds the 100-page import limit."
        case .invalidDatabaseURL: "The knowledge base requires a local file path."
        case .databaseAccess: "The knowledge base file could not be opened with private permissions."
        case .databaseVersion: "This knowledge base requires a newer version of CV Vault."
        case .database(let message): "SQLite: \(message)"
        case .invalidRange: "Use a limit from 1 to 1000 and a valid starting position."
        case .invalidQuery: "Search with at most 512 characters and 16 terms."
        case .invalidFactText: "Enter fact text of 1 to 8,000 characters."
        case .sourceNotFound: "This source is no longer in the knowledge base."
        case .factNotFound: "This fact is no longer in the knowledge base."
        }
    }
}

extension String {
    var normalizedForSearch: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
