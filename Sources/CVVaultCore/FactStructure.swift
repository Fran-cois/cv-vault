import Foundation

public enum CVFactRole: String, Codable, Sendable, CaseIterable {
    case title, organization, date, achievement, skill, language, link, detail
}

public struct CVStructuredField: Identifiable, Codable, Equatable, Sendable {
    public let role: CVFactRole
    public let fact: CVFact

    public var id: String { fact.id }
}

public struct CVStructuredEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let category: FactCategory
    public let fields: [CVStructuredField]

    fileprivate init(anchor: CVFact, fields: [CVStructuredField]) {
        self.id = anchor.id
        self.sourceID = anchor.sourceID
        self.category = anchor.category
        self.fields = fields
    }
}

public enum CVFactStructure {
    /// Groups consecutive facts in source order. The fact in each field retains its original
    /// ID, evidence, and review status. Group boundaries do not depend on review status.
    public static func organize(_ facts: [CVFact]) -> [CVStructuredEntry] {
        var entries: [CVStructuredEntry] = []
        var start = 0
        while start < facts.count {
            let anchor = facts[start]
            var end = start + 1
            while end < facts.count,
                  facts[end].sourceID == anchor.sourceID,
                  facts[end].page == anchor.page,
                  facts[end].category == anchor.category {
                end += 1
            }
            entries.append(contentsOf: organizePageSection(facts[start..<end]))
            start = end
        }
        return entries
    }

    private static func organizePageSection(_ facts: ArraySlice<CVFact>) -> [CVStructuredEntry] {
        var entries: [CVStructuredEntry] = []
        var index = facts.startIndex
        while index < facts.endIndex {
            let anchor = facts[index]
            let following = facts.dropFirst(index - facts.startIndex + 1)
            let attached = switch anchor.category {
            case .experience, .education:
                chronologyFields(anchor, following: following)
            case .projects:
                projectFields(anchor, following: following)
            default:
                [CVStructuredField]()
            }
            let role = attached.isEmpty ? standaloneRole(anchor) : .title
            let fields = [CVStructuredField(role: role, fact: anchor)] + attached
            entries.append(CVStructuredEntry(anchor: anchor, fields: fields))
            index += fields.count
        }
        return entries
    }

    private static func chronologyFields(_ anchor: CVFact, following: ArraySlice<CVFact>) -> [CVStructuredField] {
        guard canBeTitle(anchor) else { return [] }

        var fields: [CVStructuredField] = []
        var next = following
        // The importer records a short organization line between the title and its date
        // when it detects a dated entry. A nearby date anchors that association.
        if let organization = next.first, canBeTitle(organization),
           organization.text.count <= 75,
           let date = next.dropFirst().first, isDateFact(date) {
            fields.append(CVStructuredField(role: .organization, fact: organization))
            next = next.dropFirst()
        }
        if let date = next.first, isDateFact(date) {
            fields.append(CVStructuredField(role: .date, fact: date))
            next = next.dropFirst()
        }
        fields.append(contentsOf: next.prefix(while: isBullet).map { CVStructuredField(role: .achievement, fact: $0) })
        return fields
    }

    private static func projectFields(_ anchor: CVFact, following: ArraySlice<CVFact>) -> [CVStructuredField] {
        // A single arrow followed by a single URL matches the link annotation imported
        // beside a project title. Multiple adjacent URLs remain independent fields.
        if linkArrowCount(anchor.evidence) == 1, !isWebLink(anchor.text), !isBullet(anchor),
           let link = following.first, isWebLink(link.text),
           following.dropFirst().first.map({ !isWebLink($0.text) }) ?? true {
            return [CVStructuredField(role: .link, fact: link)]
        }
        return chronologyFields(anchor, following: following)
    }

    private static func linkArrowCount(_ value: String) -> Int {
        value.filter { $0 == "↗" }.count
    }

    private static func standaloneRole(_ fact: CVFact) -> CVFactRole {
        if isWebLink(fact.text) { return .link }
        switch fact.category {
        case .skills: return .skill
        case .languages: return .language
        case .experience, .education, .projects:
            if isDateFact(fact) { return .date }
            if isBullet(fact) { return .achievement }
            return .detail
        case .certifications, .publications, .awards:
            return !isBullet(fact) && isDate(fact.text) ? .date : .detail
        default: return .detail
        }
    }

    private static func canBeTitle(_ fact: CVFact) -> Bool {
        let text = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= 120 && !text.contains(where: \.isNewline)
            && !isBullet(fact) && !isDate(text) && !isWebLink(text)
            && text.last.map { !".;!?".contains($0) } == true
    }

    static func isBullet(_ fact: CVFact) -> Bool {
        let text = fact.evidence
        return bulletPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func isDateFact(_ fact: CVFact) -> Bool {
        !isBullet(fact) && isDate(fact.text, category: fact.category)
    }

    static func isDate(_ value: String, includingYear: Bool = true) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..., in: text)
        return datePattern.firstMatch(in: text, range: range) != nil
            || (includingYear && yearPattern.firstMatch(in: text, range: range) != nil)
    }

    static func isDate(_ value: String, category: FactCategory) -> Bool {
        isDate(value, includingYear: category == .education)
    }

    private static func isWebLink(_ value: String) -> Bool {
        guard !value.contains(where: \.isWhitespace), let url = URLComponents(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return url.url != nil
    }

    private static let datePattern = try! NSRegularExpression(
        pattern: #"^(?:(?:[\p{L}.]{3,12}\s+|\d{1,2}[/.-])?(?:19|20)\d{2}(?:[-/]\d{2})?)\s*(?:[-–—−]|\bto\b|\bà\b|\bau\b)\s*(?:(?:[\p{L}.]{3,12}\s+|\d{1,2}[/.-])?(?:19|20)\d{2}(?:[-/]\d{2})?|present|présent|current|en cours|aujourd['’]hui|actuel(?:lement)?)$"#,
        options: .caseInsensitive
    )
    private static let yearPattern = try! NSRegularExpression(pattern: #"^(?:19|20)\d{2}$"#)
    private static let bulletPattern = try! NSRegularExpression(pattern: #"^\s*(?:[•◦▪‣●■]|[-–—]\s)"#)
}
