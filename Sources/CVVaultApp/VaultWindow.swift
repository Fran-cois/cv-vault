import AppKit
import CVVaultCore
import SwiftUI
import UniformTypeIdentifiers

struct VaultWindow: View {
    @ObservedObject var model: VaultModel
    @State private var choosingPDFs = false
    @State private var isDropTarget = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 184, ideal: 212, max: 268)
        } detail: {
            VStack(spacing: 0) {
                if let notice = model.notice {
                    noticeBanner(notice)
                }
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isDropTarget && canImport {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(VaultStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { items, _ in
                guard canImport else { return false }
                let pdfs = items.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
                model.importPDFs(pdfs)
                return !pdfs.isEmpty
            } isTargeted: {
                isDropTarget = $0
            }
            .toolbar { toolbar }
        }
        .fileImporter(isPresented: $choosingPDFs, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importPDFs(urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .alert("L’action a échoué", isPresented: showError) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { model.start() }
    }

    private var canImport: Bool { model.isReady && !model.isImporting }

    private var showError: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: {
            if !$0 { model.errorMessage = nil }
        })
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VaultIcon(symbol: "tray.full.fill", size: 30)
                Text("CV Vault").font(.headline)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)
            List(selection: $model.route) {
                NavigationLink(value: VaultRoute.overview) {
                    Label("Vue d’ensemble", systemImage: "square.grid.2x2")
                }
                Section("Bibliothèque") {
                    NavigationLink(value: VaultRoute.facts) {
                        Label("Tous les faits", systemImage: "list.bullet.rectangle")
                    }
                    NavigationLink(value: VaultRoute.graph) {
                        Label("Graphe des faits", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    ForEach(model.sources, id: \.id) { source in
                        NavigationLink(value: VaultRoute.source(source.id)) {
                            HStack(spacing: 6) {
                                Label(source.displayName, systemImage: "doc")
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if source.unreadablePageCount > 0 {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption2)
                                        .help("Ce PDF contient des pages illisibles")
                                }
                            }
                        }
                        .help(source.name)
                    }
                }
                Section("Sorties") {
                    NavigationLink(value: VaultRoute.exports) {
                        Label("CV Typst", systemImage: "doc.text")
                    }
                    NavigationLink(value: VaultRoute.codex) {
                        Label("Codex · MCP", systemImage: "terminal")
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button {
                model.revealDatabase()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(VaultStyle.accent)
                    Text("Stockage local")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(!model.isReady)
            .help("Afficher la base SQLite dans le Finder")
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.route ?? .overview {
        case .overview:
            OverviewView(model: model, importPDF: { choosingPDFs = true })
        case .facts:
            VaultPage {
                PageTitle(title: "Tous les faits", subtitle: "Recherchez et vérifiez les informations issues de vos PDF.") {
                    EmptyView()
                }
                FactsBrowser(model: model)
            }
        case .graph:
            FactGraphView(model: model)
        case .exports:
            ExportsView(model: model)
        case .codex:
            CodexView()
        case .source(let id):
            if let source = model.sources.first(where: { $0.id == id }) {
                SourceView(model: model, source: source)
                    .id(id)
            } else {
                ContentUnavailableView("PDF introuvable", systemImage: "doc.badge.ellipsis")
            }
        }
    }

    private func noticeBanner(_ notice: VaultNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: notice.icon).foregroundStyle(notice.color)
            Text(notice.title).fontWeight(.semibold)
            Text(notice.message).foregroundStyle(.secondary)
            Spacer()
            Button {
                model.notice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Fermer la notification")
        }
        .font(.callout)
        .padding(.horizontal, 30)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isImporting {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Extraction du PDF")
            }
            Button {
                if !model.isReady { model.start(); return }
                do { try model.refresh() } catch { model.errorMessage = error.localizedDescription }
            } label: {
                Label("Actualiser", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Actualiser la base et les exports (⌘R)")
            Button {
                choosingPDFs = true
            } label: {
                Label("Importer des PDF", systemImage: "plus")
            }
            .keyboardShortcut("o")
            .disabled(!canImport)
            .help("Importer des PDF (⌘O)")
        }
    }
}

private struct OverviewView: View {
    @ObservedObject var model: VaultModel
    var importPDF: () -> Void

    var body: some View {
        VaultPage {
            PageTitle(title: "Vue d’ensemble", subtitle: "Vos CV, vos faits vérifiés et vos exports Typst.") {
                EmptyView()
            }
            HStack(spacing: 12) {
                metric("PDF importés", count: model.sources.count, symbol: "doc.on.doc", color: VaultStyle.accent) {
                    if let first = model.sources.first { model.route = .source(first.id) } else { importPDF() }
                }
                metric("Faits validés", count: model.sources.reduce(0) { $0 + $1.verifiedFactCount }, symbol: "checkmark.seal", color: VaultStyle.accent) {
                    model.route = .facts
                }
                metric("À vérifier", count: model.sources.reduce(0) { $0 + $1.pendingFactCount }, symbol: "list.bullet.clipboard", color: .orange) {
                    model.route = .facts
                }
                metric("CV Typst", count: model.exports.count, symbol: "doc.text", color: .blue) {
                    model.openExports()
                }
            }
            importPanel

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "PDF récents", symbol: "clock")
                if model.sources.isEmpty {
                    VaultEmpty(
                        title: "La bibliothèque est vide",
                        description: "Après l’import, retrouvez chaque PDF avec le texte de ses pages et les faits à valider.",
                        symbol: "doc.text.magnifyingglass"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.sources.prefix(5).enumerated()), id: \.element.id) { index, source in
                            if index > 0 { Divider().padding(.leading, 54) }
                            sourceRow(source)
                        }
                    }
                    .vaultPanel()
                }
            }
        }
    }

    private func metric(_ label: String, count: Int, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                VaultIcon(symbol: symbol, color: color, size: 27)
                Text(count.formatted())
                    .font(.system(size: 27, weight: .semibold, design: .monospaced))
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .vaultPanel()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var importPanel: some View {
        HStack(alignment: .center, spacing: 16) {
            VaultIcon(symbol: "arrow.down.document", size: 51)
            VStack(alignment: .leading, spacing: 5) {
                Text("Importer des CV").font(.title3.weight(.semibold))
                Text("Déposez vos PDF ici ou choisissez des fichiers. Le texte et les liens sont extraits sur ce Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 14)
            Button(action: importPDF) {
                Label("Choisir des PDF", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.isReady || model.isImporting)
        }
        .padding(20)
        .background(VaultStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(VaultStyle.accent.opacity(0.22)) }
    }

    private func sourceRow(_ source: CVSource) -> some View {
        Button {
            model.route = .source(source.id)
        } label: {
            HStack(spacing: 12) {
                VaultIcon(symbol: "doc.text", size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.displayName).fontWeight(.medium).lineLimit(1)
                    Text("\(formattedCount(source.pageCount, "page", "pages")) · \(source.importedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if source.pendingFactCount > 0 {
                    Label("\(source.pendingFactCount) à vérifier", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
