import Foundation

struct CVFactParser {
    private var activeCategory = FactCategory.other
    private var inHeader = true
    private var hasReadText = false
    private var mayReadHeadline = false
    private(set) var facts: [CVFact] = []

    private struct Candidate {
        let category: FactCategory
        var text: String
        var evidence: String
        var bounds: CGRect
    }

    mutating func addPage(_ page: CVPage, rows layout: PositionedPDFText?, annotations: [LocatedLink]) {
        var candidates: [Candidate] = []
        if let layout {
            parseLayout(layout, into: &candidates)
        } else {
            let rows = page.text.split(whereSeparator: \.isNewline).flatMap { raw in
                Self.splitEmbeddedBullets(String(raw)).map { LocatedText(text: $0, bounds: .null) }
            }
            parseRows(rows.map { [$0] }, laneWidth: nil, into: &candidates)
        }
        Self.attach(annotations, on: page, to: &candidates)
        facts += candidates.map {
            CVFact(
                id: UUID().uuidString, sourceID: page.sourceID, page: page.number,
                category: $0.category, text: $0.text, evidence: $0.evidence, status: .pending
            )
        }
    }

    private mutating func parseLayout(_ layout: PositionedPDFText, into candidates: inout [Candidate]) {
        let rows = layout.rows
        var start = 0
        while let index = rows.indices.dropFirst(start).first(where: { Self.pairedHeadings(rows[$0], width: layout.width) }) {
            parseRows(Array(rows[start..<index]), laneWidth: layout.width, into: &candidates)
            let headings = rows[index]
            let right = headings[1].x
            let leftWidth = right - headings[0].x
            let divider = right - min(leftWidth * 0.08, 10)
            let end = rows.indices.dropFirst(index + 1).first { next in
                // A later heading that crosses the sidebar boundary starts a new full-width section.
                rows[next].contains { Self.heading($0.text) != nil && $0.x < divider && $0.bounds.maxX > divider }
            } ?? rows.endIndex
            let section = rows[index..<end]
            let leftLane = section.compactMap { row -> [LocatedText]? in
                let fragments = row.filter { $0.x < divider }
                return fragments.isEmpty ? nil : fragments
            }
            let rightLane = section.compactMap { row -> [LocatedText]? in
                let fragments = row.filter { $0.x >= divider }
                return fragments.isEmpty ? nil : fragments
            }
            parseRows(leftLane, laneWidth: leftWidth, into: &candidates)
            parseRows(rightLane, laneWidth: layout.width - leftWidth, into: &candidates)
            start = end
        }
        parseRows(Array(rows[start...]), laneWidth: layout.width, into: &candidates)
    }

