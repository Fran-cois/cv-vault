import Foundation

enum CVSourceLayout {
    static func preamble(_ style: CVSourceStyle, language: CVLanguage, paper: CVPaper?) -> String {
        let dimensions: (Double, Double)
        switch paper {
        case .a4: dimensions = (595.276, 841.890)
        case .letter: dimensions = (612, 792)
        case nil: dimensions = (style.pageWidth, style.pageHeight)
        }

        let left = points(min(style.marginLeft, dimensions.0 * 0.23))
        let right = points(min(style.marginRight, dimensions.0 * 0.23))
        let top = points(min(style.marginTop, dimensions.1 * 0.17))
        let bottom = points(min(style.marginBottom, dimensions.1 * 0.17))
        let gap = points(max(0.35, min(3.5, style.bodyLineHeight - style.body.size)))
        let body = attributes(style.body)
        let align = style.headerCentered ? "center" : "left"
        let heading = attributes(style.heading)
        let accent = color(style.ruleColor ?? style.heading.color)
        let sectionBody: String
        if let fill = style.sectionFill {
            sectionBody = """
            #box(fill: \(color(fill)), radius: 1.5pt, inset: (x: 4pt, y: 1.4pt))[
              #heading(level: 1, body)
            ]
            """
        } else if style.sectionRule {
            sectionBody = """
            #heading(level: 1, body)
            #v(1.5pt)
            #line(length: 100%, stroke: 0.45pt + \(accent))
            """
        } else {
            sectionBody = "#heading(level: 1, body)"
        }

        return #"""
        // CV Vault · Original · editable Typst source
        #let header-align = \#(align)
        #set page(
          width: \#(points(dimensions.0)), height: \#(points(dimensions.1)),
          margin: (left: \#(left), right: \#(right), top: \#(top), bottom: \#(bottom)),
          footer: context if counter(page).final().first() > 1 {
            align(right, text(7pt, counter(page).display("1 / 1", both: true)))
          },
        )
        #set text(\#(body), lang: "\#(language.rawValue)", hyphenate: false, top-edge: "ascender", bottom-edge: "descender")
        #set par(leading: \#(gap), spacing: 1pt)
        #set list(indent: 1pt, body-indent: 3pt, spacing: 0.5pt, marker: [•])
        #set heading(numbering: none)
        #show heading.where(level: 1): set text(\#(heading))
        #show heading.where(level: 2): set text(\#(attributes(style.role)))
        #show heading: set block(above: 0pt, below: 0pt)
        #let cv-title(body) = block(width: 100%, below: 2pt, sticky: true)[
          #align(header-align, text(\#(attributes(style.name)), body))
        ]
        #let cv-subtitle(body) = block(width: 100%, below: 1.5pt, sticky: true)[
          #align(header-align, text(\#(attributes(style.subtitle)), body))
        ]
        #let cv-contact(entries) = block(width: 100%, below: 3pt)[
          #align(header-align, text(\#(attributes(style.contact)), entries.map(((value, address)) => {
            if address == none { text(value) } else { link(address, text(value)) }
          }).join(text("   ·   "))))
        ]
        #let cv-header-rule() = []
        #let cv-summary(body) = block(below: 3pt, text(\#(attributes(style.summary)), body))
        #let cv-section(body) = block(width: 100%, above: 4pt, below: 2pt, sticky: true)[
          \#(sectionBody)
        ]
        #let cv-inline-section(body) = block(above: 3pt, below: 0.5pt, sticky: true)[
          #heading(level: 1, text(\#(attributes(style.role)), body))
        ]
        #let cv-detail(body) = block(above: 1pt, below: 0.7pt, text(body))
        #let cv-entry(title, metadata, bullets, paired: false, date: none) = {
          block(width: 100%, above: 3pt, below: 1pt, sticky: bullets.len() > 0)[
            #if date == none {
              heading(level: 2, title)
            } else {
              grid(columns: (1fr, auto), column-gutter: 8pt,
                   heading(level: 2, title), align(right, text(\#(attributes(style.date)), date)))
            }
            #if metadata.len() > 0 [
              #v(0.5pt)
              #block(text(\#(attributes(style.metadata)), metadata.join("  ·  ")))
            ]
          ]
          if bullets.len() > 0 {
            if paired and \#(style.bulletColumns == 2 ? "true" : "false") and bullets.len() > 1 {
              let split = calc.ceil(bullets.len() / 2)
              grid(columns: (1fr, 1fr), column-gutter: 9pt,
                   list(..bullets.slice(0, split)), list(..bullets.slice(split)))
            } else {
              list(..bullets)
            }
          }
        }
        """#
    }

    static func footer(ratio: Double, primary: String, secondary: String) -> String {
        let percent = Int((max(0.28, min(0.72, ratio)) * 100).rounded())
        return "#grid(columns: (\(percent)%, 1fr), column-gutter: 9pt)[\n\(primary)\n][\n\(secondary)\n]"
    }

    private static func attributes(_ text: CVSourceTextStyle) -> String {
        let family = text.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = family.isEmpty ? ["Libertinus Serif"] : [family, "Libertinus Serif"]
        let fonts = "(" + known.map(CVLayout.literal).joined(separator: ", ") + ",)"
        let weight = ["regular", "semibold", "bold"].contains(text.weight) ? text.weight : "regular"
        return [
            "font: \(fonts)",
            "size: \(points(text.size))",
            "weight: \(CVLayout.literal(weight))",
            "style: \"\(text.italic ? "italic" : "normal")\"",
            "fill: \(color(text.color))"
        ].joined(separator: ", ")
    }

    private static func points(_ value: Double) -> String {
        String(format: "%.3fpt", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func color(_ value: String) -> String {
        let hex = value.count == 6 && value.allSatisfy { "0123456789abcdefABCDEF".contains($0) }
            ? value : "202020"
        return "rgb(\(CVLayout.literal(hex)))"
    }
}
