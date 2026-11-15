import AppKit
import CVVaultCore
import PDFKit
import SwiftUI

struct ExportsView: View {
    @ObservedObject var model: VaultModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sourceID: String?
    @State private var availableFacts: [CVFact] = []
    @State private var selectedIDs: Set<String> = []
    @State private var loadedSourceID: String?
    @State private var loading = false
    @State private var language = CVLanguage.fr
    @State private var template = CVTemplate.editorial
    @State private var paper = CVPaper.a4
    @State private var title = ""
    @State private var filename = ""
    @State private var proposedName = Self.makeFilename()
    @State private var editingSelection = false
    @State private var created: URL?
    @State private var hasTypst = false
    @State private var request: RenderRequest?
    @State private var preview: ExportPreview?

    var body: some View {
        VaultPage {
            PageTitle(title: "CV Typst", subtitle: "Composez et prévisualisez votre CV à partir des faits validés.") {
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
        .onAppear {
            model.refreshExports()
            detectTypst()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { detectTypst() }
        }
        .onChange(of: model.sources, initial: true) { _, sources in
            guard sourceID == nil || !sources.contains(where: { $0.id == sourceID }) else { return }
            let requested = sources.first { $0.id == model.exportSourceID }
            sourceID = requested?.id ?? sources.first(where: { $0.verifiedFactCount > 0 })?.id ?? sources.first?.id
        }
        .task(id: LoadRequest(id: sourceID, revision: model.revision)) { await loadFacts() }
        .task(id: request?.id) {
            if let request { await render(request) }
        }
        .sheet(item: $preview) { draft in
            ExportPDFSheet(preview: draft) { name in
                try finishExport(CVExporter.save(pdf: draft.pdf, name: name))
            }
        }
    }

    private var exportForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionTitle(title: "Nouvel export", symbol: "doc.badge.plus")
            templatePicker

            Divider()
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
                    Text("Format").foregroundStyle(.secondary)
                    Picker("Format papier", selection: $paper) {
                        Text("A4").tag(CVPaper.a4)
                        Text("US Letter").tag(CVPaper.letter)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
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
                        .accessibilityLabel("Nom du fichier")
                }
            }
            .disabled(request != nil)

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
                    .disabled(request != nil)
            }

            exportActions

