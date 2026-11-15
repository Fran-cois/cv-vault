import AppKit
import Foundation
import PDFKit

public enum CVSourceStyleError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        "The PDF has no measurable text style. Choose another CV style for a scanned or unreadable source."
    }
}

public struct CVSourceTextStyle: Sendable, Equatable, Hashable {
    public let fontFamily: String
    public let size: Double
    /// The foreground color in sRGB, without a leading #.
    public let color: String
    public let weight: String
    public let italic: Bool
    public var bold: Bool { weight != "regular" }
}

/// Measured style of a text-based PDF. Geometry and type sizes are in points.
public struct CVSourceStyle: Sendable, Equatable {
    public let pageWidth: Double
    public let pageHeight: Double
    public let marginLeft: Double
    public let marginRight: Double
    public let marginTop: Double
    public let marginBottom: Double
    public let body: CVSourceTextStyle
    public let name: CVSourceTextStyle
    public let subtitle: CVSourceTextStyle
    public let heading: CVSourceTextStyle
    public let role: CVSourceTextStyle
    public let metadata: CVSourceTextStyle
    public let date: CVSourceTextStyle
    public let contact: CVSourceTextStyle
    public let summary: CVSourceTextStyle
    public let bodyLineHeight: Double
    public let headerCentered: Bool
    public let sectionFill: String?
    public let sectionRule: Bool
    public let ruleColor: String?
    public let sectionTitles: [FactCategory: String]
    public let linkLabels: [String: String]
    public let bulletColumns: Int
    /// Share of the lower region occupied by its left column when two headings align.
    public let sidebarRatio: Double?

    public static func analyze(pdf: Data) throws -> CVSourceStyle {
        guard let document = PDFDocument(data: pdf), !document.isLocked else {
            throw CVSourceStyleError.unavailable
        }
        for index in 0..<min(document.pageCount, 5) {
            if let result = autoreleasepool(invoking: {
                document.page(at: index).flatMap(analyze(page:))
            }) {
                return result
            }
        }
        throw CVSourceStyleError.unavailable
    }
}

private extension CVSourceStyle {
    struct Glyph {
        let style: CVSourceTextStyle
        let bounds: CGRect
        let code: UInt16
    }

    struct Run {
        let text: String
        let bounds: CGRect
        let style: CVSourceTextStyle
        let glyphs: [Glyph]

        var looksLikeContact: Bool {
            text.contains("@") || text.localizedCaseInsensitiveContains("https://")
              || text.localizedCaseInsensitiveContains("www.")
        }

        var looksLikeDate: Bool {
            let count = text.count
            let digits = text.filter(\.isNumber).count
            return (4...26).contains(count) && digits >= 4
                && Double(digits) / Double(count) >= 0.42
        }

        var looksLikeHeading: Bool {
            let letters = text.filter(\.isLetter)
            return sectionCategory != nil
                || (text.count <= 52 && style.bold && letters.count > 2 && letters.allSatisfy(\.isUppercase))
        }

        var isLightHeading: Bool {
            text.count <= 52 && (style.bold || sectionCategory != nil) && RGB(hex: style.color).lightness > 0.87
        }

        var sectionCategory: FactCategory? {
            guard text.count <= 58, !looksLikeContact, !looksLikeDate else { return nil }
            let key = text.normalizedForSearch.trimmingCharacters(in: .punctuationCharacters)
            if let category = Self.exactSectionTitles[key] { return category }
            guard style.bold else { return nil }
            // A bold compound heading can contain several words, such as Formation & recherche.
            let first = key.split(whereSeparator: \.isWhitespace).first.map(String.init)
            return first.flatMap { Self.exactSectionTitles[$0] }
        }

        private static let exactSectionTitles: [String: FactCategory] = [
            "profil": .summary, "summary": .summary, "profile": .summary, "a propos": .summary,
            "formation": .education, "formations": .education, "education": .education,
            "experience": .experience, "experiences": .experience, "experience professionnelle": .experience,
            "experiences professionnelles": .experience, "work experience": .experience,
            "professional experience": .experience, "emploi": .experience,
            "competences": .skills, "skills": .skills, "technical skills": .skills,
            "projects": .projects, "projets": .projects,
            "langues": .languages, "languages": .languages,
            "publications": .publications, "certifications": .certifications,
            "awards": .awards, "distinctions": .awards, "interets": .other, "interests": .other,
        ]
    }

