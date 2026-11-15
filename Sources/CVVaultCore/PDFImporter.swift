import CoreGraphics
import Foundation
import PDFKit
import Vision

enum PDFImporter {
    static func read(at url: URL) throws -> Data {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw KnowledgeBaseError.invalidPDF
        }

        let limit = 50 * 1024 * 1024
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var data = Data()
        while let chunk = try file.read(upToCount: min(1024 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw KnowledgeBaseError.fileTooLarge }
        }
        return data
    }

    static func extract(from data: Data, sourceID: String) throws -> (pages: [CVPage], facts: [CVFact]) {
        guard let document = PDFDocument(data: data) else { throw KnowledgeBaseError.invalidPDF }
        guard !document.isLocked else { throw KnowledgeBaseError.lockedPDF }
        guard document.pageCount > 0 else { throw KnowledgeBaseError.invalidPDF }
        guard document.pageCount <= 100 else { throw KnowledgeBaseError.tooManyPages }

        var pages: [CVPage] = []
        var parser = CVFactParser()
        for index in 0..<document.pageCount {
            autoreleasepool {
                let number = index + 1
                guard let pdfPage = document.page(at: index) else {
                    pages.append(CVPage(sourceID: sourceID, number: number, text: "", links: [], method: .unreadable))
                    return
                }

                let annotations = pdfPage.annotations.compactMap { annotation -> LocatedLink? in
                    guard let url = (annotation.action as? PDFActionURL)?.url else { return nil }
                    return LocatedLink(url: url.absoluteString, bounds: annotation.bounds)
                }
                var seenLinks = Set<String>()
                let links = annotations.map(\.url).filter { seenLinks.insert($0).inserted }
                let nativeText = pdfPage.string ?? ""
                let text: String
                let method: PageMethod
                if nativeText.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                    text = nativeText
                    method = .text
                } else if let ocrText = try? recognizeText(on: pdfPage), !ocrText.isEmpty {
                    text = nativeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? ocrText : nativeText + "\n" + ocrText
                    method = .ocr
                } else {
                    text = nativeText
                    method = .unreadable
                }

                let page = CVPage(sourceID: sourceID, number: number, text: text, links: links, method: method)
                pages.append(page)
                let rows = method == .text ? PositionedPDFText.rows(on: pdfPage, text: nativeText) : nil
                parser.addPage(page, rows: rows, annotations: annotations)
            }
        }
        return (pages, parser.facts)
    }

    private static func recognizeText(on page: PDFPage) throws -> String {
        guard let reference = page.pageRef else { return "" }
        let bounds = reference.getBoxRect(.cropBox)
        let rotated = abs(reference.rotationAngle % 180) == 90
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let longestSide = max(size.width, size.height)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return "" }

        let width = max(1, Int(ceil(size.width / longestSide * 2200)))
        let height = max(1, Int(ceil(size.height / longestSide * 2200)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return "" }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "fr-FR"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

}
