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

        XCTAssertTrue(source.contains(#"#list.item("Swift [UI] #include(\"private.typ\") \\ é")"#))
        XCTAssertTrue(source.contains(#"#cv-subtitle("Platform developer")"#))
        let skills = try XCTUnwrap(source.range(of: "#cv-section(\"Ce que je sais faire\")"))
        let projects = try XCTUnwrap(source.range(of: "#cv-section(\"Projects\")"))
        XCTAssertLessThan(skills.lowerBound, projects.lowerBound)
        XCTAssertLessThan(try XCTUnwrap(source.range(of: "Second project")).lowerBound,
                          try XCTUnwrap(source.range(of: "First project")).lowerBound)
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
        status: FactStatus = .verified, sourceID: String = "source-1"
    ) -> CVFact {
        CVFact(id: id, sourceID: sourceID, page: 1, category: category, text: text, evidence: text, status: status)
    }
}
