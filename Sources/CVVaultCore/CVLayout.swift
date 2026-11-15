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
        template: CVTemplate, paper: CVPaper?, composition: [CVSection]?, sourceStyle: CVSourceStyle?
    ) throws -> String {
        let appearance: CVSourceStyle?
        if template == .source {
            guard let sourceStyle else { throw CVExportError.missingSourceStyle }
            appearance = sourceStyle
        } else {
            appearance = nil
        }
        let rows = try composition.map { try resolve($0, facts: facts) } ?? defaultSections(facts)
        let nameAndIdentity = distinct(facts.filter { $0.category == .identity }.map(\.text))
        let candidateName = nameAndIdentity.first
        let role = title?.nonBlank
        let name = candidateName ?? role ?? "CV"
        let subtitle = distinct([candidateName == nil ? nil : role].compactMap { $0 } + nameAndIdentity.dropFirst())
        let contacts = distinct(facts.filter { $0.category == .contact }.map(\.text))
        let metadataTitle = distinct([candidateName, role].compactMap { $0 }).joined(separator: " — ")

        var output = [appearance.map { CVSourceLayout.preamble($0, language: language, paper: paper) }
            ?? preamble(template: template, language: language, paper: paper ?? .a4)]
        let author = candidateName.map { ", author: " + tuple([$0]) } ?? ""
        output.append("#set document(title: \(literal(metadataTitle.nonBlank ?? "CV"))\(author))")
        output.append("")
        output.append("#cv-title(\(literal(name)))")
        for item in subtitle { output.append("#cv-subtitle(\(literal(item)))") }
        if !contacts.isEmpty {
            let entries = contacts.map { value in
                let destination = contactDestination(value)
                let label = destination.flatMap { appearance?.linkLabels[$0] } ?? value
                return "(\(literal(label)), \(destination.map(literal) ?? "none"))"
            }
            output.append("#cv-contact((\(entries.joined(separator: ", ")),))")
        }
        output.append("#cv-header-rule()")

        let sectionLines = { (section: Section) in render(section, labels: labels, language: language, appearance: appearance) }
        let tail = rows.reversed().prefix { footerCategories.contains($0.category) }.reversed()
        if let ratio = appearance?.sidebarRatio,
           tail.contains(where: { $0.category == .projects }),
           tail.contains(where: { $0.category != .projects }) {
            output += rows.dropLast(tail.count).flatMap(sectionLines)
            let primary = tail.filter { $0.category != .projects }.flatMap(sectionLines).joined(separator: "\n")
            let secondary = tail.filter { $0.category == .projects }.flatMap(sectionLines).joined(separator: "\n")
            output.append("")
            output.append(CVSourceLayout.footer(ratio: ratio, primary: primary, secondary: secondary))
        } else {
            output += rows.flatMap(sectionLines)
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func render(
        _ section: Section, labels: [FactCategory: String], language: CVLanguage, appearance: CVSourceStyle?
    ) -> [String] {
        let category = section.category
        let label = labels[category]?.nonBlank ?? appearance?.sectionTitles[category]
        var output = [""]
        if appearance == nil || category != .summary || label != nil {
            let heading = label ?? CVExporter.sectionTitle(category, language)
            let command = appearance?.sidebarRatio != nil && (category == .languages || category == .other)
                ? "cv-inline-section" : "cv-section"
            output.append("#\(command)(\(literal(heading)))")
        }
        var attachedProjectURL: Int?
        for (index, row) in section.rows.enumerated() {
            switch row {
            case .fact(let content):
                if appearance != nil, category == .projects {
                    if let address = webDestination(content) {
                        if attachedProjectURL != index {
                            output.append("#cv-project-url(\(literal(content)), \(literal(address)))")
                        }
                        continue
                    }
                    let parts = content.split(separator: "↗", maxSplits: 2, omittingEmptySubsequences: false)
                    if parts.count == 2, let address = projectDestination(in: section.rows, after: index) {
                        let before = String(parts[0])
                        let after = String(parts[1])
                        output.append("#cv-project-link(\(literal(before)), \(literal(after)), \(literal(address)))")
                        attachedProjectURL = index + 1
                        continue
                    }
                }
                switch category {
                case .summary:
                    let paragraph = appearance == nil ? "par" : "cv-summary"
                    output.append("#\(paragraph)(\(literal(content)))")
                case .skills, .languages:
                    output.append("#cv-detail(\(literal(content)))")
                default:
                    output.append("#list.item(\(literal(content)))")
                }
            case .entry(let heading, let metadata, let bullets):
                var fields = [literal(heading), tuple(metadata), tuple(bullets)]
                if appearance != nil, category == .experience || category == .education {
                    fields.append("paired: true")
                    if let date = metadata.last, isDateMetadata(date, category: category) {
                        fields[1] = tuple(Array(metadata.dropLast()))
                        fields.append("date: \(literal(date))")
                    }
                }
                output.append("#cv-entry(\(fields.joined(separator: ", ")))")
            }
        }
        return output
    }

    private static let headerCategories: Set<FactCategory> = [.identity, .contact]
    private static let entryCategories: Set<FactCategory> = [.experience, .education, .projects]
    private static let footerCategories: Set<FactCategory> = [.skills, .languages, .other, .projects]

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
        isDateMetadata(fact.text, category: category)
    }

    private static func isDateMetadata(_ value: String, category: FactCategory) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func literal(_ string: String) -> String {
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
        return webDestination(contact)
    }

    private static func projectDestination(in rows: [Row], after index: Int) -> String? {
        let following = rows.dropFirst(index + 1)
        guard case .fact(let value)? = following.first, let address = webDestination(value) else {
            return nil
        }
        // Leave consecutive links visible because a single-arrow association would be ambiguous.
        if case .fact(let next)? = following.dropFirst().first, webDestination(next) != nil {
            return nil
        }
        return address
    }

    private static func webDestination(_ value: String) -> String? {
        guard !value.contains(where: \.isWhitespace),
              let address = URLComponents(string: value),
              let scheme = address.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = address.host, !host.isEmpty, address.user == nil, address.password == nil else {
            return nil
        }
        return address.url?.absoluteString
    }

    private struct Style {
        // These are Typst expressions. Both sans profiles end with a bundled fallback.
        static let sans = #"("Helvetica Neue", "Arial", "Libertinus Serif")"#

        let bodyFont: String
        let ink: String
        let accent: String
        let muted: String
        let rule: String
        let headlineSize: String
        let nameTracking: String
        var headerAlign = "left"
        var headerRule = "100%"
        var headerStroke = "1.1pt + accent"
        var titlePrefix = ""
        var titleColor = ""
        var bodySize = "11.2pt"
        var sectionAbove = "16pt"
        var sectionBelow = "8pt"
        var sectionText = #"13pt, weight: "semibold""#
        var sectionBody = "#heading(level: 1, body)\n  #v(4pt)\n  #line(length: 100%, stroke: 0.45pt + rule)"
        var roleText = #"11.4pt, weight: "bold""#
        var metadataText = "10pt"

        static func forTemplate(_ template: CVTemplate) -> Style {
            switch template {
            case .source, .editorial:
                Style(bodyFont: #""Libertinus Serif""#, ink: "162636", accent: "14495D",
                      muted: "485866", rule: "C7D5DB", headlineSize: "33pt", nameTracking: "-0.7pt",
                      headerRule: "42mm")
            case .classic:
                Style(bodyFont: #""New Computer Modern""#, ink: "1B1B1B", accent: "292929",
                      muted: "4C4C4C", rule: "C8C8C8", headlineSize: "27pt", nameTracking: "-0.2pt",
                      headerAlign: "center")
            case .minimal:
                Style(bodyFont: sans, ink: "20272E", accent: "353D45",
                      muted: "5C646C", rule: "C8CED2", headlineSize: "28pt", nameTracking: "-0.4pt",
                      headerStroke: "0.6pt + rule", bodySize: "10.8pt", sectionAbove: "12pt",
                      sectionBelow: "5pt", sectionText: #"11.5pt, weight: "bold", tracking: 0.25pt"#,
                      sectionBody: "#heading(level: 1, body)")
            case .executive:
                Style(bodyFont: #""Libertinus Serif""#, ink: "202D3A", accent: "203656",
                      muted: "425770", rule: "BAC4D0", headlineSize: "36pt", nameTracking: "-0.25pt",
                      headerStroke: "0.6pt + rule",
                      titlePrefix: "#line(length: 100%, stroke: 2.5pt + accent)\n  #v(9pt)\n  ",
                      titleColor: "fill: accent, ", sectionAbove: "18pt",
                      sectionText: #"13pt, weight: "semibold", tracking: 0.45pt"#,
                      roleText: #"12pt, weight: "bold", fill: accent"#)
            case .technical:
                Style(bodyFont: sans, ink: "1C2B37", accent: "225572",
                      muted: "4F6472", rule: "B6CDD8", headlineSize: "30pt", nameTracking: "-0.45pt",
                      headerRule: "32mm", bodySize: "10.8pt", sectionAbove: "14pt", sectionBelow: "7pt",
                      sectionText: #"11pt, font: "DejaVu Sans Mono", weight: "bold", tracking: 0.25pt"#,
                      sectionBody: """
                      #block(width: 100%, fill: rgb("EDF5F8"), inset: (left: 8pt, y: 4pt),
                        stroke: (left: 1.6pt + accent))[#heading(level: 1, body)]
                      """,
                      metadataText: #"9.2pt, font: "DejaVu Sans Mono""#)
            }
        }
    }

    private static func preamble(template: CVTemplate, language: CVLanguage, paper: CVPaper) -> String {
        let style = Style.forTemplate(template)
        let paperName = paper == .a4 ? "a4" : "us-letter"
        return #"""
        // CV Vault · \#(template.rawValue) · editable, standalone Typst document
        #let accent = rgb("\#(style.accent)")
        #let muted = rgb("\#(style.muted)")
        #let rule = rgb("\#(style.rule)")
        #let header-align = \#(style.headerAlign)

        #set page(
          paper: "\#(paperName)",
          margin: (x: 21mm, top: 17mm, bottom: 17mm),
          footer: context if counter(page).final().first() > 1 {
            align(right, text(8pt, fill: muted, counter(page).display("1 / 1", both: true)))
          },
        )
        #set text(
          font: \#(style.bodyFont), lang: "\#(language.rawValue)", size: \#(style.bodySize),
          fill: rgb("\#(style.ink)"), hyphenate: false, top-edge: "ascender", bottom-edge: "descender",
        )
        #set par(leading: 0.55em, spacing: 0.82em)
        #set list(indent: 1pt, body-indent: 5pt, spacing: 4pt, marker: [•])
        #set heading(numbering: none)
        #show heading.where(level: 1): set text(\#(style.sectionText), fill: accent)
        #show heading.where(level: 1): set block(above: 0pt, below: 0pt)
        #show heading.where(level: 2): set text(\#(style.roleText))
        #show heading.where(level: 2): set block(above: 0pt, below: 0pt)

        #let cv-title(body) = block(width: 100%, inset: (bottom: 4pt), below: 6pt, sticky: true)[
          \#(style.titlePrefix)#align(header-align, text(\#(style.headlineSize), tracking: \#(style.nameTracking), weight: "bold", \#(style.titleColor)body))
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
          #align(header-align, line(length: \#(style.headerRule), stroke: \#(style.headerStroke)))
        ]
        #let cv-section(body) = block(width: 100%, above: \#(style.sectionAbove), below: \#(style.sectionBelow), sticky: true)[
          \#(style.sectionBody)
        ]
        #let cv-detail(body) = block(above: 0pt, below: 5pt, text(body))
        #let cv-entry(title, metadata, bullets) = {
          block(width: 100%, above: 10pt, below: 5pt, sticky: bullets.len() > 0)[
            #heading(level: 2, title)
            #if metadata.len() > 0 [
              #v(3pt)
              #block(text(\#(style.metadataText), fill: muted, metadata.join("  ·  ")))
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
