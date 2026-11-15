import Foundation

public enum CVTemplate: String, CaseIterable, Codable, Sendable {
    case editorial, classic
}

public enum CVPaper: String, CaseIterable, Codable, Sendable {
    case a4, letter
}

/// A section contains structured entries followed by standalone facts. Its position sets the order in the CV.
public struct CVSection: Codable, Equatable, Sendable {
    public let category: FactCategory
    public let factIDs: [String]
    public let entries: [CVEntry]

    public init(category: FactCategory, factIDs: [String] = [], entries: [CVEntry] = []) {
        self.category = category
        self.factIDs = factIDs
        self.entries = entries
    }
}

/// Every heading, metadata line and bullet points to a verified fact in the matching section.
public struct CVEntry: Codable, Equatable, Sendable {
    public let headingFactID: String
    public let metadataFactIDs: [String]
    public let bulletFactIDs: [String]

    public init(headingFactID: String, metadataFactIDs: [String] = [], bulletFactIDs: [String] = []) {
        self.headingFactID = headingFactID
        self.metadataFactIDs = metadataFactIDs
        self.bulletFactIDs = bulletFactIDs
    }
}

public enum CVCompositionError: LocalizedError, Equatable {
    case headerSection
    case repeatedSection
    case emptySection
    case unsupportedEntries
    case unknownFact
    case wrongCategory
    case repeatedFact
    case unusedFact

    public var errorDescription: String? {
        switch self {
        case .headerSection: "Identity and contact facts are placed in the header automatically."
        case .repeatedSection: "Use each CV section category only once."
        case .emptySection: "Each CV section needs a fact or an entry."
        case .unsupportedEntries: "Structured entries are available for experience, education and projects."
        case .unknownFact: "A CV section refers to a fact outside the selection."
        case .wrongCategory: "Use facts from the same category as the CV section."
        case .repeatedFact: "Use each selected CV fact only once."
        case .unusedFact: "Use every selected fact in the CV sections or remove it from the selection."
        }
    }
}