    private mutating func parseRows(_ rows: [[LocatedText]], laneWidth: CGFloat?, into candidates: inout [Candidate]) {
        var index = 0
        let rowStarts = rows.compactMap { $0.first?.x }.filter(\.isFinite).sorted()
        // One glyph at the crop edge should not displace the margin of the whole lane.
        let laneStart = rowStarts.isEmpty ? nil : rowStarts[rowStarts.count / 5]
        while index < rows.count {
            let row = rows[index]
            guard let first = row.first else { index += 1; continue }
            let rowText = Self.combined(row)
            let label = Self.heading(first.text)
            let heading = label ?? Self.heading(rowText)

            if let heading {
                activeCategory = heading.category
                inHeader = heading.category == .identity || heading.category == .contact ? inHeader : false
                hasReadText = true
                mayReadHeadline = false
                if let remainder = heading.remainder {
                    let remainderText = Self.join([remainder] + (label == nil ? [] : row.dropFirst().map(\.text)))
                    Self.append(remainderText, evidence: rowText, category: activeCategory, fragments: row, to: &candidates)
                    index += 1
                } else if label != nil, row.count > 1, let laneStart, let laneWidth,
                          Self.isLabelRow(row, laneStart: laneStart, laneWidth: laneWidth) {
                    let cell = Self.collectCell(rows, at: index, laneStart: laneStart, laneWidth: laneWidth)
                    if !cell.body.isEmpty {
                        Self.append(cell.body, evidence: cell.evidence, category: activeCategory,
                                    fragments: cell.fragments, to: &candidates)
                    }
                    index = cell.next
                } else {
                    if label != nil, row.count > 1 {
                        Self.append(Self.combined(Array(row.dropFirst())), evidence: rowText,
                                    category: activeCategory, fragments: row, to: &candidates)
                    }
                    index += 1
                }
                continue
            }

            if activeCategory == .education || activeCategory == .experience,
               let laneWidth, Self.dateSuffix(in: row, width: laneWidth) != nil {
                index = collectDatedEntry(rows, from: index, laneWidth: laneWidth, into: &candidates)
                continue
            }

            if !inHeader, [.skills, .projects, .languages].contains(activeCategory),
               let laneStart, let laneWidth,
               Self.isLabelRow(row, laneStart: laneStart, laneWidth: laneWidth) {
                let cell = Self.collectCell(rows, at: index, laneStart: laneStart, laneWidth: laneWidth)
                Self.append(cell.label + " — " + cell.body, evidence: cell.evidence, category: activeCategory,
                            fragments: cell.fragments, to: &candidates)
                index = cell.next
                continue
            }

            if Self.bulletStart(first.text) {
                let end = Self.continuationEnd(rows, after: index, anchor: first, allowUnpositioned: laneWidth == nil)
                let fragments = rows[index..<end].flatMap { $0 }
                let evidence = rows[index..<end].map(Self.combined).joined(separator: "\n")
                let text = Self.join([Self.removeBullet(rowText)] + rows[(index + 1)..<end].map(Self.combined))
                Self.append(text, evidence: evidence, category: activeCategory, fragments: fragments, to: &candidates)
                inHeader = false
                mayReadHeadline = false
                hasReadText = true
                index = end
                continue
            }

            if inHeader && Self.isContactLine(rowText) {
                let values = Self.contactParts(rowText)
                for value in values {
                    Self.append(value, evidence: rowText, category: .contact, fragments: row, to: &candidates)
                }
                mayReadHeadline = false
            } else if inHeader, !hasReadText, Self.looksLikeName(rowText) {
                Self.append(rowText, evidence: rowText, category: .identity, fragments: row, to: &candidates)
                mayReadHeadline = true
            } else if inHeader && mayReadHeadline && Self.looksLikeHeadline(rowText) {
                Self.append(rowText, evidence: rowText, category: .identity, fragments: row, to: &candidates)
                mayReadHeadline = false
            } else {
                let category: FactCategory
                if inHeader, activeCategory == .other, hasReadText, Self.looksLikeProse(rowText) {
                    category = .summary
                } else {
                    category = activeCategory
                }
                Self.append(rowText, evidence: rowText, category: category, fragments: row, to: &candidates)
                mayReadHeadline = false
            }
            hasReadText = true
            index += 1
        }
    }