    static func analyze(page: PDFPage) -> CVSourceStyle? {
        let canvas = page.bounds(for: .cropBox)
        guard (180...2000).contains(canvas.width), (180...2000).contains(canvas.height),
              page.rotation == 0, let text = page.attributedString,
              (12...80_000).contains(text.length) else { return nil }
        let runs = measureRuns(on: page, text: text, canvas: canvas)
        guard runs.count >= 2, runs.reduce(0, { $0 + $1.glyphs.count }) >= 12,
              let body = dominantStyle(runs.filter { !$0.isLightHeading }) else { return nil }

        let left = percentile(runs.map { Double($0.bounds.minX - canvas.minX) }, 0.10)
        let right = percentile(runs.map { Double(canvas.maxX - $0.bounds.maxX) }, 0.08)
        let top = canvas.maxY - (runs.map(\.bounds.maxY).max() ?? canvas.maxY)
        let bottom = (runs.map(\.bounds.minY).min() ?? canvas.minY) - canvas.minY
        // A short page may have plenty of empty space below or at the right of its text.
        let leftMargin = boundedMargin(left, dimension: canvas.width)
        let rightMargin = boundedMargin(right, dimension: canvas.width, other: leftMargin)
        let topMargin = boundedMargin(top, dimension: canvas.height)
        let bottomMargin = boundedMargin(bottom, dimension: canvas.height, other: topMargin)

        let header = Array(runs.prefix(6)).filter { $0.bounds.midY > canvas.midY }
        let name = header.filter { !$0.looksLikeContact && !$0.looksLikeDate && !$0.isLightHeading }
            .max { $0.style.size < $1.style.size } ?? runs[0]
        let lowerHeader = header.filter { $0.bounds.midY < name.bounds.midY - 2 }
        let subtitle = lowerHeader.first { !$0.looksLikeContact && !$0.looksLikeDate
            && !$0.looksLikeHeading && !$0.isLightHeading && $0.text.count <= 105 }
        let contacts = lowerHeader.filter(\.looksLikeContact)
        let headingRuns = runs.filter { $0.bounds.midY < name.bounds.midY - 2
            && ($0.isLightHeading || $0.looksLikeHeading) }
        var sectionTitles: [FactCategory: String] = [:]
        for run in headingRuns {
            if let category = run.sectionCategory, sectionTitles[category] == nil {
                sectionTitles[category] = run.text
            }
        }
        let heading = dominantStyle(headingRuns.filter(\.isLightHeading)) ?? dominantStyle(headingRuns) ?? body
        let accents = headingRuns.filter { $0.style == heading }
        let firstHeadingY = headingRuns.first.map(\.bounds.midY) ?? canvas.midY
        let summary = runs.first { $0.bounds.midY < name.bounds.midY - 2 && $0.bounds.midY > firstHeadingY + 2
            && !$0.looksLikeContact && !$0.looksLikeDate && $0.text.count >= 65 }
        let roleRuns = runs.filter { $0.bounds.midY < firstHeadingY
            && !$0.looksLikeHeading && !$0.isLightHeading && !$0.looksLikeDate
            && $0.style.bold && !$0.style.italic && $0.style.size >= body.size - 0.3
            && !$0.glyphs.contains(where: { isBullet($0.code) }) }
        let metadata = dominantStyle(runs.filter {
            $0.bounds.midY < firstHeadingY && $0.style.italic && !$0.looksLikeDate
        }) ?? body
        let dates = runs.filter { $0.looksLikeDate && $0.bounds.midX > canvas.midX }

        let alignmentCenter = Double(canvas.midX) + (leftMargin - rightMargin) / 2
        let headerCentered = abs(Double(name.bounds.midX) - alignmentCenter) < max(8, Double(canvas.width) * 0.055)
        let fillAndRule = decorations(on: page, canvas: canvas, headings: Array(accents.prefix(10)),
                                      left: leftMargin, right: rightMargin)
        let foregroundHeading = RGB(hex: heading.color).lightness > 0.87 && fillAndRule.fill == nil
            ? CVSourceTextStyle(fontFamily: heading.fontFamily, size: heading.size, color: body.color,
                                weight: heading.weight, italic: heading.italic)
            : heading
        let contentWidth = max(1, Double(canvas.width) - leftMargin - rightMargin)
        let footerHeadings = headingRuns.filter { $0.bounds.midY < canvas.minY + canvas.height * 0.47 }
        let sidebar = lowerColumns(in: footerHeadings, left: Double(canvas.minX) + leftMargin, width: contentWidth)
        let columns = alignedBulletColumns(in: runs, left: Double(canvas.minX) + leftMargin, width: contentWidth)

        return CVSourceStyle(
            pageWidth: canvas.width, pageHeight: canvas.height,
            marginLeft: leftMargin, marginRight: rightMargin, marginTop: topMargin, marginBottom: bottomMargin,
            body: body, name: name.style, subtitle: subtitle?.style ?? body, heading: foregroundHeading,
            role: dominantStyle(roleRuns) ?? foregroundHeading, metadata: metadata,
            date: dominantStyle(dates) ?? metadata, contact: dominantStyle(contacts) ?? body,
            summary: summary?.style ?? body,
            bodyLineHeight: inferLineHeight(runs, body: body),
            headerCentered: headerCentered, sectionFill: fillAndRule.fill, sectionRule: fillAndRule.rule != nil,
            ruleColor: fillAndRule.rule, sectionTitles: sectionTitles, linkLabels: measureLinkLabels(on: page),
            bulletColumns: columns, sidebarRatio: sidebar
        )
    }

