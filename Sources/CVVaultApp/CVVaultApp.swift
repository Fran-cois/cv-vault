import AppKit
import CVVaultCore
import SwiftUI

@main
struct CVVaultApp: App {
    @StateObject private var model = VaultModel()

    var body: some Scene {
        WindowGroup("CV Vault") {
            VaultWindow(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .tint(VaultStyle.accent)
        }
        .defaultSize(width: 1120, height: 760)
    }
}

enum VaultRoute: Hashable {
    case overview, facts, exports, codex
    case source(String)
}

struct VaultNotice {
    let title: String
    let message: String
    var icon = "checkmark.circle.fill"
    var color = VaultStyle.accent
}

@MainActor
final class VaultModel: ObservableObject {
    @Published var route: VaultRoute? = .overview
    @Published private(set) var sources: [CVSource] = []
    @Published private(set) var exports: [URL] = []
    @Published private(set) var revision = 0
    @Published private(set) var isImporting = false
    @Published private(set) var isReady = false
    @Published var notice: VaultNotice?
    @Published var errorMessage: String?
    @Published var exportSourceID: String?
    private var database: KnowledgeBase?

    func start() {
        guard database == nil else { return }
        do {
            database = try KnowledgeBase()
            isReady = true
            try refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() throws {
        if let database {
            var allSources: [CVSource] = []
            var offset = 0
            while true {
                let batch = try database.listSources(limit: 100, offset: offset)
                allSources.append(contentsOf: batch)
                guard batch.count == 100 else { break }
                offset += batch.count
            }
            sources = allSources
        }
        refreshExports()
        revision += 1
    }

    func refreshExports() {
        let directory = CVExporter.defaultOutputDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = files.compactMap { url -> (URL, Date)? in
            guard url.pathExtension.lowercased() == "typ",
                  let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  attributes.isRegularFile == true else { return nil }
            return (url, attributes.contentModificationDate ?? .distantPast)
        }
        exports = candidates.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    func importPDFs(_ urls: [URL]) {
        guard !urls.isEmpty, let database, !isImporting else { return }
        isImporting = true
        notice = nil
        Task {
            let response = await Task.detached(priority: .userInitiated) {
                var imports: [PDFImportResult] = []
                var failures: [String] = []
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        imports.append(try database.importPDF(at: url))
                    } catch {
                        failures.append("\(url.lastPathComponent) — \(error.localizedDescription)")
                    }
                }
                return (imports, failures)
            }.value
            isImporting = false
            do { try refresh() } catch { errorMessage = error.localizedDescription }
            if let result = response.0.last {
                route = .source(result.source.id)
                let added = response.0.filter { !$0.isDuplicate }.count
                let duplicates = response.0.count - added
                let unreadable = response.0.reduce(0) { $0 + $1.source.unreadablePageCount }
                let summary = [
                    added > 0 ? formattedCount(added, "PDF importé", "PDF importés") : nil,
                    duplicates > 0 ? formattedCount(duplicates, "déjà dans la base", "déjà dans la base") : nil,
                    unreadable > 0 ? formattedCount(unreadable, "page illisible", "pages illisibles") : nil,
                ].compactMap { $0 }.joined(separator: " · ")
                notice = VaultNotice(
                    title: unreadable > 0 ? "Import à vérifier" : "Import terminé",
                    message: summary,
                    icon: unreadable > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                    color: unreadable > 0 ? .orange : VaultStyle.accent
                )
            }
            if !response.1.isEmpty { errorMessage = response.1.joined(separator: "\n\n") }
        }
    }

    func requireDatabase() throws -> KnowledgeBase {
        guard let database else { throw VaultUIError.databaseUnavailable }
        return database
    }

    func update(_ fact: CVFact, status: FactStatus, text: String? = nil, category: FactCategory? = nil) throws {
        _ = try requireDatabase().updateFact(
            id: fact.id, text: text ?? fact.text, category: category ?? fact.category, status: status
        )
        try refresh()
    }

    func changeStatus(_ fact: CVFact, status: FactStatus) {
        do {
            try update(fact, status: status)
        } catch { errorMessage = error.localizedDescription }
    }

    func verifyPendingFacts(for source: CVSource) {
        do {
            let count = try requireDatabase().verifyPendingFacts(sourceID: source.id)
            try refresh()
            notice = VaultNotice(
                title: formattedCount(count, "fait validé", "faits validés"),
                message: source.displayName
            )
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ source: CVSource) {
        do {
            try requireDatabase().deleteSource(id: source.id)
            if route == .source(source.id) { route = .overview }
            if exportSourceID == source.id { exportSourceID = nil }
            try refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func openExports(for sourceID: String? = nil) {
        exportSourceID = sourceID
        route = .exports
    }

    func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([KnowledgeBase.defaultDatabaseURL])
    }

    func revealExports() {
        NSWorkspace.shared.open(CVExporter.defaultOutputDirectory)
    }
}

enum VaultUIError: LocalizedError {
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable: "La base de connaissances n’est pas disponible."
        }
    }
}
