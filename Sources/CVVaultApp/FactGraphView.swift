import AppKit
import CVVaultCore
import SwiftUI

struct FactGraphView: View {
    @ObservedObject var model: VaultModel
    @State private var filter = GraphFilter()
    @State private var graph = GraphData()
    @State private var loading = true
    @State private var loadError: String?
    @State private var selection: GraphFact?
    @State private var inspectedFact: CVFact?
    @State private var inspectionError: String?
    @State private var fixedZoom: CGFloat?
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(
                title: "Graphe des faits",
                subtitle: "Chaque fait est relié à sa catégorie et à son PDF source."
            ) {
                if !graph.rows.isEmpty {
                    Text(formattedCount(graph.factCount, "fait affiché", "faits affichés"))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            filters
            GeometryReader { geometry in
                let showSide = selection != nil && geometry.size.width >= 830
                let layout = showSide ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
                layout {
                    graphPanel
                    if selection != nil {
                        inspector.frame(
                            width: showSide ? 258 : nil,
                            height: showSide ? nil : min(206, geometry.size.height * 0.46)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: GraphRequest(filter: filter, revision: model.revision, isReady: model.isReady)) {
            await loadGraph()
        }
        .task(id: GraphInspection(factID: selection?.id, revision: model.revision)) {
            await inspectSelection()
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                queryField
                filterMenus
            }
            VStack(alignment: .leading, spacing: 8) {
                queryField
                filterMenus
            }
        }
        .controlSize(.regular)
    }

    private var queryField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Rechercher un fait ou son extrait", text: $filter.query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Rechercher un fait ou son extrait")
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
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .vaultPanel(radius: 6)
        .frame(minWidth: 175)
    }

    private var filterMenus: some View {
        HStack(spacing: 8) {
            Picker("PDF", selection: $filter.sourceID) {
                Text("Tous les PDF").tag(String?.none)
                ForEach(model.sources) { source in
                    Text(source.displayName).tag(Optional(source.id))
                }
            }
            .labelsHidden()
            .frame(width: 140)
            Picker("Catégorie", selection: $filter.category) {
                Text("Catégories").tag(FactCategory?.none)
                ForEach(FactCategory.allCases, id: \.self) { category in
                    Text(category.displayName).tag(Optional(category))
                }
            }
            .labelsHidden()
            .frame(width: 148)
            Picker("Statut", selection: $filter.status) {
                Text("Statuts").tag(FactStatus?.none)
                ForEach(FactStatus.allCases, id: \.self) { status in
                    Text(status.displayName).tag(Optional(status))
                }
            }
            .labelsHidden()
            .frame(width: 120)
            if filter.isRestricted {
                Button("Tout afficher", systemImage: "line.3.horizontal.decrease.circle") {
                    filter = GraphFilter()
                }
                .labelStyle(.iconOnly)
                .help("Réinitialiser les filtres")
            }
        }
    }

    private var graphPanel: some View {
        GeometryReader { geometry in
            let fitZoom = min(1.25, max(0.72, (geometry.size.width - 2) / GraphMetrics.baseWidth))
            let currentZoom = fixedZoom ?? fitZoom
            let zoom = bounded(currentZoom * magnification)
            VStack(spacing: 0) {
                graphToolbar(zoom: currentZoom)
                Divider()
                graphViewport(metrics: GraphMetrics(zoom: zoom), baseZoom: currentZoom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .vaultPanel()
        }
    }

    private func graphToolbar(zoom: CGFloat) -> some View {
        HStack(spacing: 11) {
            ForEach(FactStatus.allCases, id: \.self) { status in
                HStack(spacing: 5) {
                    Circle()
                        .fill(status.statusColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(status.displayName)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            Spacer(minLength: 7)
            HStack(spacing: 6) {
                Button("Réduire le zoom", systemImage: "minus") {
                    fixedZoom = bounded(zoom / 1.18)
                }
                .disabled(zoom <= 0.55)
                Button("Ajuster à la largeur", systemImage: "arrow.left.and.right") {
                    fixedZoom = nil
                }
                .help("Ajuster à la largeur")
                Button("Augmenter le zoom", systemImage: "plus") {
                    fixedZoom = bounded(zoom * 1.18)
                }
                .disabled(zoom >= 1.70)
                Text("\(Int((zoom * 100).rounded())) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
                    .accessibilityLabel("Zoom")
                    .accessibilityValue("\(Int((zoom * 100).rounded())) pour cent")
            }
            .controlSize(.small)
            .labelStyle(.iconOnly)
            .disabled(graph.rows.isEmpty)
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
    }

    private func graphViewport(metrics: GraphMetrics, baseZoom: CGFloat) -> some View {
        ZStack {
            GraphBackdrop()
            if let loadError {
                ContentUnavailableView(
                    "Impossible de lire le graphe",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if graph.rows.isEmpty {
                if loading {
                    ProgressView("Lecture des faits…")
                } else {
                    ContentUnavailableView(
                        "Aucun fait à afficher",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text(filter.isRestricted
                            ? "Modifiez les filtres pour retrouver des faits."
                            : "Après l’import d’un PDF, ses faits apparaissent ici.")
                    )
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                ForEach(graph.rows) { row in
                                    GraphRowView(
                                        row: row,
                                        metrics: metrics,
                                        selection: selection,
                                        selectSource: { id in
                                            filter.sourceID = filter.sourceID == id ? nil : id
                                        },
                                        openSource: { id in model.openOriginal(of: id) },
                                        selectCategory: { sourceID, category in
                                            filter.sourceID = sourceID
                                            filter.category = filter.category == category ? nil : category
                                        },
                                        selectFact: { fact in
                                            inspect(fact)
                                        }
                                    )
                                }
                            } header: {
                                columnHeaders(metrics: metrics)
                            }
                        }
                        .frame(width: metrics.width)
                        .padding(.bottom, 14)
                    }
                    .onChange(of: selection?.id) { _, id in
                        if let id, graph.ids.contains(id) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($magnification) { value, state, _ in state = value.magnification }
                        .onEnded { value in
                            fixedZoom = bounded(baseZoom * value.magnification)
                        }
                )
                .accessibilityLabel("Relations entre les PDF, les catégories et les faits")
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .vaultPanel(radius: 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Mise à jour du graphe")
                }
            }
        }
    }

    private func columnHeaders(metrics: GraphMetrics) -> some View {
        HStack(spacing: 0) {
            columnLabel("PDF source", symbol: "doc", width: metrics.categoryX - metrics.sourceX, zoom: metrics.zoom)
            columnLabel("Catégorie", symbol: "folder", width: metrics.factX - metrics.categoryX, zoom: metrics.zoom)
            columnLabel("Fait", symbol: "circle.hexagongrid", width: metrics.factWidth, zoom: metrics.zoom)
        }
        .padding(.leading, metrics.sourceX)
        .padding(.trailing, metrics.margin)
        .frame(height: max(29, 34 * metrics.zoom))
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func columnLabel(_ title: String, symbol: String, width: CGFloat, zoom: CGFloat) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11 * zoom, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Détail du fait", systemImage: "sidebar.right")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Fermer le détail", systemImage: "xmark") { inspect(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            ScrollView {
                if let fact = inspectedFact {
                    factDetails(fact)
                        .padding(14)
                } else if let inspectionError {
                    Text(inspectionError)
                        .foregroundStyle(.secondary)
                        .padding(14)
                } else {
                    ProgressView().padding(14)
                }
            }
            if let fact = inspectedFact {
                Divider()
                HStack {
                    Button("Voir le PDF", systemImage: "doc.text") {
                        model.openOriginal(of: fact.sourceID, page: fact.page)
                    }
                    if fact.status == .pending {
                        Button("Valider", systemImage: "checkmark") {
                            model.changeStatus(fact, status: .verified)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
            }
        }
        .vaultPanel()
    }

    private func factDetails(_ fact: CVFact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label(fact.category.displayName, systemImage: fact.category.symbol)
                    .foregroundStyle(.secondary)
                Label(fact.status.displayName, systemImage: "circle.fill")
                    .foregroundStyle(fact.status.statusColor)
            }
            .font(.caption)
            Text(fact.text)
                .font(.body.weight(.medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Label("Extrait source", systemImage: "quote.opening").font(.subheadline.weight(.semibold))
                if let source = model.sources.first(where: { $0.id == fact.sourceID }) {
                    Text("\(source.displayName) · page \(fact.page)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(fact.evidence.isEmpty ? "Aucun extrait enregistré." : fact.evidence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadGraph() async {
        guard model.isReady else { return }
        let filter = filter
        let sources = model.sources
        loading = true
        loadError = nil
        do {
            if !filter.query.isEmpty {
                try await Task.sleep(for: .milliseconds(160))
            }
            let database = try model.requireDatabase()
            let worker = Task.detached(priority: .userInitiated) {
                try GraphData.load(database: database, sources: sources, filter: filter)
            }
            let data = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            graph = data
            if let selection, !data.ids.contains(selection.id) {
                inspect(nil)
            }
            loading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            graph = GraphData()
            loadError = error.localizedDescription
            loading = false
        }
    }

    private func inspect(_ fact: GraphFact?) {
        if selection?.id == fact?.id { return }
        selection = fact
        inspectedFact = nil
        inspectionError = nil
    }

    private func inspectSelection() async {
        guard let id = selection?.id else { return }
        do {
            let database = try model.requireDatabase()
            let fact = try await Task.detached { try database.fact(id: id) }.value
            try Task.checkCancellation()
            guard selection?.id == id else { return }
            inspectedFact = fact
            if fact == nil { inspectionError = "Ce fait n’est plus disponible dans la base." }
        } catch {
            guard !Task.isCancelled, selection?.id == id else { return }
            inspectedFact = nil
            inspectionError = error.localizedDescription
        }
    }

    private func bounded(_ zoom: CGFloat) -> CGFloat { min(1.70, max(0.55, zoom)) }
}

private struct GraphFilter: Hashable, Sendable {
    var query = ""
    var sourceID: String?
    var category: FactCategory?
    var status: FactStatus?

    var isRestricted: Bool {
        sourceID != nil || category != nil || status != nil ||
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filtersFacts: Bool {
        category != nil || status != nil ||
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct GraphRequest: Hashable {
    let filter: GraphFilter
    let revision: Int
    let isReady: Bool
}

private struct GraphInspection: Hashable {
    let factID: String?
    let revision: Int
}

private struct GraphFact: Sendable {
    let id: String
    let sourceID: String
    let page: Int
    let category: FactCategory
    let status: FactStatus
    let preview: String

    init(_ fact: CVFact) {
        id = fact.id
        sourceID = fact.sourceID
        page = fact.page
        category = fact.category
        status = fact.status
        let summary = String(fact.text.prefix(200))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        preview = summary.isEmpty ? fact.category.rawValue : summary
    }
}

private struct GraphRow: Identifiable, Sendable {
    var id: String { fact?.id ?? "source:" + source.id }
    let source: CVSource
    let fact: GraphFact?
    let sourceFactCount: Int
    let categoryFactCount: Int
    let showSource: Bool
    let showCategory: Bool
    let sourceLineUp: Bool
    let sourceLineDown: Bool
    let categoryLineUp: Bool
    let categoryLineDown: Bool
}

private struct GraphData: Sendable {
    var rows: [GraphRow] = []
    var ids: Set<String> = []
    var factCount: Int { ids.count }

    static func load(database: KnowledgeBase, sources: [CVSource], filter: GraphFilter) throws -> GraphData {
        var result = GraphData()
        let visibleSources = sources.filter { filter.sourceID == nil || $0.id == filter.sourceID }
        for source in visibleSources {
            try Task.checkCancellation()
            let groups = try loadGroups(database: database, sourceID: source.id, filter: filter)
            let categories = FactCategory.allCases.filter { groups[$0] != nil }
            let total = groups.values.reduce(0) { $0 + $1.count }
            if categories.isEmpty && !filter.filtersFacts {
                result.rows.append(GraphRow(
                    source: source, fact: nil, sourceFactCount: 0, categoryFactCount: 0,
                    showSource: true, showCategory: false, sourceLineUp: false, sourceLineDown: false,
                    categoryLineUp: false, categoryLineDown: false
                ))
            }
            for (categoryIndex, category) in categories.enumerated() {
                guard let facts = groups[category] else { continue }
                for (index, fact) in facts.enumerated() {
                    result.rows.append(GraphRow(
                        source: source,
                        fact: fact,
                        sourceFactCount: total,
                        categoryFactCount: facts.count,
                        showSource: categoryIndex == 0 && index == 0,
                        showCategory: index == 0,
                        sourceLineUp: index == 0 ? categoryIndex > 0 : categoryIndex < categories.count - 1,
                        sourceLineDown: categoryIndex < categories.count - 1,
                        categoryLineUp: index > 0,
                        categoryLineDown: index < facts.count - 1
                    ))
                    result.ids.insert(fact.id)
                }
            }
        }
        return result
    }

    private static func loadGroups(
        database: KnowledgeBase,
        sourceID: String,
        filter: GraphFilter
    ) throws -> [FactCategory: [GraphFact]] {
        let limit = 250
        var offset = 0
        var groups: [FactCategory: [GraphFact]] = [:]
        while true {
            try Task.checkCancellation()
            let batch = try database.searchFacts(
                query: filter.query,
                category: filter.category,
                status: filter.status,
                sourceID: sourceID,
                limit: limit,
                offset: offset
            )
            for row in batch {
                let fact = GraphFact(row)
                groups[fact.category, default: []].append(fact)
            }
            if batch.count < limit { return groups }
            offset += batch.count
        }
    }
}

private struct GraphMetrics {
    static let baseWidth: CGFloat = 722
    let zoom: CGFloat
    var margin: CGFloat { 18 * zoom }
    var width: CGFloat { Self.baseWidth * zoom }
    var sourceX: CGFloat { margin }
    var categoryX: CGFloat { 214 * zoom }
    var factX: CGFloat { 410 * zoom }
    var sourceWidth: CGFloat { 151 * zoom }
    var categoryWidth: CGFloat { 151 * zoom }
    var factWidth: CGFloat { width - factX - margin }
    var nodeHeight: CGFloat { 42 * zoom }
    var height: CGFloat { 54 * zoom }
    var sourceTrunk: CGFloat { 190 * zoom }
    var categoryTrunk: CGFloat { 386 * zoom }
}

private struct GraphRowView: View {
    let row: GraphRow
    let metrics: GraphMetrics
    let selection: GraphFact?
    let selectSource: (String) -> Void
    let openSource: (String) -> Void
    let selectCategory: (String, FactCategory) -> Void
    let selectFact: (GraphFact) -> Void

    private var sourceActive: Bool { selection?.sourceID == row.source.id }
    private var categoryActive: Bool { sourceActive && selection?.category == row.fact?.category }

    var body: some View {
        ZStack(alignment: .topLeading) {
            edges
            if row.showSource {
                node(
                    row.source.displayName,
                    caption: formattedCount(row.sourceFactCount, "fait", "faits"),
                    symbol: "doc.text.fill", color: .blue,
                    width: metrics.sourceWidth, active: sourceActive
                ) { selectSource(row.source.id) }
                .help("Afficher ou isoler les faits de ce PDF")
                .contextMenu {
                    Button("Voir le PDF", systemImage: "doc.text") { openSource(row.source.id) }
                }
                .offset(x: metrics.sourceX, y: nodeY)
            }
            if let fact = row.fact {
                if row.showCategory {
                    node(
                        fact.category.displayName,
                        caption: formattedCount(row.categoryFactCount, "fait", "faits"),
                        symbol: fact.category.symbol, color: fact.category.graphColor,
                        width: metrics.categoryWidth, active: categoryActive
                    ) { selectCategory(row.source.id, fact.category) }
                    .help("Filtrer sur cette catégorie dans ce PDF")
                    .offset(x: metrics.categoryX, y: nodeY)
                }
                node(
                    fact.preview,
                    caption: "Page \(fact.page) · \(fact.status.displayName)",
                    symbol: "smallcircle.filled.circle", color: fact.status.statusColor,
                    width: metrics.factWidth, active: selection?.id == fact.id
                ) { selectFact(fact) }
                .help("Voir le texte complet et l’extrait source")
                .offset(x: metrics.factX, y: nodeY)
            }
        }
        .frame(width: metrics.width, height: metrics.height)
        .padding(.top, row.showSource ? 10 * metrics.zoom : 0)
    }

    private var nodeY: CGFloat { (metrics.height - metrics.nodeHeight) / 2 }

    private func node(
        _ title: String, caption: String, symbol: String, color: Color,
        width: CGFloat, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7 * metrics.zoom) {
                VaultIcon(symbol: symbol, color: color, size: 23 * metrics.zoom)
                VStack(alignment: .leading, spacing: 2 * metrics.zoom) {
                    Text(title)
                        .lineLimit(1)
                        .font(.system(size: 11 * metrics.zoom, weight: .semibold))
                    Text(caption)
                        .lineLimit(1)
                        .font(.system(size: 9.5 * metrics.zoom))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7 * metrics.zoom)
            .frame(width: width, height: metrics.nodeHeight, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 8 * metrics.zoom)
                shape.fill(VaultStyle.panel)
                    .overlay { shape.fill(color.opacity(active ? 0.11 : 0.035)) }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8 * metrics.zoom)
                    .strokeBorder(color.opacity(active ? 0.85 : 0.27), lineWidth: active ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8 * metrics.zoom))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(caption)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var edges: some View {
        Canvas { context, size in
            guard let fact = row.fact else { return }
            let mid = size.height / 2
            let categoryColor = fact.category.graphColor
            let categoryStart = metrics.categoryX + metrics.categoryWidth
            let sourceEnd = metrics.sourceX + metrics.sourceWidth
            let sourceColor = Color.blue
            let strongLeaf = selection?.id == fact.id
            func draw(_ points: [CGPoint], color: Color, strong: Bool) {
                var path = Path()
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                context.stroke(
                    path,
                    with: .color(color.opacity(strong ? 0.83 : 0.33)),
                    style: StrokeStyle(
                        lineWidth: (strong ? 1.9 : 1.15) * metrics.zoom,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }

            let sourceJoin = CGPoint(x: metrics.sourceTrunk, y: mid)
            if row.showSource {
                draw([CGPoint(x: sourceEnd, y: mid), sourceJoin], color: sourceColor, strong: sourceActive)
            }
            if row.sourceLineUp || row.sourceLineDown {
                draw([
                    CGPoint(x: metrics.sourceTrunk, y: row.sourceLineUp ? 0 : mid),
                    CGPoint(x: metrics.sourceTrunk, y: row.sourceLineDown ? size.height : mid)
                ], color: sourceColor, strong: sourceActive)
            }
            if row.showCategory {
                draw([sourceJoin, CGPoint(x: metrics.categoryX, y: mid)], color: categoryColor, strong: categoryActive)
            }

            let categoryJoin = CGPoint(x: metrics.categoryTrunk, y: mid)
            if row.showCategory {
                draw([CGPoint(x: categoryStart, y: mid), categoryJoin], color: categoryColor, strong: categoryActive)
            }
            if row.categoryLineUp || row.categoryLineDown {
                draw([
                    CGPoint(x: metrics.categoryTrunk, y: row.categoryLineUp ? 0 : mid),
                    CGPoint(x: metrics.categoryTrunk, y: row.categoryLineDown ? size.height : mid)
                ], color: categoryColor, strong: categoryActive)
            }
            draw([categoryJoin, CGPoint(x: metrics.factX, y: mid)], color: categoryColor, strong: strongLeaf)
            let dot = 4.0 * metrics.zoom
            context.fill(
                Path(ellipseIn: CGRect(x: categoryJoin.x - dot / 2, y: mid - dot / 2, width: dot, height: dot)),
                with: .color(categoryColor.opacity(strongLeaf ? 0.93 : 0.46))
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GraphBackdrop: View {
    var body: some View {
        Canvas { context, size in
            var dots = Path()
            for x in stride(from: 10.0, to: size.width, by: 16) {
                for y in stride(from: 10.0, to: size.height, by: 16) {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.25, height: 1.25))
                }
            }
            context.fill(dots, with: .color(.secondary.opacity(0.23)))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityHidden(true)
    }
}

private extension FactCategory {
    var graphColor: Color {
        switch self {
        case .identity, .contact: .blue
        case .summary, .experience: VaultStyle.accent
        case .skills, .projects: .indigo
        case .education, .certifications: .purple
        case .languages, .publications: .teal
        case .awards: .orange
        case .other: .secondary
        }
    }
}