    static func measureLinkLabels(on page: PDFPage) -> [String: String] {
        var labels: [String: String] = [:]
        for annotation in page.annotations {
            guard let url = (annotation.action as? PDFActionURL)?.url,
                  let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { continue }
            let bounds = annotation.bounds.insetBy(dx: -0.1, dy: -0.5)
            guard let label = page.selection(for: bounds)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty, label.count <= 120, !label.contains(where: \.isNewline),
                  label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { continue }
            labels[url.absoluteString] = labels[url.absoluteString] ?? label
        }
        return labels
    }

    static func measureRuns(on page: PDFPage, text: NSAttributedString, canvas: CGRect) -> [Run] {
        let characters = text.string as NSString
        let accepted = canvas.insetBy(dx: -2, dy: -2)
        var runs: [Run] = []
        var glyphs: [Glyph] = []
        var start: Int?
        var end = 0
        var acceptedRange = NSRange(location: 0, length: 0)
        var activeStyle: CVSourceTextStyle?
        var offset = 0

        func flush() {
            defer {
                glyphs.removeAll(keepingCapacity: true)
                start = nil
            }
            guard let start, end > start else { return }
            let words = characters.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard words.contains(where: { $0.isLetter || $0.isNumber }),
                  let mainStyle = dominantStyle(glyphs) else { return }
            let bounds = glyphs.reduce(CGRect.null) { $0.union($1.bounds) }
            runs.append(Run(text: words, bounds: bounds, style: mainStyle, glyphs: glyphs))
        }

        for index in 0..<characters.length {
            let code = characters.character(at: index)
            if [10, 13, 0x2028, 0x2029].contains(code) {
                flush()
                continue
            }
            let position = offset
            offset += 1
            guard ![9, 32, 160, 0x202F].contains(code) else { continue }
            if !NSLocationInRange(index, acceptedRange) {
                activeStyle = textStyle(text.attributes(at: index, effectiveRange: &acceptedRange))
            }
            guard let style = activeStyle else { continue }
            let bounds = page.characterBounds(at: position)
            guard bounds.width > 0, bounds.height > 0, accepted.contains(bounds),
                  bounds.width < canvas.width * 0.22 else { continue }
            if let previous = glyphs.last {
                let gap = bounds.minX - previous.bounds.maxX
                let backward = previous.bounds.minX - bounds.minX
                if gap > max(13, style.size * 1.6) || backward > max(8, previous.bounds.width) {
                    flush()
                }
            }
            start = start ?? index
            end = index + 1
            glyphs.append(Glyph(style: style, bounds: bounds, code: code))
        }
        flush()
        return runs.sorted {
            let first = ($0.bounds.midY / 2).rounded()
            let second = ($1.bounds.midY / 2).rounded()
            if first == second { return $0.bounds.minX < $1.bounds.minX }
            return first > second
        }
    }

