import Foundation

public enum CVTemplate: String, CaseIterable, Codable, Sendable {
    case editorial, classic, minimal, executive, technical

    public func displayName(language: CVLanguage) -> String {
        switch (self, language) {
        case (.editorial, .fr): "Éditorial"
        case (.editorial, .en): "Editorial"
        case (.classic, .fr): "Classique"
        case (.classic, .en): "Classic"
        case (.minimal, .fr): "Minimaliste"
        case (.minimal, .en): "Minimal"
        case (.executive, .fr): "Direction"
        case (.executive, .en): "Executive"
        case (.technical, .fr): "Technique"
        case (.technical, .en): "Technical"
        }
    }

    public func description(language: CVLanguage) -> String {
        switch (self, language) {
        case (.editorial, .fr):
            "Grand nom aligné à gauche, corps à empattements et titres bleu pétrole."
        case (.editorial, .en):
            "Large left-aligned name, serif body text, and deep teal section headings."
        case (.classic, .fr):
            "En-tête centré, typographie à empattements et lignes fines en noir et blanc."
        case (.classic, .en):
            "Centered header, serif typography, and fine rules in black and white."
        case (.minimal, .fr):
            "Typographie sans empattements, sections compactes et séparation discrète."
        case (.minimal, .en):
            "Sans-serif typography, compact sections, and understated dividers."
        case (.executive, .fr):
            "En-tête de type papier à lettres, filet bleu marine et titres de poste mis en valeur."
        case (.executive, .en):
            "Letterhead layout with a navy rule and prominent role titles."
        case (.technical, .fr):
            "Bandeaux de section bleus, titres et dates à chasse fixe."
        case (.technical, .en):
            "Blue section bands with monospaced headings and dates."
        }
    }
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
