import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import CVVaultCore

final class KnowledgeBaseTests: XCTestCase {
    func testImportPreservesOriginalEvidenceAndLinksThroughReviewAndDeletion() throws {
        try withTemporaryDirectory { folder in
            let databaseURL = folder.appendingPathComponent("private/knowledge.sqlite3")
            let knowledge = try KnowledgeBase(databaseURL: databaseURL)
            let pdf = folder.appendingPathComponent("sample.pdf")
            try makePDF(at: pdf, pages: [.text([
                "Lina Example", "lina@example.test", "Expériences professionnelles",
                "Ingénierie chez Atelier Exemple, 2023–2025", "• Livré un service à 100%",
                "Compétences : Swift et SQLite", "Bénévolat", "Atelier d'écriture"
            ])])
            let document = try XCTUnwrap(PDFDocument(url: pdf))
            let page = try XCTUnwrap(document.page(at: 0))
            let link = PDFAnnotation(bounds: CGRect(x: 70, y: 690, width: 200, height: 24), forType: .link, withProperties: nil)
            link.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.test/portfolio")))
            page.addAnnotation(link)
            XCTAssertTrue(document.write(to: pdf))

            let result = try knowledge.importPDF(at: pdf)
            XCTAssertFalse(result.isDuplicate)
            XCTAssertEqual(result.source.sha256.count, 64)
            XCTAssertEqual(result.source.pageCount, 1)
            XCTAssertEqual(result.source.unreadablePageCount, 0)
            XCTAssertEqual(result.source.pendingFactCount, result.source.factCount)
            XCTAssertEqual(try knowledge.originalPDF(sourceID: result.source.id), try Data(contentsOf: pdf))
            XCTAssertEqual(try knowledge.pages(sourceID: result.source.id).first?.links, ["https://example.test/portfolio"])
            XCTAssertEqual(try knowledge.pages(sourceID: result.source.id).first?.method, .text)
            XCTAssertTrue(try XCTUnwrap(knowledge.pages(sourceID: result.source.id).first).text.contains("Bénévolat"))

            let unrecognized = try XCTUnwrap(knowledge.searchFacts(query: "atelier d'ecriture").first)
            XCTAssertEqual(unrecognized.category, .other)
            let role = try XCTUnwrap(knowledge.searchFacts(query: "INGENIERIE exemple", category: .experience).first)
            XCTAssertEqual(role.status, .pending)
            XCTAssertEqual(role.page, 1)
            XCTAssertTrue(role.evidence.contains("Ingénierie"))
            XCTAssertEqual(try knowledge.searchFacts(category: .skills).first?.text, "Swift et SQLite")
            XCTAssertEqual(try knowledge.searchFacts(query: "%").count, 1)
            XCTAssertEqual(try knowledge.searchFacts(query: "_").count, 0)
            XCTAssertEqual(try knowledge.searchFacts(query: "example.test/portfolio", category: .contact).first?.page, 1)

            let reviewed = try knowledge.updateFact(
                id: role.id, text: "Ingénierie logicielle à Atelier Exemple", category: .experience, status: .verified
            )
            XCTAssertEqual(reviewed.evidence, role.evidence)
            XCTAssertEqual(try knowledge.searchFacts(query: "logicielle", status: .verified), [reviewed])
            XCTAssertEqual(try knowledge.source(id: result.source.id)?.verifiedFactCount, 1)
            XCTAssertEqual(try knowledge.facts(ids: [reviewed.id, "missing", unrecognized.id]), [reviewed, unrecognized])

            let renamed = folder.appendingPathComponent("renamed.pdf")
            try FileManager.default.copyItem(at: pdf, to: renamed)
            let duplicate = try knowledge.importPDF(at: renamed)
            XCTAssertTrue(duplicate.isDuplicate)
            XCTAssertEqual(duplicate.source.id, result.source.id)
            XCTAssertEqual(duplicate.source.name, "sample.pdf")
            XCTAssertEqual(try knowledge.listSources().count, 1)
            XCTAssertTrue(try knowledge.listSources(limit: 1, offset: 1).isEmpty)

            let rejected = try knowledge.updateFact(
                id: unrecognized.id, text: unrecognized.text, category: .other, status: .rejected
            )
            XCTAssertEqual(try knowledge.verifyPendingFacts(sourceID: result.source.id), result.source.factCount - 2)
            XCTAssertEqual(try knowledge.verifyPendingFacts(sourceID: result.source.id), 0)
            XCTAssertEqual(try knowledge.source(id: result.source.id)?.pendingFactCount, 0)
            XCTAssertEqual(try knowledge.searchFacts(status: .rejected), [rejected])

            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: databaseURL.deletingLastPathComponent().path)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
            XCTAssertEqual(directoryAttributes[.posixPermissions] as? Int, 0o700)
            XCTAssertEqual(fileAttributes[.posixPermissions] as? Int, 0o600)

            let reopened = try KnowledgeBase(databaseURL: databaseURL)
            XCTAssertEqual(try reopened.fact(id: role.id), reviewed)
            try reopened.deleteSource(id: result.source.id)
            XCTAssertTrue(try knowledge.listSources().isEmpty)
            XCTAssertTrue(try knowledge.pages(sourceID: result.source.id).isEmpty)
            XCTAssertTrue(try knowledge.searchFacts().isEmpty)
            XCTAssertNil(try knowledge.originalPDF(sourceID: result.source.id))
        }
    }

    func testOCRAndUnreadablePageKeepIndependentProvenance() throws {
        try withTemporaryDirectory { folder in
            let knowledge = try KnowledgeBase(databaseURL: folder.appendingPathComponent("knowledge.sqlite3"))
            let pdf = folder.appendingPathComponent("mixed.pdf")
            try makePDF(at: pdf, pages: [.text(["Lina Example"]), .image, .blank])

            let result = try knowledge.importPDF(at: pdf)
            XCTAssertEqual(result.source.pageCount, 3)
            XCTAssertEqual(result.source.unreadablePageCount, 1)
            let pages = try knowledge.pages(sourceID: result.source.id)
            XCTAssertEqual(pages.map(\.method), [.text, .ocr, .unreadable])
            let scan = try XCTUnwrap(knowledge.searchFacts(query: "SYNTHETIC RESUME").first)
            XCTAssertEqual(scan.page, 2)
            XCTAssertEqual(scan.evidence, "SYNTHETIC RESUME")
            XCTAssertEqual(try knowledge.pages(sourceID: result.source.id, startPage: 2, limit: 1), [pages[1]])
        }
    }

    func testFrenchCVResolvesLocalColumnsAndKeepsWrappedEvidenceWithItsBullet() throws {
        try withTemporaryDirectory { folder in
            let knowledge = try KnowledgeBase(databaseURL: folder.appendingPathComponent("knowledge.sqlite3"))
            let file = folder.appendingPathComponent("columns.pdf")
            try makePDF(at: file, pages: [.positioned([
                ("Camille Exemple", 64, 746, 18),
                ("camille@example.invalid", 64, 727, 10),
                ("Ingénieure logicielle avec une expérience en livraison de produits.", 64, 708, 11),
                ("EXPÉRIENCE PROFESSIONNELLE", 64, 682, 12),
                ("Ingénieure plateforme", 64, 659, 11),
                ("2020 – 2024", 456, 659, 10),
                ("Studio Exemple", 64, 644, 10),
                ("• Déployé un service régional", 64, 625, 10),
                ("• Réduit de 30 % le délai", 330, 625, 10),
                ("pour trois équipes internes.", 77, 613, 10),
                ("de traitement.", 343, 613, 10),
                ("• Documenté les interfaces", 64, 599, 10),
                ("• Formé deux équipes", 330, 599, 10),
                ("FORMATION & RECHERCHE", 64, 568, 12),
                ("Master en informatique", 64, 546, 11),
                ("2019", 498, 546, 10),
                ("Institut Exemple", 64, 531, 10),
                ("• Étudié les systèmes répartis", 64, 512, 10),
                ("• Analysé un jeu de données", 330, 512, 10),
                ("COMPÉTENCES", 64, 473, 12),
                ("PROJETS", 330, 473, 12),
                ("SQL : PostgreSQL", 64, 454, 10),
                ("Observatoire local :", 330, 454, 10),
                ("suivi des flux régionaux.", 330, 442, 10),
                ("Langues  français et anglais", 64, 425, 10)
            ])])
            let document = try XCTUnwrap(PDFDocument(url: file))
            let page = try XCTUnwrap(document.page(at: 0))
            let annotation = PDFAnnotation(bounds: CGRect(x: 330, y: 451, width: 88, height: 13),
                                           forType: .link, withProperties: nil)
            annotation.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.invalid/observatory")))
            page.addAnnotation(annotation)
            XCTAssertTrue(document.write(to: file))
            let result = try knowledge.importPDF(at: file)
            let id = result.source.id
            let facts = try knowledge.searchFacts(sourceID: id)

            let first = try XCTUnwrap(facts.first { $0.text.contains("Déployé") })
            let second = try XCTUnwrap(facts.first { $0.text.contains("Réduit") })
            XCTAssertEqual(first.category, .experience)
            XCTAssertEqual(second.category, .experience)
            XCTAssertTrue(first.text.contains("pour trois équipes internes."))
            XCTAssertTrue(second.text.contains("de traitement."))
            XCTAssertTrue(first.evidence.contains("Déployé"))
            XCTAssertTrue(first.evidence.contains("pour trois équipes internes."))
            XCTAssertFalse(first.evidence.contains("Réduit"))
            XCTAssertFalse(second.evidence.contains("pour trois équipes internes."))
            XCTAssertTrue(facts.contains { $0.category == .education && $0.text.contains("Master") })
            XCTAssertTrue(facts.contains { $0.category == .education && $0.text.contains("systèmes répartis") })
            XCTAssertTrue(facts.contains { $0.category == .languages && $0.text.contains("anglais") })
            XCTAssertTrue(facts.contains { $0.category == .summary && $0.text.contains("livraison de produits") })
            XCTAssertTrue(facts.contains { $0.category == .projects && $0.text.contains("flux régionaux") })
            XCTAssertFalse(facts.contains { $0.category == .contact && $0.text.contains("observatory") })
            XCTAssertTrue(try XCTUnwrap(knowledge.pages(sourceID: id).first).links
                .contains("https://example.invalid/observatory"))
            XCTAssertTrue(facts.allSatisfy { $0.page == 1 && $0.status == .pending })
        }
    }

    func testConcurrentImportsDeduplicateAcrossConnections() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("concurrent.pdf")
        try makePDF(at: pdf, pages: [.text(["Lina Example"])])
        let path = folder.appendingPathComponent("knowledge.sqlite3")
        let first = try KnowledgeBase(databaseURL: path)
        let second = try KnowledgeBase(databaseURL: path)

        async let resultA = first.importPDF(at: pdf)
        async let resultB = second.importPDF(at: pdf)
        let results = try await [resultA, resultB]
        XCTAssertEqual(results.filter(\.isDuplicate).count, 1)
        XCTAssertEqual(Set(results.map(\.source.id)).count, 1)
        XCTAssertEqual(try first.listSources().count, 1)
    }

    func testOriginalStyleReusesSourceLinkLabelsAndKeepsProjectArrowClickable() throws {
        try withTemporaryDirectory { folder in
            let file = folder.appendingPathComponent("links.pdf")
            try makePDF(at: file, pages: [.text(["Camille Exemple", "Portfolio", "Projets", "Observatoire local"])])
            let document = try XCTUnwrap(PDFDocument(url: file))
            let page = try XCTUnwrap(document.page(at: 0))
            let profile = "https://example.invalid/portfolio"
            let project = "https://example.invalid/observatoire"
            let link = PDFAnnotation(bounds: CGRect(x: 63, y: 694, width: 100, height: 25), forType: .link, withProperties: nil)
            link.action = PDFActionURL(url: try XCTUnwrap(URL(string: profile)))
            page.addAnnotation(link)
            XCTAssertTrue(document.write(to: file))
            let style = try CVSourceStyle.analyze(pdf: Data(contentsOf: file))
            XCTAssertEqual(style.linkLabels[profile], "Portfolio")

            let facts: [CVFact] = [
                ("Camille Exemple", FactCategory.identity),
                (profile, .contact),
                ("Observatoire ↗ · Analyse des flux", .projects),
                (project, .projects)
            ].map { text, category in
                CVFact(id: UUID().uuidString, sourceID: "links", page: 1, category: category,
                       text: text, evidence: text, status: .verified)
            }
            let original = try CVExporter.generate(facts: facts, template: .source, sourceStyle: style)
            XCTAssertTrue(original.contains(#"("Portfolio", "https://example.invalid/portfolio")"#))
            XCTAssertTrue(original.contains(#"#cv-project-link("Observatoire ", " · Analyse des flux", "https://example.invalid/observatoire")"#))
            XCTAssertFalse(original.contains("#cv-project-url(" + CVLayout.literal(project)))

            let preset = try CVExporter.generate(facts: facts, template: .editorial, sourceStyle: style)
            XCTAssertTrue(preset.contains(#"("https://example.invalid/portfolio", "https://example.invalid/portfolio")"#))
            XCTAssertTrue(preset.contains("#list.item(" + CVLayout.literal(project)))
        }
    }

    private enum FixturePage {
        case text([String])
        case positioned([(text: String, x: CGFloat, y: CGFloat, size: CGFloat)])
        case image
        case blank
    }

    private func makePDF(at url: URL, pages: [FixturePage]) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        for page in pages {
            pdf.beginPDFPage(nil)
            switch page {
            case .text(let lines):
                for (offset, line) in lines.enumerated() {
                    draw(line, on: pdf, size: 18, x: 64, y: 730 - CGFloat(offset * 30))
                }
            case .positioned(let lines):
                for line in lines {
                    draw(line.text, on: pdf, size: line.size, x: line.x, y: line.y)
                }
            case .image:
                let raster = try XCTUnwrap(CGContext(
                    data: nil, width: 1224, height: 1584, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ))
                raster.setFillColor(gray: 1, alpha: 1)
                raster.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584))
                draw("SYNTHETIC RESUME", on: raster, size: 72, x: 122, y: 1360)
                pdf.draw(try XCTUnwrap(raster.makeImage()), in: mediaBox)
            case .blank: break
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    private func draw(_ text: String, on context: CGContext, size: CGFloat, x: CGFloat, y: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder)
    }
}