    static func textStyle(_ attributes: [NSAttributedString.Key: Any]) -> CVSourceTextStyle? {
        guard let font = attributes[.font] as? NSFont, (4...120).contains(font.pointSize) else { return nil }
        let family = font.familyName ?? font.fontName
        let rawName = font.fontName.lowercased()
        let traits = font.fontDescriptor.symbolicTraits
        let weight: String
        if rawName.contains("semibold") || rawName.contains("demibold") || rawName.contains("medium") {
            weight = "semibold"
        } else if traits.contains(.bold) || rawName.contains("bold") ||
                    rawName.contains("heavy") || rawName.hasSuffix("black") {
            weight = "bold"
        } else {
            weight = "regular"
        }
        let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB)
        let rgb = color.map { RGB(r: $0.redComponent, g: $0.greenComponent, b: $0.blueComponent) }
        return CVSourceTextStyle(
            fontFamily: family, size: (font.pointSize * 100).rounded() / 100,
            color: rgb?.hex ?? "1E1E1E", weight: weight,
            italic: traits.contains(.italic) || rawName.contains("italic") || rawName.contains("oblique")
        )
    }

    static func dominantStyle(_ runs: [Run]) -> CVSourceTextStyle? {
        dominantStyle(runs.flatMap(\.glyphs))
    }

    static func dominantStyle(_ glyphs: [Glyph]) -> CVSourceTextStyle? {
        let counts = glyphs.reduce(into: [CVSourceTextStyle: Int]()) { $0[$1.style, default: 0] += 1 }
        var best: (style: CVSourceTextStyle, count: Int)?
        for glyph in glyphs {
            let amount = counts[glyph.style, default: 0]
            if amount > (best?.count ?? 0) { best = (glyph.style, amount) }
        }
        return best?.style
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let ordered = values.sorted()
        guard !ordered.isEmpty else { return 0 }
        return ordered[Int(Double(ordered.count - 1) * fraction)]
    }

    static func boundedMargin(_ distance: Double, dimension: Double, other: Double? = nil) -> Double {
        let limit = other.map { max(25, $0 * 2.5) } ?? dimension * 0.14
        if distance > limit, let other { return other }
        return min(limit, max(4, distance))
    }

    static func inferLineHeight(_ runs: [Run], body: CVSourceTextStyle) -> Double {
        let positions = runs.filter { $0.style == body && $0.text.count >= 8 }.map { Double($0.bounds.midY) }
            .sorted(by: >)
        let steps = zip(positions, positions.dropFirst()).map { $0 - $1 }
            .filter { (body.size * 0.80...body.size * 1.75).contains($0) }
        if steps.count >= 3 { return percentile(steps, 0.5) }
        return body.size * 1.18
    }

    static func isBullet(_ code: UInt16) -> Bool {
        [0x2022, 0x25CF, 0x25E6, 0x25AA, 0x25A0, 0x25B8, 0x2023].contains(code)
    }

    static func alignedBulletColumns(in runs: [Run], left: Double, width: Double) -> Int {
        let bullets = runs.flatMap { run -> [CGPoint] in
            run.glyphs.enumerated().compactMap { index, glyph in
                guard isBullet(glyph.code) else { return nil }
                let next = run.glyphs.dropFirst(index + 1).first
                let x = next.map { $0.bounds.minX - 5 } ?? glyph.bounds.minX
                return CGPoint(x: x, y: glyph.bounds.midY)
            }
        }
        let first = bullets.filter { (left - 8...left + width * 0.15).contains($0.x) }
        let second = bullets.filter { (left + width * 0.37...left + width * 0.68).contains($0.x) }
        let matches = first.filter { point in
            second.contains { abs($0.y - point.y) <= 4 }
        }
        return matches.count >= 2 ? 2 : 1
    }

    static func lowerColumns(in headings: [Run], left: Double, width: Double) -> Double? {
        for first in headings where first.bounds.minX < left + width * 0.20 {
            if let right = headings.first(where: {
                abs($0.bounds.midY - first.bounds.midY) < max(4, first.style.size * 0.60)
                    && (left + width * 0.30...left + width * 0.72).contains($0.bounds.minX)
            }) {
                return min(0.70, max(0.30, (right.bounds.minX - first.bounds.minX) / width))
            }
        }
        return nil
    }

    struct RGB: Hashable {
        let r: Int
        let g: Int
        let b: Int

        init(r: CGFloat, g: CGFloat, b: CGFloat) {
            self.r = Int((min(1, max(0, r)) * 255).rounded())
            self.g = Int((min(1, max(0, g)) * 255).rounded())
            self.b = Int((min(1, max(0, b)) * 255).rounded())
        }

        init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
            self.r = Int(r); self.g = Int(g); self.b = Int(b)
        }

        init(hex: String) {
            let value = Int(hex, radix: 16) ?? 0
            r = value >> 16 & 255
            g = value >> 8 & 255
            b = value & 255
        }

        var hex: String { String(format: "%02X%02X%02X", r, g, b) }
        var lightness: Double { (Double(r) * 0.213 + Double(g) * 0.715 + Double(b) * 0.072) / 255 }
        var isPaper: Bool { min(r, g, b) >= 248 }
    }

    static func decorations(
        on page: PDFPage, canvas: CGRect, headings: [Run], left: Double, right: Double
    ) -> (fill: String?, rule: String?) {
        guard !headings.isEmpty, let pdf = page.pageRef,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return (nil, nil) }
        let scale = min(1.4, 1024 / max(canvas.width, canvas.height))
        let width = Int(ceil(canvas.width * scale))
        let height = Int(ceil(canvas.height * scale))
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let transform = pdf.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.concatenate(transform)
            context.drawPDFPage(pdf)
            return true
        }
        guard rendered else { return (nil, nil) }

        func pixel(_ x: Double, _ y: Double) -> RGB {
            let point = CGPoint(x: x, y: y).applying(transform)
            let column = Int(point.x.rounded(.down))
            let row = height - 1 - Int(point.y.rounded(.down))
            guard (0..<width).contains(column), (0..<height).contains(row) else { return RGB(255, 255, 255) }
            let index = (row * width + column) * 4
            return RGB(pixels[index], pixels[index + 1], pixels[index + 2])
        }

        var fills: [RGB] = []
        var rules: [RGB] = []
        for heading in headings {
            let box = heading.bounds
            var samples: [RGB] = []
            for x in stride(from: Double(box.minX), to: Double(box.maxX), by: 1.7) {
                for y in [box.minY + 0.2, box.midY, box.maxY - 0.2] {
                    samples.append(pixel(x, y))
                }
            }
            // Light labels are antialiased over the band. Remove the light fringes so
            // their many identical edge pixels cannot outweigh the solid paint.
            let bandColors = heading.isLightHeading ? samples.filter { $0.lightness < 0.68 } : samples
            if bandColors.count * 5 >= samples.count,
               let mode = commonColor(bandColors, minimumShare: heading.isLightHeading ? 0.22 : 0.48) {
                fills.append(mode)
                continue
            }
            let first = Double(canvas.minX) + left
            let last = Double(canvas.maxX) - right
            for offset in stride(from: 1.0, through: 9.0, by: 0.65) {
                let row = stride(from: first, to: last, by: 3).map { pixel($0, box.minY - offset) }
                if let color = commonColor(row, minimumShare: 0.66) {
                    rules.append(color)
                    break
                }
            }
        }
        let fill = commonColor(fills, minimumShare: 0.22)?.hex
        let rule = commonColor(rules, minimumShare: 0.42)?.hex
        return (fill, rule)
    }

    static func commonColor(_ colors: [RGB], minimumShare: Double) -> RGB? {
        guard !colors.isEmpty else { return nil }
        let counts = colors.filter { !$0.isPaper }.reduce(into: [RGB: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted {
            $0.value == $1.value ? $0.key.hex < $1.key.hex : $0.value > $1.value
        }.first.flatMap { Double($0.value) / Double(colors.count) >= minimumShare ? $0.key : nil }
    }
}
