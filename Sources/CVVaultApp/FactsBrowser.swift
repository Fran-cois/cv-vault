import CVVaultCore
import SwiftUI

struct FactsBrowser: View {
    @ObservedObject var model: VaultModel
    var sourceID: String?
    @State private var filter = Filter()
    @State private var results: [CVFact] = []
    @State private var page = 0
    @State private var hasNextPage = false
    @State private var loaded = false
    @State private var editing: CVFact?
    private let pageSize = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filters
            if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            } else if results.isEmpty {
                VaultEmpty(
                    title: "Aucun fait trouvé",
                    description: filter == Filter()
                        ? "Importez un PDF pour alimenter la base."
                        : "Essayez un autre mot-clé ou modifiez les filtres.",
                    symbol: "magnifyingglass"
                )
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, fact in
                        if index != 0 { Divider().padding(.leading, 45) }
                        factRow(fact)
                    }
                }
                .vaultPanel()
            }
            if page > 0 || hasNextPage { pagination }
        }
        .onChange(of: filter) { _, _ in page = 0 }
        .task(id: Request(filter: filter, page: page, revision: model.revision)) { await loadFacts() }
        .sheet(item: $editing) { fact in
            FactEditor(fact: fact) { text, category, status in
                try model.update(fact, status: status, text: text, category: category)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Rechercher dans les faits", text: $filter.query)
                    .textFieldStyle(.plain)
                if !filter.query.isEmpty {
                    Button {
                        filter.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Effacer la recherche")
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .vaultPanel(radius: 7)
            .frame(minWidth: 168)
            Picker("Catégorie", selection: $filter.category) {
                Text("Toutes les catégories").tag(FactCategory?.none)
                ForEach(FactCategory.allCases, id: \.self) { category in
                    Text(category.displayName).tag(Optional(category))
                }
            }
            .labelsHidden()
            .frame(width: 160)
            Picker("Statut", selection: $filter.status) {
                Text("Tous les statuts").tag(FactStatus?.none)
                ForEach(FactStatus.allCases, id: \.self) { status in
                    Text(status.displayName).tag(Optional(status))
                }
            }
            .labelsHidden()
            .frame(width: 128)
        }
    }

    private func factRow(_ fact: CVFact) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VaultIcon(symbol: fact.category.symbol, size: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(fact.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if sourceID == nil,
                       let source = model.sources.first(where: { $0.id == fact.sourceID }) {
                        Button(source.displayName) { model.route = .source(fact.sourceID) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                    }
                    Text("\(fact.category.displayName) · p. \(fact.page)")
                        .foregroundStyle(.secondary)
                    Label(fact.status.displayName, systemImage: "circle.fill")
                        .foregroundStyle(fact.status.statusColor)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if fact.status == .pending {
                Button {
                    model.changeStatus(fact, status: .verified)
                } label: {
                    Label("Valider", systemImage: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Valider ce fait pour les exports")
            }
            Menu {
                Button("Modifier et voir la preuve…", systemImage: "pencil") { editing = fact }
                Divider()
                ForEach(FactStatus.allCases.filter { $0 != fact.status }, id: \.self) { status in
                    Button(statusAction(status)) { model.changeStatus(fact, status: status) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions sur ce fait")
        }
        .padding(12)
    }

    private var pagination: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Précédent", systemImage: "chevron.left") { page -= 1 }
                .labelStyle(.iconOnly)
                .disabled(page == 0)
            Text("Page \(page + 1)").font(.callout).foregroundStyle(.secondary)
            Button("Suivant", systemImage: "chevron.right") { page += 1 }
                .labelStyle(.iconOnly)
                .disabled(!hasNextPage)
        }
    }

    private func statusAction(_ status: FactStatus) -> String {
        switch status {
        case .pending: "Remettre à vérifier"
        case .verified: "Valider"
        case .rejected: "Écarter"
        }
    }

    private func loadFacts() async {
        let filter = filter
        let sourceID = sourceID
        let offset = page * pageSize
        let limit = pageSize + 1
        do {
            try await Task.sleep(for: .milliseconds(100))
            let database = try model.requireDatabase()
            let batch = try await Task.detached {
                try database.searchFacts(
                    query: filter.query, category: filter.category, status: filter.status,
                    sourceID: sourceID, limit: limit, offset: offset
                )
            }.value
            try Task.checkCancellation()
            if batch.isEmpty && page > 0 {
                page -= 1
                return
            }
            results = Array(batch.prefix(pageSize))
            hasNextPage = batch.count > pageSize
            loaded = true
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loaded = true
            model.errorMessage = error.localizedDescription
        }
    }

    private struct Filter: Hashable, Sendable {
        var query = ""
        var status: FactStatus?
        var category: FactCategory?
    }

    private struct Request: Hashable {
        let filter: Filter
        let page: Int
        let revision: Int
    }
}

private struct FactEditor: View {
    let fact: CVFact
    var update: (String, FactCategory, FactStatus) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var category: FactCategory
    @State private var status: FactStatus
    @State private var errorMessage: String?

    init(fact: CVFact, update: @escaping (String, FactCategory, FactStatus) throws -> Void) {
        self.fact = fact
        self.update = update
        _text = State(initialValue: fact.text)
        _category = State(initialValue: fact.category)
        _status = State(initialValue: fact.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Modifier le fait").font(.title2.weight(.semibold))
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(height: 92)
                .vaultPanel()
                .accessibilityLabel("Texte du fait")
            HStack {
                Picker("Catégorie", selection: $category) {
                    ForEach(FactCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Statut", selection: $status) {
                    ForEach(FactStatus.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Preuve dans le PDF · page \(fact.page)", systemImage: "quote.opening")
                    .font(.subheadline.weight(.semibold))
                ScrollView {
                    Text(fact.evidence)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
            }
            .padding(12)
            .vaultPanel()
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    do {
                        try update(text, category, status)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 510)
    }
}
