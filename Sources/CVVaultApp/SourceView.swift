import CVVaultCore
import PDFKit
import SwiftUI

struct SourceView: View {
    @ObservedObject var model: VaultModel
    let source: CVSource
    @State private var tab = Tab.facts
    @State private var showDelete = false
    @State private var showVerifyAll = false

    var body: some View {
        VaultPage {
            PageTitle(
                title: source.displayName,
                subtitle: "\(formattedCount(source.pageCount, "page", "pages")) · Importé le \(source.importedAt.formatted(date: .abbreviated, time: .omitted))"
            ) {
                Button {
                    model.openExports(for: source.id)
                } label: {
                    Label("Créer un CV", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(source.verifiedFactCount == 0)
                .help(source.verifiedFactCount == 0 ? "Validez un fait pour créer un CV" : "Créer un CV Typst depuis ce PDF")
                Menu {
                    Button("Supprimer de la bibliothèque…", systemImage: "trash", role: .destructive) {
                        showDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions PDF")
            }

            if source.unreadablePageCount > 0 {
                Label(
                    "\(formattedCount(source.unreadablePageCount, "page illisible", "pages illisibles")). Ouvrez le PDF original pour les examiner.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Picker("Vue du PDF", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("\(formattedCount(source.verifiedFactCount, "fait validé", "faits validés")) · \(source.pendingFactCount) à vérifier")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if tab == .facts && source.pendingFactCount > 0 {
                    Button("Tout valider…") { showVerifyAll = true }
                        .confirmationDialog(
                            "Valider les faits en attente ?",
                            isPresented: $showVerifyAll,
                            titleVisibility: .visible
                        ) {
                            Button("Valider les \(formattedCount(source.pendingFactCount, "fait", "faits"))") {
                                model.verifyPendingFacts(for: source)
                            }
                            Button("Annuler", role: .cancel) {}
                        } message: {
                            Text("Tous les faits à vérifier de ce PDF pourront être utilisés dans les exports. Confirmez après les avoir relus.")
                        }
                }
            }

            switch tab {
            case .facts: FactsBrowser(model: model, sourceID: source.id)
            case .text: ExtractedPages(model: model, source: source)
            case .original: OriginalPDF(model: model, sourceID: source.id)
            }
        }
        .confirmationDialog("Supprimer ce PDF de la bibliothèque ?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Supprimer le PDF et ses faits", role: .destructive) { model.delete(source) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La copie intégrée et ses faits seront retirés de la base. Le fichier d’origine et les exports Typst seront conservés.")
        }
    }

    private enum Tab: String, CaseIterable {
        case facts = "Faits"
        case text = "Texte extrait"
        case original = "PDF original"
    }
}

private struct ExtractedPages: View {
    @ObservedObject var model: VaultModel
    let source: CVSource
    @State private var pages: [CVPage] = []
    @State private var loading = true

    var body: some View {
        LazyVStack(spacing: 10) {
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            } else {
                ForEach(pages, id: \.number) { page in
                    ExtractedPage(page: page)
                }
            }
        }
        .task(id: source.id) {
            do {
                let database = try model.requireDatabase()
                let sourceID = source.id
                let limit = min(1000, max(1, source.pageCount))
                pages = try await Task.detached {
                    try database.pages(sourceID: sourceID, limit: limit)
                }.value
                loading = false
            } catch {
                loading = false
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ExtractedPage: View {
    let page: CVPage
    @State private var expanded: Bool

    init(page: CVPage) {
        self.page = page
        _expanded = State(initialValue: page.number == 1)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if page.text.isEmpty {
                    Text("Aucun texte lisible n’a été extrait.").foregroundStyle(.secondary)
                } else {
                    Text(page.text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !page.links.isEmpty {
                    Divider()
                    Label("Liens du PDF", systemImage: "link").font(.subheadline.weight(.semibold))
                    ForEach(page.links, id: \.self) { link in
                        Text(link).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        } label: {
            HStack {
                Text("Page \(page.number)").fontWeight(.medium)
                Spacer()
                Text(page.method.displayName)
                    .font(.caption)
                    .foregroundStyle(page.method == .unreadable ? .orange : .secondary)
            }
        }
        .padding(12)
        .vaultPanel()
    }
}

private struct OriginalPDF: View {
    @ObservedObject var model: VaultModel
    let sourceID: String
    @State private var document: PDFDocument?
    @State private var loading = true

    var body: some View {
        Group {
            if let document {
                PDFPreview(document: document)
                    .frame(height: 590)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .vaultPanel()
            } else if loading {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            } else {
                VaultEmpty(title: "Aperçu indisponible", description: "La copie du PDF ne peut pas être affichée.", symbol: "doc")
            }
        }
        .task(id: sourceID) {
            do {
                let database = try model.requireDatabase()
                let id = sourceID
                let data = try await Task.detached { try database.originalPDF(sourceID: id) }.value
                document = data.flatMap(PDFDocument.init(data:))
                loading = false
            } catch {
                loading = false
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.displaysPageBreaks = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