    private mutating func collectDatedEntry(
        _ rows: [[LocatedText]], from index: Int, laneWidth: CGFloat, into candidates: inout [Candidate]
    ) -> Int {
        let row = rows[index]
        guard let date = Self.dateSuffix(in: row, width: laneWidth), let first = row.first else { return index + 1 }
        let title = Array(row.dropLast())
        Self.append(Self.combined(title), evidence: Self.combined(title), category: activeCategory,
                    fragments: title, to: &candidates)
        var start = index + 1
        if start < rows.count, let next = rows[start].first, first.y - next.y <= 23,
           Self.heading(next.text) == nil, !rows[start].contains(where: { Self.bulletStart($0.text) }),
           Self.dateSuffix(in: rows[start], width: laneWidth) == nil, !Self.isDate(next.text) {
            let metadata = rows[start]
            Self.append(metadata.map(\.text).joined(separator: " · "), evidence: Self.combined(metadata),
                        category: activeCategory, fragments: metadata, to: &candidates)
            start += 1
        }
        Self.append(date.text, evidence: date.text, category: activeCategory, fragments: [date], to: &candidates)

        let end = rows.indices.dropFirst(start).first { i in
            guard let first = rows[i].first else { return false }
            return Self.heading(first.text) != nil || Self.dateSuffix(in: rows[i], width: laneWidth) != nil
        } ?? rows.endIndex
        let body = rows[start..<end]
        let starts = body.flatMap { $0 }.filter { Self.bulletStart($0.text) }.map(\.x).sorted()
        if let left = starts.first, let right = starts.last, right - left >= laneWidth * 0.26 {
            // Anchor each wrapped line to its bullet column, inside this dated entry only.
            let divider = (left + right) / 2
            let lanes = [
                body.map { $0.filter { $0.x < divider } },
                body.map { $0.filter { $0.x >= divider } }
            ]
            for lane in lanes {
                parseRows(lane.filter { !$0.isEmpty }, laneWidth: laneWidth / 2, into: &candidates)
            }
        } else if !body.isEmpty {
            parseRows(Array(body), laneWidth: laneWidth, into: &candidates)
        }
        return end
    }

    private struct Cell {
        let label: String
        let body: String
        let evidence: String
        let fragments: [LocatedText]
        let next: Int
    }

    private static func collectCell(
        _ rows: [[LocatedText]], at index: Int, laneStart: CGFloat, laneWidth: CGFloat
    ) -> Cell {
        let start = rows[index]
        let boundary = laneStart + min(0.13 * laneWidth, (start[1].x - laneStart) * 0.65)
        var labels = [start[0].text]
        var content = Array(start.dropFirst()).map(\.text)
        var evidence = [combined(start)]
        var fragments = start
        var next = index + 1
        while next < rows.count, let first = rows[next].first, let previous = fragments.last,
              previous.y - first.y <= 16, heading(first.text) == nil, !bulletStart(first.text) {
            let row = rows[next]
            let bounded = row.filter { $0.x < boundary }
            if !bounded.isEmpty {
                guard labels.last?.hasSuffix("/") == true, bounded.count == 1,
                      first.text.count <= 32 else { break }
                labels.append(first.text)
            }
            content += row.filter { $0.x >= boundary }.map(\.text)
            fragments += row
            evidence.append(combined(row))
            next += 1
        }
        return Cell(label: join(labels), body: join(content), evidence: evidence.joined(separator: "\n"),
                    fragments: fragments, next: next)
    }

    private static func isLabelRow(_ row: [LocatedText], laneStart: CGFloat, laneWidth: CGFloat) -> Bool {
        guard row.count >= 2, let first = row.first, first.x - laneStart < min(20, laneWidth * 0.08),
              first.text.count <= 45, !bulletStart(first.text) else { return false }
        return row[1].x - first.bounds.maxX >= 13 && row[1].x - first.x >= laneWidth * 0.15
    }

    private static func continuationEnd(
        _ rows: [[LocatedText]], after index: Int, anchor: LocatedText, allowUnpositioned: Bool
    ) -> Int {
        var end = index + 1
        while end < rows.count, let first = rows[end].first, let last = rows[end - 1].first,
              !rows[end].contains(where: { bulletStart($0.text) }), heading(first.text) == nil,
              !isDate(first.text) {
            if allowUnpositioned {
                // Without layout, retain uncertain boundaries and join clear sentence continuations only.
                guard let previous = rows[end - 1].last?.text.last, !".!?".contains(previous),
                      first.text.first?.isLowercase == true else { break }
            } else {
                let indentation = first.x - anchor.x
                let matchesText = anchor.firstLetterX.map { abs(first.x - $0) <= 5 } == true
                guard matchesText || (3...34).contains(indentation),
                      last.y - first.y <= max(13.0, last.bounds.height * 1.55) else { break }
            }
            end += 1
        }
        return end
    }

