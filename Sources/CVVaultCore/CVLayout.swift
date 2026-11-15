import Foundation

enum CVLayout {
    private struct Section {
        let category: FactCategory
        let rows: [Row]
    }

    private enum Row {
        case fact(String)
        case entry(heading: String, metadata: [String], bullets: [String])
    }

    static func render(
        facts: [CVFact], labels: [FactCategory: String], language: CVLanguage, title: String?,
        template: CVTemplate, paper: CVPaper, composition: [CVSection]?
    ) throws -> String {
        let rows = try composition.map { try resolve($0, facts: facts) } ?? defaultSections(facts)
        let nameAndIdentity = distinct(facts.filter { $0.category == .identity }.map(\.text))
        let candidateName = nameAndIdentity.first
        let role = title?.nonBlank
        let name = candidateName ?? role ?? "CV"
        let subtitle = distinct([candidateName == nil ? nil : role].compactMap { $0 } + nameAndIdentity.dropFirst())
        let contacts = distinct(facts.filter { $0.category == .contact }.map(\.text))
        let metadataTitle = distinct([candidateName, role].compactMap { $0 }).joined(separator: " — ")

        var output = [preamble(template: template, language: language, paper: paper)]
        let author = candidateName.map { ", author: " + tuple([$0]) } ?? ""
        output.append("#set document(title: \(literal(metadataTitle.nonBlank ?? "CV"))\(author))")
        output.append("")
        output.append("#cv-title(\(literal(name)))")
        for item in subtitle { output.append("#cv-subtitle(\(literal(item)))") }
        if !contacts.isEmpty {
            let entries = contacts.map { value in
                let destination = contactDestination(value).map(literal) ?? "none"
                return "(\(literal(value)), \(destination))"
            }
            output.append("#cv-contact((\(entries.joined(separator: ", ")),))")
        }
        output.append("#cv-header-rule()")

        for section in rows {
            let heading = labels[section.category]?.nonBlank ?? CVExporter.sectionTitle(section.category, language)
            output.append("")
            output.append("#cv-section(\(literal(heading)))")
            for row in section.rows {
                switch row {
                case .fact(let content):
                    switch section.category {
                    case .summary:
                        output.append("#par(\(literal(content)))")
                    case .skills, .languages:
                        output.append("#cv-detail(\(literal(content)))")
                    default:
                        output.append("#list.item(\(literal(content)))")
                    }
                case .entry(let heading, let metadata, let bullets):
                    output.append("#cv-entry(\(literal(heading)), \(tuple(metadata)), \(tuple(bullets)))")
                }
            }
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static let headerCategories: Set<FactCategory> = [.identity, .contact]
    private static let entryCategories: Set<FactCategory> = [.experience, .education, .projects]

    private static func resolve(_ composition: [CVSection], facts: [CVFact]) throws -> [Section] {
        let byID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        var usedSections: Set<FactCategory> = []
        var usedFacts: Set<String> = []

        func take(_ id: String, in category: FactCategory) throws -> String {
            guard let fact = byID[id] else { throw CVCompositionError.unknownFact }
            guard fact.category == category else { throw CVCompositionError.wrongCategory }
            guard usedFacts.insert(id).inserted else { throw CVCompositionError.repeatedFact }
            return fact.text
        }

        let sections = try composition.map { section -> Section in
            let category = section.category
            guard !headerCategories.contains(category) else { throw CVCompositionError.headerSection }
            guard usedSections.insert(category).inserted else { throw CVCompositionError.repeatedSection }
            guard !section.entries.isEmpty || !section.factIDs.isEmpty else { throw CVCompositionError.emptySection }
            guard section.entries.isEmpty || entryCategories.contains(category) else {
                throw CVCompositionError.unsupportedEntries
            }

            var rows = try section.entries.map { entry -> Row in
                .entry(
                    heading: try take(entry.headingFactID, in: category),
                    metadata: try entry.metadataFactIDs.map { try take($0, in: category) },
                    bullets: try entry.bulletFactIDs.map { try take($0, in: category) }
                )
            }
            rows += try section.factIDs.map { .fact(try take($0, in: category)) }
            return Section(category: category, rows: rows)
        }

        guard facts.allSatisfy({ headerCategories.contains($0.category) || usedFacts.contains($0.id) }) else {
            throw CVCompositionError.unusedFact
        }
        return sections
    }

    private static func defaultSections(_ facts: [CVFact]) -> [Section] {
        var categories: [FactCategory] = []
        var factsByCategory: [FactCategory: [CVFact]] = [:]
        for fact in facts where !headerCategories.contains(fact.category) {
            if factsByCategory[fact.category] == nil { categories.append(fact.category) }
            factsByCategory[fact.category, default: []].append(fact)
        }
        return categories.map { category in
            let items = factsByCategory[category, default: []]
            let rows = entryCategories.contains(category) ? recognizedEntries(items, category: category) : items.map { .fact($0.text) }
            return Section(category: category, rows: rows)
        }
    }

    // Only promote a short source line when nearby dates or original bullet markers show its structure.
    private static func recognizedEntries(_ facts: [CVFact], category: FactCategory) -> [Row] {
        var rows: [Row] = []
        var index = 0
        while index < facts.count {
            let heading = facts[index]
            var next = index + 1
            guard next < facts.count, heading.page == facts[next].page,
                  isHeadingCandidate(heading) else {
                rows.append(.fact(heading.text))
                index += 1
                continue
            }
            var metadata: [String] = []
            if next + 1 < facts.count, heading.page == facts[next + 1].page,
               facts[next].text.count <= 75, isHeadingCandidate(facts[next]),
               isDateMetadata(facts[next + 1], category: category) {
                metadata.append(facts[next].text)
                next += 1
            }
            if isDateMetadata(facts[next], category: category) {
                metadata.append(facts[next].text)
                next += 1
            }
            var bullets: [String] = []
            while next < facts.count, facts[next].page == heading.page, hasBulletMarker(facts[next]) {
                bullets.append(facts[next].text)
                next += 1
            }
            if metadata.isEmpty, bullets.isEmpty {
                rows.append(.fact(heading.text))
            } else {
                rows.append(.entry(heading: heading.text, metadata: metadata, bullets: bullets))
            }
            index = next
        }
        return rows
    }

    private static func isHeadingCandidate(_ fact: CVFact) -> Bool {
        let content = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.count <= 120 && !content.contains(where: \.isNewline)
            && !hasBulletMarker(fact) && !isDateMetadata(fact, category: .education)
            && content.last.map { !".;!?".contains($0) } == true
    }

    private static let datePattern = try! NSRegularExpression(
        pattern: #"^(?:(?:[\p{L}.]{3,12}\s+|\d{1,2}[/.-])?(?:19|20)\d{2}(?:[-/]\d{2})?)\s*(?:[-–—−]|\bto\b|\bà\b|\bau\b)\s*(?:(?:[\p{L}.]{3,12}\s+|\d{1,2}[/.-])?(?:19|20)\d{2}(?:[-/]\d{2})?|present|présent|current|en cours|aujourd['’]hui)$"#,
        options: .caseInsensitive
    )

    private static let yearPattern = try! NSRegularExpression(pattern: #"^(?:19|20)\d{2}$"#)
    private static let bulletPattern = try! NSRegularExpression(pattern: #"^\s*(?:[•◦▪‣●■]|[-–—]\s)"#)

    private static func isDateMetadata(_ fact: CVFact, category: FactCategory) -> Bool {
        let text = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..., in: text)
        return datePattern.firstMatch(in: text, range: range) != nil
            || (category == .education && yearPattern.firstMatch(in: text, range: range) != nil)
    }

    private static func hasBulletMarker(_ fact: CVFact) -> Bool {
        let text = fact.evidence
        return bulletPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func tuple(_ values: [String]) -> String {
        let escaped = values.map(literal).joined(separator: ", ")
        return escaped.isEmpty ? "()" : "(\(escaped),)"
    }

    private static func literal(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0xA, 0xD: result += "\\n"
            case 0x9: result += "  "
            case 0...31, 127...159: continue
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func distinct(_ strings: [String]) -> [String] {
        var seen: Set<String> = []
        return strings.compactMap(\.nonBlank).filter { seen.insert($0).inserted }
    }

    private static func contactDestination(_ contact: String) -> String? {
        if contact.range(of: #"^[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil {
            return "mailto:" + contact
        }
        guard !contact.contains(where: \.isWhitespace),
              let address = URLComponents(string: contact),
              let scheme = address.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = address.host, !host.isEmpty, address.user == nil, address.password == nil else {
            return nil
        }
        return address.url?.absoluteString
    }

    private static func preamble(template: CVTemplate, language: CVLanguage, paper: CVPaper) -> String {
        let editorial = template == .editorial
        let bodyFont = editorial ? "Libertinus Serif" : "New Computer Modern"
        let ink = editorial ? "162636" : "1B1B1B"
        let accent = editorial ? "14495D" : "292929"
        let muted = editorial ? "485866" : "4C4C4C"
        let rule = editorial ? "C7D5DB" : "C8C8C8"
        let headlineSize = editorial ? "33pt" : "27pt"
        let nameTracking = editorial ? "-0.7pt" : "-0.2pt"
        let headerAlign = editorial ? "left" : "center"
        let headerRule = editorial ? "42mm" : "100%"
        let paperName = paper == .a4 ? "a4" : "us-letter"
        return #"""
        // CV Vault · \#(template.rawValue) · editable, standalone Typst document
        #let accent = rgb("\#(accent)")
        #let muted = rgb("\#(muted)")
        #let rule = rgb("\#(rule)")
        #let header-align = \#(headerAlign)

        #set page(
          paper: "\#(paperName)",
          margin: (x: 21mm, top: 17mm, bottom: 17mm),
          footer: context if counter(page).final().first() > 1 {
            align(right, text(8pt, fill: muted, counter(page).display("1 / 1", both: true)))
          },
        )
        #set text(
          font: "\#(bodyFont)", lang: "\#(language.rawValue)", size: 11.2pt,
          fill: rgb("\#(ink)"), hyphenate: false, top-edge: "ascender", bottom-edge: "descender",
        )
        #set par(leading: 0.55em, spacing: 0.82em)
        #set list(indent: 1pt, body-indent: 5pt, spacing: 4pt, marker: [•])
        #set heading(numbering: none)
        #show heading.where(level: 1): set text(13pt, weight: "semibold", fill: accent)
        #show heading.where(level: 1): set block(above: 0pt, below: 0pt)
        #show heading.where(level: 2): set text(11.4pt, weight: "bold")
        #show heading.where(level: 2): set block(above: 0pt, below: 0pt)

        #let cv-title(body) = block(width: 100%, inset: (bottom: 4pt), below: 6pt, sticky: true)[
          #align(header-align, text(\#(headlineSize), tracking: \#(nameTracking), weight: "bold", body))
        ]
        #let cv-subtitle(body) = block(width: 100%, below: 7pt, sticky: true)[
          #align(header-align, text(13pt, weight: "semibold", fill: accent, body))
        ]
        #let cv-contact(entries) = block(width: 100%, above: 5pt, below: 9pt)[
          #align(header-align, text(10pt, fill: muted, entries.map(((value, destination)) => {
            if destination == none { text(value) } else { link(destination, text(value)) }
          }).join(text("  ·  "))))
        ]
        #let cv-header-rule() = block(width: 100%, above: 8pt, below: 9pt)[
          #align(header-align, line(length: \#(headerRule), stroke: 1.1pt + accent))
        ]
        #let cv-section(body) = block(width: 100%, above: 16pt, below: 8pt, sticky: true)[
          #heading(level: 1, body)
          #v(4pt)
          #line(length: 100%, stroke: 0.45pt + rule)
        ]
        #let cv-detail(body) = block(above: 0pt, below: 5pt, text(body))
        #let cv-entry(title, metadata, bullets) = {
          block(width: 100%, above: 10pt, below: 5pt, sticky: bullets.len() > 0)[
            #heading(level: 2, title)
            #if metadata.len() > 0 [
              #v(3pt)
              #block(text(10pt, fill: muted, metadata.join("  ·  ")))
            ]
          ]
          if bullets.len() > 0 {
            block(above: 5pt, below: 7pt, list(..bullets))
          }
        }
        """#
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
