import XCTest
@testable import CVVaultCore

final class FactStructureTests: XCTestCase {
    func testDatedEntryPreservesItsFactsAndStopsAtSourceBoundaries() {
        let facts = [
            fact("position", "Ingénieure plateforme", .experience),
            fact("employer", "Atelier Démo", .experience),
            fact("period", "2021 – aujourd’hui", .experience),
            fact("impact", "Réduction des temps de chargement", .experience, bullet: true, status: .verified),
            fact("rejected", "Refonte de la chaîne de déploiement", .experience, bullet: true, status: .rejected),
            fact("next-page", "Supervision des incidents", .experience, page: 2, bullet: true),
            fact("other-source", "Migration de la base", .experience, source: "source-b", page: 2, bullet: true),
            fact("skill", "Python et SQL", .skills, source: "source-b", page: 2),
            fact("language", "Français et anglais", .languages, source: "source-b", page: 2)
        ]

        let entries = CVFactStructure.organize(facts)

        XCTAssertEqual(entries.map(\.id), ["position", "next-page", "other-source", "skill", "language"])
        XCTAssertEqual(entries.flatMap(\.fields).map(\.fact), facts)
        XCTAssertEqual(entries.first?.fields.map(\.role), [.title, .organization, .date, .achievement, .achievement])
        XCTAssertEqual(entries.dropFirst().flatMap(\.fields).map(\.role), [.achievement, .achievement, .skill, .language])
    }

    func testOnlyUnambiguousProjectLinksAreAttachedToTheirLabels() {
        let facts = [
            fact("linked-project", "Observatoire ↗", .projects),
            fact("attached-link", "https://example.invalid/observatoire", .projects),
            fact("ambiguous-project", "Bibliothèque ↗", .projects),
            fact("possible-link-1", "https://example.invalid/bibliotheque", .projects),
            fact("possible-link-2", "https://example.invalid/documentation", .projects),
            fact("dated-project", "Application de démonstration", .projects),
            fact("project-dates", "2018 - 2019", .projects),
            fact("project-result", "Réalisation du prototype", .projects, bullet: true)
        ]

        let entries = CVFactStructure.organize(facts)

        XCTAssertEqual(entries.map(\.id), ["linked-project", "ambiguous-project", "possible-link-1", "possible-link-2", "dated-project"])
        XCTAssertEqual(entries.map { $0.fields.map(\.role) }, [[.title, .link], [.detail], [.link], [.link], [.title, .date, .achievement]])
        XCTAssertEqual(entries.flatMap(\.fields).map(\.fact), facts)
    }

    private func fact(
        _ id: String, _ text: String, _ category: FactCategory, source: String = "source-a", page: Int = 1,
        bullet: Bool = false, status: FactStatus = .pending
    ) -> CVFact {
        CVFact(id: id, sourceID: source, page: page, category: category, text: text,
               evidence: bullet ? "• " + text : text, status: status)
    }
}
