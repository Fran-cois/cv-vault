import AppKit
import CVVaultCore
import SwiftUI

struct ExportsView: View {
    @ObservedObject var model: VaultModel
    @State private var sourceID: String?
    @State private var availableFacts: [CVFact] = []
    @State private var selectedIDs: Set<String> = []
    @State private var loadedSourceID: String?
    @State private var loading = false
    @State private var language = CVLanguage.fr
    @State private var title = ""
    @State private var filename = ""
    @State private var proposedName = Self.makeFilename()
    @State private var editingSelection = false
    @State private var created: URL?

    var body: some View {
        VaultPage {
            PageTitle(title: "CV Typst", subtitle: "Composez un CV à partir des faits validés d’un PDF.") {
                if !model.exports.isEmpty {
                    Button("Ouvrir le dossier", systemImage: "folder") { model.revealExports() }
                }
            }

            if model.sources.isEmpty {
                VaultEmpty(
                    title: "Aucun PDF disponible",
                    description: "Importez un CV, puis validez les faits à inclure dans votre export.",
                    symbol: "doc.badge.plus"
                )
            } else {
                exportForm
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Historique des exports", symbol: "clock")
                if model.exports.isEmpty {
                    VaultEmpty(
                        title: "Aucun export",
                        description: "Les CV créés ici ou enregistrés par Codex apparaissent dans cette liste.",
                        symbol: "folder"
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.exports.enumerated()), id: \.element) { index, url in
                            if index > 0 { Divider().padding(.leading, 50) }
                            exportRow(url)
                        }
                    }
                    .vaultPanel()
                }
            }
        }
        .onAppear { model.refreshExports() }
        .onChange(of: model.sources, initial: true) { _, sources in
            guard sourceID == nil || !sources.contains(where: { $0.id == sourceID }) else { return }
            let requested = sources.first { $0.id == model.exportSourceID }
            sourceID = requested?.id ?? sources.first(where: { $0.verifiedFactCount > 0 })?.id ?? sources.first?.id
        }
        .task(id: LoadRequest(id: sourceID, revision: model.revision)) { await loadFacts() }
    }

    private var exportForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionTitle(title: "Nouvel export", symbol: "doc.badge.plus")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("PDF source").foregroundStyle(.secondary)
                    Picker("PDF source", selection: $sourceID) {
                        Text("Choisir un PDF").tag(String?.none)
                        ForEach(model.sources, id: \.id) { source in
                            Text(source.displayName).tag(Optional(source.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("Langue").foregroundStyle(.secondary)
                    Picker("Langue du modèle", selection: $language) {
                        Text("Français").tag(CVLanguage.fr)
                        Text("English").tag(CVLanguage.en)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                GridRow {
                    Text("Titre").foregroundStyle(.secondary)
                    TextField("Facultatif", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Titre du CV")
                }
                GridRow {
                    Text("Nom du fichier").foregroundStyle(.secondary)
                    TextField(proposedName, text: $filename)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Nom du fichier Typst")
                }
            }

            Divider()
            if loading {
                ProgressView().controlSize(.small).padding(4)
            } else if availableFacts.isEmpty && sourceID != nil {
                HStack {
                    Label("Ce PDF ne contient aucun fait validé.", systemImage: "checkmark.seal")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Vérifier les faits") {
                        if let sourceID { model.route = .source(sourceID) }
                    }
                    .buttonStyle(.link)
                }
            } else if !availableFacts.isEmpty {
                factPicker
            }

            HStack {
                if let created {
                    Button("\(created.lastPathComponent) créé", systemImage: "checkmark.circle.fill") { reveal(created) }
                        .buttonStyle(.link)
                }
                Spacer()
                Button {
                    exportCV()
                } label: {
                    Label("Générer le .typ", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty || loading || sourceID != loadedSourceID)
            }
        }
        .padding(17)
        .vaultPanel()
    }

    private var factPicker: some View {
        DisclosureGroup(isExpanded: $editingSelection) {
            VStack(alignment: .leading, spacing: 9) {
                Button(selectedIDs.isEmpty ? "Tout sélectionner" : "Tout désélectionner") {
                    selectedIDs = selectedIDs.isEmpty ? Set(availableFacts.map(\.id)) : []
                }
                .buttonStyle(.link)
                ForEach(availableFacts, id: \.id) { fact in
                    Toggle(isOn: selection(for: fact.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(fact.text).fixedSize(horizontal: false, vertical: true)
                            Text("\(fact.category.displayName) · p. \(fact.page)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Text("\(selectedIDs.count) / \(availableFacts.count) faits validés sélectionnés")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func selection(for id: String) -> Binding<Bool> {
        Binding(get: { selectedIDs.contains(id) }, set: { selected in
            if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        })
    }

    private func exportRow(_ url: URL) -> some View {
        HStack(spacing: 10) {
            VaultIcon(symbol: "doc.text", size: 28)
            Text(url.lastPathComponent)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer()
            Button("Afficher dans le Finder", systemImage: "folder") { reveal(url) }
                .labelStyle(.iconOnly)
                .help("Afficher dans le Finder")
            Button("Ouvrir", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                .labelStyle(.iconOnly)
                .help("Ouvrir le fichier Typst")
        }
        .padding(11)
    }

    private func loadFacts() async {
        guard let id = sourceID else {
            availableFacts = []
            selectedIDs = []
            loadedSourceID = nil
            loading = false
            return
        }
        loading = true
        do {
            let database = try model.requireDatabase()
            let facts = try await Task.detached {
                var results: [CVFact] = []
                while true {
                    let batch = try database.searchFacts(status: .verified, sourceID: id, limit: 100, offset: results.count)
                    results.append(contentsOf: batch)
                    if batch.count < 100 { return results }
                }
            }.value
            try Task.checkCancellation()
            if loadedSourceID == id {
                let oldIDs = Set(availableFacts.map(\.id))
                let availableIDs = Set(facts.map(\.id))
                selectedIDs = selectedIDs.intersection(availableIDs).union(availableIDs.subtracting(oldIDs))
            } else {
                selectedIDs = Set(facts.map(\.id))
            }
            loadedSourceID = id
            availableFacts = facts
            loading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            model.errorMessage = error.localizedDescription
            loading = false
        }
    }

    private func exportCV() {
        do {
            let database = try model.requireDatabase()
            let facts = try availableFacts.filter { selectedIDs.contains($0.id) }.map { fact in
                guard let current = try database.fact(id: fact.id) else { throw ExportUIError.factRemoved }
                return current
            }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let typst = try CVExporter.generate(facts: facts, language: language, title: trimmedTitle.isEmpty ? nil : trimmedTitle)
            let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
            created = try CVExporter.save(typst: typst, name: name.isEmpty ? proposedName : name)
            filename = ""
            proposedName = Self.makeFilename()
            try model.refresh()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func makeFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "cv-\(formatter.string(from: Date())).typ"
    }

    private struct LoadRequest: Hashable {
        let id: String?
        let revision: Int
    }

    private enum ExportUIError: LocalizedError {
        case factRemoved

        var errorDescription: String? {
            "Un des faits sélectionnés a été supprimé. Actualisez la base, puis réessayez."
        }
    }
}
