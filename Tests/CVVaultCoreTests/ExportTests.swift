import Foundation
import XCTest
@testable import CVVaultCore

final class ExportTests: XCTestCase {
    func testRendererKeepsSelectionOrderAndEscapesImportedText() throws {
        let source = try CVExporter.generate(facts: [
            fact("name", .identity, "Camille Exemple"),
            fact("skill", .skills, "Swift [UI] #include(\"private.typ\") \\ é"),
            fact("project-b", .projects, "Second project"),
            fact("project-a", .projects, "First project")
        ], labels: [.skills: "Ce que je sais faire"], language: .en, title: "Platform developer")

        XCTAssertTrue(source.contains(#"#cv-detail("Swift [UI] #include(\"private.typ\") \\ é")"#))
        XCTAssertTrue(source.contains(#"#cv-subtitle("Platform developer")"#))
        let skills = try XCTUnwrap(source.range(of: "#cv-section(\"Ce que je sais faire\")"))
        let projects = try XCTUnwrap(source.range(of: "#cv-section(\"Projects\")"))
        XCTAssertLessThan(skills.lowerBound, projects.lowerBound)
        XCTAssertLessThan(try XCTUnwrap(source.range(of: "Second project")).lowerBound,
                          try XCTUnwrap(source.range(of: "First project")).lowerBound)
    }

    func testStructuredLayoutKeepsEntryEvidenceAndSectionOrder() throws {
        let facts = [
            fact("name", .identity, "Camille Exemple"),
            fact("skill", .skills, "Swift"),
            fact("result", .experience, "Reduced a reporting delay from one day to one hour."),
            fact("role", .experience, "Lead engineer, Atelier Exemple"),
            fact("dates", .experience, "2021 – 2024"),
        ]
        let sections = [
            CVSection(category: .experience, entries: [
                CVEntry(headingFactID: "role", metadataFactIDs: ["dates"], bulletFactIDs: ["result"]),
            ]),
            CVSection(category: .skills, factIDs: ["skill"]),
        ]
        let source = try CVExporter.generate(facts: facts, language: .en, template: .classic, paper: .letter, sections: sections)
        XCTAssertTrue(source.contains(#"paper: "us-letter""#))
        XCTAssertTrue(source.contains(#"#cv-entry("Lead engineer, Atelier Exemple", ("2021 – 2024",), ("Reduced a reporting delay from one day to one hour.",))"#))
        let experience = try XCTUnwrap(source.range(of: #"#cv-section("Experience")"#))
        let skills = try XCTUnwrap(source.range(of: #"#cv-section("Skills")"#))
        XCTAssertLessThan(experience.lowerBound, skills.lowerBound)
    }

    func testStructuredLayoutRejectsUnknownRepeatedAndMisplacedFacts() throws {
        let facts = [
            fact("role", .experience, "Software engineer"),
            fact("dates", .experience, "2021 – 2024"),
            fact("skill", .skills, "Swift"),
        ]
        let tests: [(CVCompositionError, [CVSection])] = [
            (.unknownFact, [CVSection(category: .experience, factIDs: ["missing"])]),
            (.repeatedFact, [CVSection(category: .experience, factIDs: ["role"], entries: [
                CVEntry(headingFactID: "role"),
            ])]),
            (.wrongCategory, [CVSection(category: .experience, entries: [
                CVEntry(headingFactID: "role", metadataFactIDs: ["skill"]),
            ])]),
            (.unusedFact, [CVSection(category: .experience, entries: [
                CVEntry(headingFactID: "role"),
            ])]),
        ]
        for (expected, sections) in tests {
            XCTAssertThrowsError(try CVExporter.generate(facts: facts, sections: sections)) { error in
                XCTAssertEqual(error as? CVCompositionError, expected)
            }
        }
    }

    func testFlatLayoutOnlyGroupsWhenSourceShowsEntryStructure() throws {
        let facts = [
            fact("role", .experience, "Architecte logiciel"),
            fact("company", .experience, "Atelier Exemple, Paris"),
            fact("dates", .experience, "janvier 2020 – août 2024"),
            fact("result", .experience, "Industrialisation des tests.", evidence: "• Industrialisation des tests."),
            fact("note", .experience, "Information complémentaire."),
            fact("across-page", .experience, "Observation sur une autre page", evidence: "• Observation sur une autre page", page: 2),
            fact("degree", .education, "Master en informatique"),
            fact("university", .education, "Université Exemple"),
            fact("year", .education, "2018"),
        ]
        let source = try CVExporter.generate(facts: facts)
        XCTAssertTrue(source.contains(#"#cv-entry("Architecte logiciel", ("Atelier Exemple, Paris", "janvier 2020 – août 2024",), ("Industrialisation des tests.",))"#))
        XCTAssertTrue(source.contains(#"#cv-entry("Master en informatique", ("Université Exemple", "2018",), ())"#))
        XCTAssertTrue(source.contains(#"#list.item("Information complémentaire.")"#))
        XCTAssertTrue(source.contains(#"#list.item("Observation sur une autre page")"#))
    }

    func testRendererRequiresVerifiedUniqueFactsFromOneSource() throws {
        let one = fact("one", .skills, "Testing")
        for (facts, expected) in [
            ([], CVExportError.emptySelection),
            ([fact("pending", .skills, "Draft", status: .pending)], .unverifiedFact),
            ([one, one], .duplicateFact),
            ([one, fact("two", .skills, "Swift", sourceID: "other")], .multipleSources),
        ] {
            XCTAssertThrowsError(try CVExporter.generate(facts: facts)) { error in
                XCTAssertEqual(error as? CVExportError, expected)
            }
        }
    }

    func testSaveStaysInExportDirectoryAndDoesNotReplaceFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let exports = home.appendingPathComponent("Exports", isDirectory: true)
        let result = try CVExporter.save(typst: "first", name: "CV Démo.typ", directory: exports)
        XCTAssertEqual(result.lastPathComponent, "CV Démo.typ")
        XCTAssertThrowsError(try CVExporter.save(typst: "other", name: "CV Démo", directory: exports))
        XCTAssertThrowsError(try CVExporter.save(typst: "other", name: "../outside.typ", directory: exports))
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "first")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: result.path)[.posixPermissions] as? Int, 0o600)

        let alias = home.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: exports)
        XCTAssertThrowsError(try CVExporter.save(typst: "other", name: "Elsewhere", directory: alias))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.appendingPathComponent("Elsewhere.typ").path))
    }

    private func fact(
        _ id: String, _ category: FactCategory, _ text: String,
        status: FactStatus = .verified, sourceID: String = "source-1", evidence: String? = nil, page: Int = 1
    ) -> CVFact {
        CVFact(id: id, sourceID: sourceID, page: page, category: category, text: text, evidence: evidence ?? text, status: status)
    }
}