    private static let wideDateRegex = try! NSRegularExpression(
        pattern: #"^(?:[\p{L}.]{3,12}\s+|\d{1,2}[/.\-])?(?:19|20)\d{2}(?:[/\-]\d{2})?\s*(?:[–—−-]|\bto\b|\bà\b|\bau\b)\s*(?:(?:[\p{L}.]{3,12}\s+|\d{1,2}[/.\-])?(?:19|20)\d{2}(?:[/\-]\d{2})?|present|présent|current|en cours|aujourd['’]hui|actuel(?:lement)?)$"#,
        options: .caseInsensitive
    )

    private static let yearRegex = try! NSRegularExpression(pattern: #"^(?:19|20)\d{2}$"#)

    private static func isDate(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return wideDateRegex.firstMatch(in: text, range: range) != nil
            || yearRegex.firstMatch(in: text, range: range) != nil
    }

    private static func dateSuffix(in row: [LocatedText], width: CGFloat) -> LocatedText? {
        guard row.count >= 2, let first = row.first, let last = row.last,
              !row.contains(where: { bulletStart($0.text) }), !isDate(first.text), isDate(last.text),
              last.x - row[row.count - 2].bounds.maxX >= max(14, width * 0.035),
              last.x - first.x >= width * 0.38 else { return nil }
        return last
    }

    private static func pairedHeadings(_ row: [LocatedText], width: CGFloat) -> Bool {
        guard row.count == 2, row[1].x - row[0].x >= width * 0.27,
              let first = heading(row[0].text), let second = heading(row[1].text) else { return false }
        return first.remainder == nil && second.remainder == nil && first.category != second.category
    }

    private static func append(
        _ text: String, evidence: String, category: FactCategory, fragments: [LocatedText], to candidates: inout [Candidate]
    ) {
        guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return }
        candidates.append(Candidate(category: category, text: text, evidence: evidence,
                                    bounds: fragments.reduce(CGRect.null) { $0.union($1.bounds) }))
    }

    private static func combined(_ line: [LocatedText]) -> String { join(line.map(\.text)) }

    private static func join(_ fragments: [String]) -> String {
        var result = ""
        for fragment in fragments {
            let piece = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if result.hasSuffix("\u{00ad}") {
                result.removeLast()
            } else if !result.isEmpty && !((result.hasSuffix("-") || result.hasSuffix("/")) && result.dropLast().last?.isLetter == true) {
                result.append(" ")
            }
            result.append(piece)
        }
        return result
    }

    static func isBulletGlyph(_ character: Character) -> Bool { "•◦▪‣●■▸‧".contains(character) }