            if !hasTypst {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle").accessibilityHidden(true)
                    Text("Typst est requis pour l’aperçu et l’enregistrement PDF.")
                    Link("Installer Typst", destination: TypstPDFCompiler.installationURL)
                    Button("Détecter") { detectTypst() }.buttonStyle(.link)
                }
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
        .padding(17)
        .vaultPanel()
    }

    private var templatePicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                templateChoices
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                templateChoices
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Style du CV")
        .disabled(request != nil)
    }

    private var templateChoices: some View {
        ForEach(CVTemplate.allCases, id: \.self) { style in
            TemplateChoice(template: style, selection: $template)
                .frame(minWidth: 155)
        }
    }

    private var exportActions: some View {
        HStack(spacing: 10) {
            if let request {
                ProgressView().controlSize(.small)
                Text(request.output == .pdf ? "Compilation PDF…" : "Génération Typst…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if let created {
                Button("\(created.lastPathComponent) créé", systemImage: "checkmark.circle.fill") { reveal(created) }
                    .buttonStyle(.link)
                    .lineLimit(1)
            }
            Spacer()
            Button("Générer le .typ", systemImage: "arrow.down.doc") { prepare(.typst) }
                .disabled(!canExport)
            Button("Aperçu PDF", systemImage: "eye") { prepare(.pdf) }
                .buttonStyle(.borderedProminent)
                .disabled(!canExport || !hasTypst)
        }
    }

    private var canExport: Bool {
        request == nil && !selectedIDs.isEmpty && !loading && sourceID == loadedSourceID
    }

    private var factPicker: some View {
        DisclosureGroup(isExpanded: $editingSelection) {
            LazyVStack(alignment: .leading, spacing: 9) {
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
            VaultIcon(symbol: url.pathExtension == "pdf" ? "doc.richtext" : "doc.text", size: 28)
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
                .help("Ouvrir le fichier")
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

    private func detectTypst() {
        hasTypst = TypstPDFCompiler.executable() != nil
    }

    private func prepare(_ output: RenderRequest.Output) {
        guard canExport, let sourceID else { return }
        var name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".typ") || name.lowercased().hasSuffix(".pdf") {
            name.removeLast(4)
        }
        request = RenderRequest(
            sourceID: sourceID,
            factIDs: availableFacts.filter { selectedIDs.contains($0.id) }.map(\.id),
            language: language, template: template, paper: paper, title: title,
            name: name.isEmpty ? proposedName : name, output: output
        )
    }

    private func render(_ job: RenderRequest) async {
        defer {
            if request?.id == job.id { request = nil }
        }
        do {
            let database = try model.requireDatabase()
            let result = try await Task.detached(priority: .userInitiated) {
                try job.run(with: database)
            }.value
            try Task.checkCancellation()
            switch result {
            case .saved(let url):
                finishExport(url)
            case .preview(let pdf):
                guard let document = PDFDocument(data: pdf), document.pageCount > 0 else {
                    throw TypstPDFCompiler.Failure.emptyPDF
                }
                preview = ExportPreview(pdf: pdf, document: document, name: job.name)
            }
        } catch {
            guard !Task.isCancelled else { return }
            detectTypst()
            model.errorMessage = error.localizedDescription
        }
    }

    private func finishExport(_ url: URL) {
        created = url
        filename = ""
        proposedName = Self.makeFilename()
        model.refreshExports()
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func makeFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "cv-\(formatter.string(from: Date()))"
    }

    private struct LoadRequest: Hashable {
        let id: String?
        let revision: Int
    }

    private struct RenderRequest: Sendable {
        enum Output: Sendable { case typst, pdf }
        enum Result: Sendable { case saved(URL), preview(Data) }

        let id = UUID()
        let sourceID: String
        let factIDs: [String]
        let language: CVLanguage
        let template: CVTemplate
        let paper: CVPaper
        let title: String
        let name: String
        let output: Output

        func run(with database: KnowledgeBase) throws -> Result {
            var facts: [CVFact] = []
            for offset in stride(from: 0, to: factIDs.count, by: 500) {
                let ids = Array(factIDs[offset..<min(offset + 500, factIDs.count)])
                let batch = try database.facts(ids: ids)
                guard batch.map(\.id) == ids,
                      batch.allSatisfy({ $0.sourceID == sourceID && $0.status == .verified }) else {
                    throw SelectionChanged()
                }
                facts.append(contentsOf: batch)
            }
            let typst = try CVExporter.generate(facts: facts, language: language, title: title, template: template, paper: paper)
            switch output {
            case .typst: return .saved(try CVExporter.save(typst: typst, name: name))
            case .pdf: return .preview(try TypstPDFCompiler.compile(typst))
            }
        }
    }

    private struct SelectionChanged: LocalizedError {
        var errorDescription: String? {
            "Les faits sélectionnés ont changé. Actualisez la base, puis réessayez."
        }
    }
}

private struct ExportPreview: Identifiable {
    let id = UUID()
    let pdf: Data
    let document: PDFDocument
    let name: String
}

private struct ExportPDFSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saveError: String?
    let preview: ExportPreview
    let save: (String) throws -> Void

    init(preview: ExportPreview, save: @escaping (String) throws -> Void) {
        self.preview = preview
        self.save = save
        _name = State(initialValue: preview.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Aperçu PDF").font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Label(formattedCount(preview.document.pageCount, "page", "pages"), systemImage: "doc.on.doc")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(13)
            Divider()
            PDFPreview(document: preview.document)
                .accessibilityLabel("Aperçu du CV")
            Divider()
            HStack(spacing: 10) {
                TextField("Nom du fichier PDF", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Button("Fermer", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer le PDF", systemImage: "arrow.down.doc") {
                    do {
                        try save(name)
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(13)
        }
        .frame(minWidth: 585, idealWidth: 680, minHeight: 490, idealHeight: 625)
        .alert("Enregistrement impossible", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }
}

private struct TemplateChoice: View {
    let template: CVTemplate
    @Binding var selection: CVTemplate

    private var selected: Bool { selection == template }

    private var accent: Color {
        switch template {
        case .editorial: Color(red: 0.08, green: 0.29, blue: 0.36)
        case .classic: Color(white: 0.16)
        case .minimal: Color(red: 0.21, green: 0.24, blue: 0.27)
        case .executive: Color(red: 0.13, green: 0.21, blue: 0.34)
        case .technical: Color(red: 0.13, green: 0.33, blue: 0.45)
        }
    }

    private var caption: String {
        switch template {
        case .editorial: "Titres accentués"
        case .classic: "Noir et blanc"
        case .minimal: "Sans empattement"
        case .executive: "Serif bleu marine"
        case .technical: "Titres monospace"
        }
    }

    var body: some View {
        Button {
            selection = template
        } label: {
            HStack(spacing: 8) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(template.displayName(language: .fr)).font(.callout.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? VaultStyle.accent : Color.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                selected ? VaultStyle.accent.opacity(0.09) : Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? VaultStyle.accent : VaultStyle.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(template.displayName(language: .fr))
        .accessibilityHint(template.description(language: .fr))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var thumbnail: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: template == .classic ? .center : .leading, spacing: 2) {
                RoundedRectangle(cornerRadius: 1).fill(accent).frame(width: 15, height: 3)
                RoundedRectangle(cornerRadius: 1).fill(accent.opacity(0.4)).frame(width: 11, height: 1)
            }
            .frame(maxWidth: .infinity, alignment: template == .classic ? .center : .leading)
            Rectangle().fill(accent.opacity(template == .minimal ? 0 : 0.55))
                .frame(width: template == .editorial ? 9 : 20, height: template == .executive ? 2 : 1)
            Rectangle().fill(accent.opacity(template == .technical ? 0.25 : 1))
                .frame(width: template == .technical ? 20 : 8, height: template == .technical ? 3 : 1)
            Rectangle().fill(accent.opacity(0.35)).frame(width: 15, height: 1)
            Rectangle().fill(accent.opacity(0.35)).frame(width: 11, height: 1)
        }
        .padding(5)
        .frame(width: 30, height: 39, alignment: .topLeading)
        .background(Color(white: 0.98), in: RoundedRectangle(cornerRadius: 2))
        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}
