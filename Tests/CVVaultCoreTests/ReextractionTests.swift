import CoreGraphics
import CoreText
import SQLite3
import XCTest
@testable import CVVaultCore

final class ReextractionTests: XCTestCase {
    func testReextractionRetainsLegacyEditsAndReviewsAcrossRepeatedRuns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let path = folder.appendingPathComponent("knowledge.sqlite3")
        let original = try KnowledgeBase(databaseURL: path)
        let pdf = folder.appendingPathComponent("synthetic.pdf")
        try writePDF(
            ["Lina Exemple", "Expérience", "Analyste logiciel chez Atelier Exemple.",
             "Formation", "Diplôme de sciences", "Compétences", "Swift et SQLite"],
            to: pdf
        )
        let sourceID = try original.importPDF(at: pdf).source.id
        let imported = try XCTUnwrap(original.source(id: sourceID))
        let identity = try XCTUnwrap(original.searchFacts(category: .identity).first)
        let experience = try XCTUnwrap(original.searchFacts(category: .experience).first)
        let skill = try XCTUnwrap(original.searchFacts(category: .skills).first)
        let education = try XCTUnwrap(original.searchFacts(category: .education).first)
        let bytes = try Data(contentsOf: pdf)

        // Recreate the legacy schema, then exercise edits and reviews made before this upgrade.
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &connection), SQLITE_OK)
        do {
            defer { sqlite3_close(connection) }
            XCTAssertEqual(sqlite3_exec(connection, """
                DROP TRIGGER facts_mark_user_edit;
                ALTER TABLE facts DROP COLUMN user_edited;
                PRAGMA user_version = 1;
                """, nil, nil, nil), SQLITE_OK)
        }
        let pendingEdit = try original.updateFact(
            id: experience.id, text: experience.text, category: .projects, status: .pending
        )
        let verified = try original.updateFact(
            id: education.id, text: "Diplôme scientifique", category: .education, status: .verified
        )
        let rejected = try original.updateFact(
            id: skill.id, text: skill.text, category: .skills, status: .rejected
        )

        let upgraded = try KnowledgeBase(databaseURL: path)
        for _ in 0..<2 {
            let result = try upgraded.reextractPDF(sourceID: imported.id)
            XCTAssertEqual(result.source.importedAt, imported.importedAt)
            XCTAssertEqual(result.source.sha256, imported.sha256)
            XCTAssertEqual(result.previousFactCount, imported.factCount)
            XCTAssertEqual(result.preservedFactCount, imported.factCount)
            XCTAssertEqual(result.addedFactCount, 0)
            XCTAssertEqual(result.removedFactCount, 0)
            XCTAssertEqual(result.reviewedOrEditedFactCount, 3)
            XCTAssertEqual(try upgraded.facts(ids: [identity.id, experience.id, education.id, skill.id]),
                           [identity, pendingEdit, verified, rejected])
            XCTAssertEqual(try upgraded.originalPDF(sourceID: imported.id), bytes)
        }
        let newEdit = try upgraded.updateFact(
            id: identity.id, text: "Lina Dupont", category: .identity, status: .pending
        )
        XCTAssertEqual(try upgraded.reextractPDF(sourceID: imported.id).reviewedOrEditedFactCount, 4)
        XCTAssertEqual(try upgraded.fact(id: identity.id), newEdit)
        XCTAssertEqual(try upgraded.importPDF(at: pdf).source.id, imported.id)
        XCTAssertEqual(try upgraded.listSources().count, 1)
    }

    func testReconciliationPreservesARejectedFragmentAndItsNeighbors() {
        let kept = storedFact(id: "kept", page: 1, text: "A livré une application")
        let rejected = storedFact(id: "rejected", page: 1, text: "avec un résultat non confirmé", status: .rejected)
        let oldScan = storedFact(id: "scan", page: 2, text: "Bilan annuel")
        let standalone = storedFact(id: "standalone", page: 1, text: "Documentation rédigée")
        let mergedEvidence = "A livré une application\navec un résultat non confirmé"
        let mergedParagraph = storedFact(id: "new-paragraph", page: 1, text: mergedEvidence)
        let newDetail = storedFact(id: "new-detail", page: 1, text: "Rapport de maintenance")

        let result = FactReextraction.merge(
            existing: [kept, rejected, standalone, oldScan],
            extracted: [mergedParagraph, newDetail, standalone].map(\.fact),
            usingPreviousPages: [2]
        )

        XCTAssertEqual(result.map(\.fact), [kept, rejected, newDetail, standalone, oldScan].map(\.fact))
    }

    private func storedFact(id: String, page: Int, text: String, status: FactStatus = .pending) -> StoredFact {
        StoredFact(fact: CVFact(
            id: id, sourceID: "synthetic", page: page, category: .experience,
            text: text, evidence: text, status: status
        ), userEdited: false)
    }

    private func writePDF(_ lines: [String], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        context.beginPDFPage(nil)
        for (index, line) in lines.enumerated() {
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let text = NSAttributedString(string: line, attributes: attributes)
            context.textPosition = CGPoint(x: 64, y: 730 - CGFloat(index * 38))
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        context.endPDFPage()
        context.closePDF()
    }
}
