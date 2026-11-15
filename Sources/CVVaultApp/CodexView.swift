import AppKit
import SwiftUI

struct CodexView: View {
    @State private var copied: String?

    var body: some View {
        VaultPage {
            PageTitle(title: "Codex · MCP", subtitle: "Composez des CV Typst dans Codex à partir de votre bibliothèque.") {
                Link(destination: URL(string: "https://learn.chatgpt.com/docs/extend/mcp?surface=cli")!) {
                    Label("Guide Codex", systemImage: "arrow.up.right")
                }
            }

            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 11) {
                    VaultIcon(symbol: "terminal", size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ajouter CV Vault à Codex").font(.headline)
                        Text("Exécutez cette commande dans Terminal, puis redémarrez Codex.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                codeBlock(command, key: "installation")
                if !serverAvailable {
                    Label("Le serveur MCP est introuvable à côté de l’app. Compilez les deux exécutables ou utilisez le paquet .app.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text("Le serveur local lit le texte extrait et les faits des CV importés. Les informations consultées par Codex entrent dans la conversation où vous utilisez le serveur.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(17)
            .vaultPanel()

            VStack(alignment: .leading, spacing: 11) {
                SectionTitle(title: "Outils disponibles", symbol: "wrench.and.screwdriver")
                VStack(spacing: 0) {
                    toolRow("list_sources", "Lister les PDF de la bibliothèque", symbol: "doc.on.doc")
                    Divider().padding(.leading, 49)
                    toolRow("get_source", "Lire les pages extraites et leurs liens", symbol: "doc.text.magnifyingglass")
                    Divider().padding(.leading, 49)
                    toolRow("search_facts", "Trouver des faits et leurs preuves", symbol: "magnifyingglass")
                    Divider().padding(.leading, 49)
                    toolRow("generate_cv", "Générer et enregistrer un CV Typst", symbol: "arrow.down.doc")
                }
                .vaultPanel()
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "À essayer dans Codex", symbol: "text.bubble")
                codeBlock("Crée un CV Typst en français pour un poste de [poste]. Garde les faits validés les plus pertinents d’une seule source, place les plus convaincants en premier et enregistre le fichier en cv-cible.typ.", key: "prompt", monospace: false)
            }
        }
        .task(id: copied) {
            guard copied != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = nil }
        }
    }

    private var serverPath: String {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("cv-vault-mcp").path
            ?? "/Applications/CV Vault.app/Contents/MacOS/cv-vault-mcp"
    }

    private var serverAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: serverPath)
    }

    private var command: String {
        let quotedPath = "'" + serverPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "codex mcp add cv-vault -- \(quotedPath)"
    }

    private func codeBlock(_ value: String, key: String, monospace: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(value)
                .font(.system(.callout, design: monospace ? .monospaced : .default))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == key ? "Copié" : "Copier", systemImage: copied == key ? "checkmark" : "document.on.document") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = key
            }
            .buttonStyle(.bordered)
            .fixedSize()
        }
        .padding(11)
        .vaultPanel(radius: 8)
    }

    private func toolRow(_ name: String, _ description: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            VaultIcon(symbol: symbol, size: 27)
            Text(name)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .frame(width: 120, alignment: .leading)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
    }
}
