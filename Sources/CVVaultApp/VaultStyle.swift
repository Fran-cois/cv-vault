import AppKit
import CVVaultCore
import SwiftUI

enum VaultStyle {
    static let accent = Color(nsColor: NSColor(
        name: "CVVaultAccent",
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.35, green: 0.83, blue: 0.71, alpha: 1)
                : NSColor(srgbRed: 0.05, green: 0.42, blue: 0.35, alpha: 1)
        }
    ))
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.56)
}

extension View {
    func vaultPanel(radius: CGFloat = 11) -> some View {
        background(VaultStyle.panel, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(VaultStyle.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct VaultIcon: View {
    let symbol: String
    var color = VaultStyle.accent
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

struct VaultPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .frame(maxWidth: 1120)
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct PageTitle<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            actions
        }
    }
}

struct SectionTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

struct VaultEmpty: View {
    let title: String
    let description: String
    let symbol: String

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            VaultIcon(symbol: symbol, color: .secondary, size: 40)
            Text(title).font(.headline)
            Text(description)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .vaultPanel()
    }
}

func formattedCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count.formatted()) \(count == 1 ? singular : plural)"
}

extension FactCategory {
    var displayName: String {
        switch self {
        case .identity: "Identité"
        case .contact: "Coordonnées"
        case .summary: "Profil"
        case .experience: "Expériences"
        case .education: "Formation"
        case .skills: "Compétences"
        case .languages: "Langues"
        case .certifications: "Certifications"
        case .projects: "Projets"
        case .publications: "Publications"
        case .awards: "Distinctions"
        case .other: "Autres"
        }
    }

    var symbol: String {
        switch self {
        case .identity: "person.crop.circle"
        case .contact: "at"
        case .summary: "text.alignleft"
        case .experience: "briefcase"
        case .education: "graduationcap"
        case .skills: "wrench.and.screwdriver"
        case .languages: "character.bubble"
        case .certifications: "checkmark.seal"
        case .projects: "folder"
        case .publications: "book"
        case .awards: "medal"
        case .other: "tray"
        }
    }
}

extension FactStatus {
    var displayName: String {
        switch self {
        case .pending: "À vérifier"
        case .verified: "Validé"
        case .rejected: "Écarté"
        }
    }

    var statusColor: Color {
        switch self {
        case .pending: .orange
        case .verified: VaultStyle.accent
        case .rejected: .secondary
        }
    }
}

extension PageMethod {
    var displayName: String {
        switch self {
        case .text: "Texte natif"
        case .ocr: "OCR"
        case .unreadable: "Illisible"
        }
    }
}

extension CVSource {
    var displayName: String { (name as NSString).deletingPathExtension }
}
