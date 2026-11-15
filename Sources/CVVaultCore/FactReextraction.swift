import Foundation

public struct PDFReextractionResult: Codable, Equatable, Sendable {
    public let source: CVSource
    public let previousFactCount: Int
    public let preservedFactCount: Int
    public let addedFactCount: Int
    public let removedFactCount: Int
    public let reviewedOrEditedFactCount: Int
}

struct StoredFact {
    let fact: CVFact
    let userEdited: Bool

    var isProtected: Bool { userEdited || fact.status != .pending }
}

enum FactReextraction {
    static func merge(existing: [StoredFact], extracted: [CVFact], usingPreviousPages: Set<Int>) -> [StoredFact] {
        let previousPages = Dictionary(grouping: existing, by: { $0.fact.page })
        let extractedPages = Dictionary(grouping: extracted, by: \.page)
        let pageNumbers = Set(previousPages.keys).union(extractedPages.keys).sorted()

        return pageNumbers.flatMap { page in
            let previous = previousPages[page, default: []]
            return usingPreviousPages.contains(page)
                ? previous
                : mergePage(existing: previous, extracted: extractedPages[page, default: []])
        }
    }

    private static func mergePage(existing: [StoredFact], extracted: [CVFact]) -> [StoredFact] {
        // Match equal evidence by occurrence, including duplicates on the same page.
        var occurrences: [String: [Int]] = [:]
        for index in existing.indices.reversed() {
            occurrences[evidenceKey(existing[index].fact.evidence), default: []].append(index)
        }
        let matches = extracted.map { candidate in
            occurrences[evidenceKey(candidate.evidence)]?.popLast()
        }
        let matched = Set(matches.compactMap { $0 })

        var unmatched: [Int: String] = [:]
        for index in existing.indices where !matched.contains(index) {
            unmatched[index] = overlapKey(existing[index].fact.evidence)
        }
        let protected = existing.indices.filter { !matched.contains($0) && existing[$0].isProtected }

        var result: [StoredFact] = []
        var retained = matched
        for (candidate, index) in zip(extracted, matches) {
            if let index {
                let old = existing[index]
                result.append(old.isProtected ? old : newFact(candidate, preservingID: old.fact.id))
                continue
            }

            let key = overlapKey(candidate.evidence)
            let includesReview = protected.contains { overlaps(key, unmatched[$0, default: ""]) }
            if includesReview {
                // Keep the older fragments of a regrouped passage if any fragment was reviewed
                // or edited. A rejected fragment must not come back as part of a pending fact.
                for index in existing.indices where !retained.contains(index) {
                    if let oldKey = unmatched[index], overlaps(key, oldKey) {
                        result.append(existing[index])
                        retained.insert(index)
                    }
                }
            } else {
                result.append(newFact(candidate))
            }
        }

        for index in protected where !retained.contains(index) {
            result.append(existing[index])
        }
        return result
    }

    private static func evidenceKey(_ evidence: String) -> String {
        evidence.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func overlapKey(_ evidence: String) -> String {
        evidenceKey(evidence).split(whereSeparator: { $0.isWhitespace || "|·•◦▪‣●■".contains($0) }).joined(separator: " ")
    }

    private static func overlaps(_ first: String, _ second: String) -> Bool {
        guard !first.isEmpty, !second.isEmpty else { return false }
        let firstPhrase = " " + first + " "
        let secondPhrase = " " + second + " "
        return firstPhrase.contains(secondPhrase) || secondPhrase.contains(firstPhrase)
    }

    private static func newFact(_ fact: CVFact, preservingID id: String? = nil) -> StoredFact {
        let replacement = CVFact(
            id: id ?? fact.id, sourceID: fact.sourceID, page: fact.page,
            category: fact.category, text: fact.text, evidence: fact.evidence, status: .pending
        )
        return StoredFact(fact: replacement, userEdited: false)
    }
}