    private static func bulletStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.first.map(isBulletGlyph) == true || ["- ", "– ", "— "].contains(where: { trimmed.hasPrefix($0) })
    }

    private static func removeBullet(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return bulletStart(trimmed) ? trimmed.dropFirst().trimmingCharacters(in: .whitespaces) : trimmed
    }

    private static func splitEmbeddedBullets(_ line: String) -> [String] {
        var result: [String] = []
        var start = line.startIndex
        for index in line.indices where isBulletGlyph(line[index]) {
            let previous = line[start..<index]
            if previous.contains(where: { !$0.isWhitespace }) {
                result.append(String(previous).trimmingCharacters(in: .whitespaces))
            }
            start = index
        }
        let remainder = line[start...].trimmingCharacters(in: .whitespaces)
        if !remainder.isEmpty { result.append(remainder) }
        return result
    }

    private static func heading(_ line: String) -> (category: FactCategory, remainder: String?)? {
        let split = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = split.first else { return nil }
        let trimmed = first.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "‐–—-")))
        let key = trimmed.normalizedForSearch.replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let category = headings[key] {
            let remainder = split.count > 1 ? split[1].trimmingCharacters(in: .whitespaces) : ""
            return (category, remainder.isEmpty ? nil : remainder)
        }
        // Résumés often place a short label in front of content with no colon.
        for prefix in ["langues", "languages"] where key.hasPrefix(prefix + " ") {
            let remainder = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !remainder.isEmpty { return (.languages, remainder) }
        }
        return nil
    }

    private static func contactParts(_ line: String) -> [String] {
        let parts = line.split(whereSeparator: { "|·•".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count > 1 ? parts : [line]
    }

    private static func isContactLine(_ line: String) -> Bool {
        contactParts(line).contains { piece in
            let email = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
            let url = #"^(?:https?://|mailto:|www\.)\S+$"#
            let phone = #"^(?:\+\d{1,3}[ .-]?)?(?:\(\d{1,4}\)|\d{2,5})(?:[ .-]?\d{2,4}){2,5}$"#
            if piece.range(of: email, options: .regularExpression) != nil
                || piece.range(of: url, options: .regularExpression) != nil { return true }
            return (9...15).contains(piece.filter(\.isNumber).count)
                && piece.range(of: phone, options: .regularExpression) != nil
        }
    }

    private static func looksLikeName(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace)
        return (2...6).contains(words.count) && line.count <= 80 && line.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
                || CharacterSet.whitespaces.contains($0) || "'’-.‐‑".unicodeScalars.contains($0)
        }
    }

    private static func looksLikeHeadline(_ line: String) -> Bool {
        line.count <= 100 && !looksLikeProse(line) && !isDate(line)
    }

    private static func looksLikeProse(_ line: String) -> Bool {
        line.count > 95 || (line.split(whereSeparator: \.isWhitespace).count >= 6 && line.last.map { ".!?".contains($0) } == true)
    }

    private static func attach(_ annotations: [LocatedLink], on page: CVPage, to candidates: inout [Candidate]) {
        var insertions: [Int: [Candidate]] = [:]
        var seen = Set<String>()
        for link in annotations where seen.insert(link.url).inserted {
            let normalized = link.url.lowercased()
            let visibleAddress = normalized.hasPrefix("mailto:") ? String(normalized.dropFirst("mailto:".count)) : normalized
            if candidates.contains(where: { $0.text.lowercased().contains(visibleAddress) }) { continue }
            let host = URLComponents(string: link.url)?.host?.lowercased()
            if let match = candidates.firstIndex(where: { item in
                guard item.category == .contact, let host else { return false }
                let protocols = item.text.lowercased()
                let hostLabel = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                return hostLabel == protocols || hostLabel.hasPrefix(protocols + ".")
            }) {
                candidates[match].text = link.url
                continue
            }
            let nearby = candidates.enumerated().compactMap { index, item -> (Int, CGFloat)? in
                guard !item.bounds.isNull else { return nil }
                let vertical = max(0, item.bounds.minY - link.bounds.maxY, link.bounds.minY - item.bounds.maxY)
                let horizontal = max(0, item.bounds.minX - link.bounds.maxX, link.bounds.minX - item.bounds.maxX)
                guard vertical <= 8 && horizontal <= 33 else { return nil }
                return (index, vertical * 3 + horizontal)
            }.min { $0.1 < $1.1 }?.0
            let nearest = nearby.map { candidates[$0].category }
            let category: FactCategory
            if nearest == .contact || nearest == .identity || normalized.hasPrefix("mailto:") {
                category = .contact
            } else if let nearest {
                category = nearest
            } else if !candidates.contains(where: { [.education, .experience, .projects].contains($0.category) }) {
                category = .contact
            } else {
                category = .other
            }
            let candidate = Candidate(category: category, text: link.url, evidence: link.url, bounds: link.bounds)
            insertions[nearby.map { $0 + 1 } ?? candidates.count, default: []].append(candidate)
        }
        for (position, links) in insertions.sorted(by: { $0.key > $1.key }) {
            candidates.insert(contentsOf: links, at: position)
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
                "education and training", "etudes", "etudes superieures", "diplomes", "qualifications",
                "formation & recherche", "formation et recherche", "formations & recherche", "formations et recherche",
                "education & research", "education and research", "formation initiale"
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
                "hobbies", "loisirs", "centres d'interet", "interets", "references",
                "other", "autres", "informations complementaires", "additional information"
            ])
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { category, labels in labels.map { ($0, category) } })
    }()
}
