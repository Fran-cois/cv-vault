import Foundation
import PDFKit

struct LocatedLink {
    let url: String
    let bounds: CGRect
}

struct LocatedText {
    let text: String
    let bounds: CGRect
    var firstLetterX: CGFloat? = nil

    var x: CGFloat { bounds.minX }
    var y: CGFloat { bounds.midY }
}

struct PositionedPDFText {
    let rows: [[LocatedText]]
    let width: CGFloat

    static func rows(on page: PDFPage, text: String) -> Self? {
        // PDFKit inserts line breaks in page.string, but its glyph coordinates skip them.
        // Restrict geometry to pages for which the glyph stream agrees with the text.
        guard page.rotation == 0, text.utf16.count <= 80_000 else { return nil }
        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }
        let glyphArea = pageBounds.insetBy(dx: -3, dy: -3)
        var cursor = 0
        var unresolved = 0
        var glyphs = 0
        var spans: [LocatedText] = []
        for row in text.split(whereSeparator: \.isNewline) {
            var buffer = ""
            var envelope = CGRect.null
            var preceding = CGRect.null
            var center: CGFloat?
            var firstLetterX: CGFloat?

            func flush() {
                let content = buffer.trimmingCharacters(in: .whitespaces)
                if !content.isEmpty, !envelope.isNull {
                    spans.append(LocatedText(text: content, bounds: envelope, firstLetterX: firstLetterX))
                }
                buffer = ""
                envelope = .null
                preceding = .null
                center = nil
                firstLetterX = nil
            }

            for character in row {
                let index = cursor
                cursor += character.utf16.count
                if character.isWhitespace {
                    buffer.append(character)
                    continue
                }
                glyphs += 1
                let bounds = page.characterBounds(at: index)
                let valid = !bounds.isNull && !bounds.isInfinite && bounds.width > 0
                    && bounds.height > 0 && glyphArea.contains(bounds)
                guard valid else {
                    unresolved += 1
                    buffer.append(character)
                    continue
                }

                if !preceding.isNull {
                    let threshold = max(3, min(5, max(bounds.height, preceding.height) * 0.41))
                    let newBaseline = (character.isLetter || character.isNumber)
                        && center.map { abs(bounds.midY - $0) > threshold } == true
                    let movedLeft = preceding.minX - bounds.minX > max(5, preceding.width)
                    let largeGap = bounds.minX - preceding.maxX > max(12, preceding.height * 1.6)
                    if newBaseline || movedLeft || largeGap || CVFactParser.isBulletGlyph(character) {
                        flush()
                    }
                }
                buffer.append(character)
                envelope = envelope.union(bounds)
                preceding = bounds
                if character.isLetter || character.isNumber {
                    if firstLetterX == nil { firstLetterX = bounds.minX }
                    center = center.map { ($0 * 3 + bounds.midY) / 4 } ?? bounds.midY
                }
            }
            flush()
        }

        // With doubtful coordinates, let the plain text parser retain the original reading order.
        guard glyphs > 0, unresolved <= max(2, glyphs / 20), !spans.isEmpty else { return nil }
        var rows: [[LocatedText]] = []
        var baseline: CGFloat?
        for span in spans.sorted(by: { $0.y == $1.y ? $0.x < $1.x : $0.y > $1.y }) {
            let tolerance = max(2.8, min(4.0, span.bounds.height * 0.3))
            if let previous = baseline, abs(span.y - previous) <= tolerance {
                rows[rows.count - 1].append(span)
            } else {
                rows.append([span])
                baseline = span.y
            }
        }
        return Self(rows: rows.map { $0.sorted { $0.x < $1.x } }, width: pageBounds.width)
    }
}
