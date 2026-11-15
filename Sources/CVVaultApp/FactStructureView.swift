import CVVaultCore
import SwiftUI

struct FactStructureView: View {
    @ObservedObject var model: VaultModel
    @State private var sourceID: String?
    @State private var category: FactCategory?
    @State private var status: FactStatus?
    @State private var snapshot: Snapshot?
    @State private var inspected: CVFact?

    private var selectedSource: CVSource? {
        model.sources.first { $0.id == sourceID } ?? model.sources.first
    }

    var body: some View {
        let request = Request(sourceID: selectedSource?.id, revision: model.revision)
        VaultPage {
            PageTitle(title: "CV structuré", subtitle: "Parcourez les entrées du CV et la preuve de chaque fait.") {
                EmptyView()
            }
            if let source = selectedSource {
                filters
                if let snapshot, snapshot.sourceID == source.id {
                    if let error = snapshot.error {
                        VaultEmpty(title: "Structure indisponible", description: error,
                                   symbol: "exclamationmark.triangle")
                    } else {
                        results(snapshot.entries)
                    }
                } else {
                    ProgressView("Chargement des faits")
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
            } else {
                VaultEmpty(title: "Aucun PDF importé", description: "Importez un PDF pour afficher ses faits.",
                           symbol: "doc")
            }
        }
        .task(id: request) { await load(request) }
        .sheet(item: $inspected) { fact in
            StructuredFactEvidence(
                fact: fact, sourceName: model.sources.first { $0.id == fact.sourceID }?.displayName
            ) {
                inspected = nil
                model.openOriginal(of: fact.sourceID, page: fact.page)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: Binding(get: { selectedSource?.id }, set: { sourceID = $0 })) {
                ForEach(model.sources) { source in
                    Text(source.displayName).tag(Optional(source.id))
                }
            }
            .frame(maxWidth: 270)
            Picker("Catégorie", selection: $category) {
                Text("Toutes").tag(FactCategory?.none)
                ForEach(FactCategory.allCases, id: \.self) { item in
                    Text(item.displayName).tag(Optional(item))
                }
            }
            .frame(maxWidth: 180)
            Picker("Statut", selection: $status) {
                Text("Tous").tag(FactStatus?.none)
                ForEach(FactStatus.allCases, id: \.self) { item in
                    Text(item.displayName).tag(Optional(item))
                }
            }
            .frame(maxWidth: 163)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func results(_ entries: [CVStructuredEntry]) -> some View {
        let visible = entries.compactMap { entry -> VisibleEntry? in
            guard category == nil || category == entry.category else { return nil }
            let fields = entry.fields.filter { status == nil || status == $0.fact.status }
            guard !fields.isEmpty else { return nil }
            return VisibleEntry(entry: entry, fields: fields)
        }
        if visible.isEmpty {
            VaultEmpty(
                title: "Aucun fait à afficher",
                description: entries.isEmpty ? "Ce PDF ne contient aucun fait extrait." : "Modifiez la catégorie ou le statut.",
                symbol: "list.bullet.indent"
            )
        } else {
            let grouped = Dictionary(grouping: visible, by: { $0.entry.category })
            let entriesCount = formattedCount(visible.count, "entrée", "entrées")
            let factsCount = formattedCount(visible.reduce(0) { $0 + $1.fields.count }, "fait", "faits")
            VStack(alignment: .leading, spacing: 14) {
                Text("\(entriesCount) · \(factsCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(FactCategory.allCases.filter { grouped[$0] != nil }, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 9) {
                        SectionTitle(title: item.displayName, symbol: item.symbol)
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(grouped[item, default: []]) { group in
                                entryCard(group)
                            }
                        }
                    }
                }
            }
        }
    }

    private func entryCard(_ group: VisibleEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = group.entry.fields.first(where: { $0.role == .title }),
               !group.fields.contains(where: { $0.id == title.id }) {
                Text(title.fact.text)
                    .font(.headline)
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .padding(.top, 11)
            }
            ForEach(Array(group.fields.enumerated()), id: \.element.id) { index, field in
                if index != 0 { Divider().padding(.horizontal, 14) }
                fieldRow(field)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vaultPanel()
    }

    private func fieldRow(_ field: CVStructuredField) -> some View {
        let fact = field.fact
        return HStack(alignment: .top, spacing: 12) {
            Text(field.role.displayName(in: fact.category))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
                .padding(.top, 2)
            Text(fact.text)
                .font(field.role == .title ? .headline : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text("p. \(fact.page)")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Page \(fact.page)")
                reviewMenu(fact)
                Button("Voir la preuve, page \(fact.page)", systemImage: "doc.text.magnifyingglass") {
                    inspected = fact
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Voir la preuve")
            }
            .font(.caption)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func reviewMenu(_ fact: CVFact) -> some View {
        Menu {
            ForEach(FactStatus.allCases.filter { $0 != fact.status }, id: \.self) { item in
                Button(item.reviewLabel) { model.changeStatus(fact, status: item) }
            }
        } label: {
            Label(fact.status.displayName, systemImage: "circle.fill")
                .foregroundStyle(fact.status.statusColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 83, alignment: .leading)
        .accessibilityLabel("Statut du fait, \(fact.status.displayName)")
        .help("Changer le statut du fait")
    }

    private func load(_ request: Request) async {
        guard let sourceID = request.sourceID else { return }
        do {
            let database = try model.requireDatabase()
            let entries = try await Task.detached(priority: .userInitiated) {
                try database.factStructure(sourceID: sourceID)
            }.value
            try Task.checkCancellation()
            snapshot = Snapshot(sourceID: sourceID, entries: entries, error: nil)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            snapshot = Snapshot(sourceID: sourceID, entries: [], error: error.localizedDescription)
        }
    }

    private struct Request: Hashable {
        let sourceID: String?
        let revision: Int
    }

    private struct Snapshot {
        let sourceID: String
        let entries: [CVStructuredEntry]
        let error: String?
    }

    private struct VisibleEntry: Identifiable {
        let entry: CVStructuredEntry
        let fields: [CVStructuredField]
        var id: String { entry.id }
    }
}

private struct StructuredFactEvidence: View {
    let fact: CVFact
    let sourceName: String?
    var openOriginal: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Preuve dans le PDF").font(.title2.weight(.semibold))
            Text([sourceName, "Page \(fact.page)"].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(fact.evidence)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 80, maxHeight: 300)
            .vaultPanel()
            HStack {
                Text("Identifiant du fait").foregroundStyle(.secondary)
                Text(fact.id).monospaced().textSelection(.enabled)
            }
            .font(.caption)
            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Voir la page du PDF", systemImage: "arrow.up.right.square") { openOriginal() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

private extension CVFactRole {
    func displayName(in category: FactCategory) -> String {
        switch self {
        case .title: category == .experience ? "Poste" : "Intitulé"
        case .organization: category == .education ? "Établissement" : "Organisation"
        case .date: "Dates"
        case .achievement: "Réalisation"
        case .skill: "Compétence"
        case .language: "Langue"
        case .link: "Lien"
        case .detail: "Détail"
        }
    }
}

private extension FactStatus {
    var reviewLabel: String {
        switch self {
        case .pending: "Remettre à vérifier"
        case .verified: "Valider"
        case .rejected: "Écarter"
        }
    }
}
