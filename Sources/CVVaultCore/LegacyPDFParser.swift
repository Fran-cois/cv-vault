import Foundation

// Kept only to recover pending edits in databases imported before extraction metadata.
enum LegacyPDFParser {
    static func facts(from pages: [CVPage]) -> [CVFact] {
        var facts: [CVFact] = []
        var activeCategory = FactCategory.other
        var hasSeenBodyLine = false

        for page in pages {
            for rawLine in page.text.split(whereSeparator: \.isNewline) {
                let evidence = String(rawLine)
                let line = stripBullet(evidence.trimmingCharacters(in: .whitespaces))
                guard !line.isEmpty else { continue }

                let category: FactCategory
                let text: String
                if let heading = parseHeading(line) {
                    if heading.category != .contact && heading.category != .identity {
                        activeCategory = heading.category
                    }
                    guard !heading.text.isEmpty else {
                        if heading.category == .contact || heading.category == .identity {
                            activeCategory = heading.category
                        }
                        hasSeenBodyLine = true
                        continue
                    }
                    category = heading.category
                    text = heading.text
                } else if isContactLine(line) {
                    category = .contact
                    text = line
                } else {
                    category = !hasSeenBodyLine && looksLikeName(line) ? .identity : activeCategory
                    text = line
                }
                hasSeenBodyLine = true
                facts.append(makeFact(on: page, text: text, evidence: evidence, category: category))
            }

            for link in page.links where !page.text.contains(link) {
                facts.append(makeFact(on: page, text: link, evidence: link, category: .contact))
            }
        }
        return facts
    }

    private static func makeFact(on page: CVPage, text: String, evidence: String, category: FactCategory) -> CVFact {
        CVFact(
            id: UUID().uuidString, sourceID: page.sourceID, page: page.number,
            category: category, text: text, evidence: evidence, status: .pending
        )
    }

    private static func stripBullet(_ line: String) -> String {
        if let first = line.first, "•◦▪‣●■".contains(first) {
            return line.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        if ["- ", "– ", "— "].contains(where: { line.hasPrefix($0) }) {
            return line.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    private static func parseHeading(_ line: String) -> (category: FactCategory, text: String)? {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let label = parts.first else { return nil }
        let key = String(label).normalizedForSearch
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "‐–—-")))
        guard let category = headings[key] else { return nil }
        let content = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return (category, content)
    }

    private static func isContactLine(_ line: String) -> Bool {
        let email = #"^[^\s@]+@[^\s@]+\.[^\s@]+(?:\s*[|·•].*)?$"#
        let url = #"^(?:https?://|mailto:|www\.)\S+(?:\s*[|·•].*)?$"#
        let phone = #"^(?:\+\d{1,3}[ .-]?)?(?:\(\d{1,4}\)|\d{2,5})(?:[ .-]?\d{2,4}){2,5}$"#
        if line.range(of: email, options: .regularExpression) != nil
            || line.range(of: url, options: .regularExpression) != nil { return true }
        let digits = line.filter(\.isNumber).count
        return (9...15).contains(digits) && line.range(of: phone, options: .regularExpression) != nil
    }

    private static func looksLikeName(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace)
        return (2...6).contains(words.count) && line.count <= 80 && line.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
                || CharacterSet.whitespaces.contains($0) || "'’-.".unicodeScalars.contains($0)
        }
    }

    private static let headings: [String: FactCategory] = {
        let groups: [(FactCategory, [String])] = [
            (.identity, ["name", "nom", "nom complet", "full name", "identite", "identity"]),
            (.contact, [
                "contact", "contacts", "coordonnees", "contact details", "email", "e-mail", "courriel",
                "telephone", "tel", "phone", "address", "adresse", "website", "site web", "linkedin",
                "github", "portfolio", "location", "localisation"
            ]),
            (.summary, ["summary", "profile", "professional summary", "profil", "resume", "a propos", "about", "objectif"]),
            (.experience, [
                "experience", "experiences", "experience professionnelle", "experiences professionnelles",
                "experience professionnelle et stages", "professional experience", "work experience",
                "employment", "employment history", "professional background", "parcours professionnel"
            ]),
            (.education, [
                "education", "formation", "formations", "formation academique", "academic background",
                "education and training", "etudes", "etudes superieures", "diplomes", "qualifications"
            ]),
            (.skills, [
                "skills", "technical skills", "core skills", "competences", "competences techniques",
                "competences cles", "technologies", "outils", "tools", "expertise", "technical expertise"
            ]),
            (.languages, ["languages", "langues", "foreign languages", "langues parlees"]),
            (.certifications, ["certifications", "certificates", "certificats", "licences", "licenses", "accreditations"]),
            (.projects, ["projects", "projets", "selected projects", "projets personnels", "personal projects", "open source"]),
            (.publications, ["publications", "articles", "research", "recherche", "communications"]),
            (.awards, ["awards", "honors", "honours", "prix", "distinctions", "recompenses"]),
            (.other, [
                "volunteering", "volunteer experience", "benevolat", "engagement associatif", "interests",
                "hobbies", "loisirs", "centres d'interet", "centres d’interet", "interets", "references",
                "other", "autres", "informations complementaires", "additional information"
            ])
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { category, labels in labels.map { ($0, category) } })
    }()
}
