# CV Vault

App macOS native pour transformer un CV PDF en base de connaissances locale et composer des CV Typst avec Codex.

**Importer un PDF → vérifier les faits → sélectionner les éléments d’un CV → exporter un `.typ`.**

## Démarrage

CV Vault fonctionne sur **macOS 14 ou plus récent**, sur Apple Silicon et Intel.

- Téléchargez l’archive macOS depuis les [versions GitHub](https://github.com/Fran-cois/cv-vault/releases). Décompressez-la, puis déplacez **CV Vault.app** dans Applications.
- Ou construisez l’app localement avec Swift 6 et les outils Xcode :

  ```sh
  git clone https://github.com/Fran-cois/cv-vault.git
  cd cv-vault
  ./build.sh --install
  open "$HOME/Applications/CV Vault.app"
  ```

L’archive du projet n’est pas notariée par Apple. Si macOS bloque son ouverture, la compilation locale ci-dessus est une alternative.

1. Cliquez sur **Importer un PDF** et sélectionnez votre CV.
2. Dans **Faits**, comparez les propositions au texte source. Corrigez le texte ou la catégorie, puis vérifiez ou écartez les éléments. Les faits vérifiés restent reliés à leur page et à leur extrait d’origine.
3. Exportez un CV depuis l’app ou composez une variante avec Codex. Le fichier `.typ` est autonome et modifiable. Si vous voulez un PDF, installez [Typst](https://github.com/typst/typst) et lancez `typst compile "Mon CV.typ"`.

L’import combine le texte intégré au PDF et la reconnaissance locale de Vision pour les pages scannées. Il conserve l’original, le texte extrait par page et les liens détectés. Le classement automatique couvre les rubriques courantes des CV français et anglais, ainsi que les informations sans rubrique reconnue. Une mise en page complexe ou un scan de mauvaise qualité peut fausser l’ordre des lignes et la reconnaissance : consultez le PDF en cas de doute. L’app signale les pages qu’elle n’a pas pu lire. Chaque PDF est limité à 50 Mio et 100 pages.

## Connecter Codex

Dans l’onglet **Codex** de l’app, copiez la commande qui correspond à son emplacement. Pour une installation effectuée par `build.sh --install` :

```sh
codex mcp add cv-vault -- "$HOME/Applications/CV Vault.app/Contents/MacOS/cv-vault-mcp"
codex mcp get cv-vault
```

Le serveur s’exécute en local sur STDIO, même quand l’app est fermée. Après l’ajout, ouvrez une nouvelle session Codex ou redémarrez le client s’il ne voit pas le serveur. Vous pouvez aussi l’ajouter dans les réglages MCP de l’app Codex en choisissant STDIO et en indiquant le chemin complet du binaire. Voir la [documentation Codex sur les serveurs MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

Exemple de demande :

> Avec CV Vault, prépare un CV pour un poste de lead data. Choisis les faits vérifiés qui démontrent le mieux mon expérience pour ce poste. Garde les dates et chiffres d’origine, puis exporte un fichier Typst nommé « CV Lead Data ».

| Outil MCP | Usage |
| --- | --- |
| `list_sources` | Lister les PDF et leur état d’extraction. |
| `get_source` | Lire le texte et les liens d’un groupe de pages. |
| `search_facts` | Chercher dans la base par texte, rubrique, source ou statut. |
| `generate_cv` | Composer un `.typ` à partir d’une liste ordonnée d’identifiants de faits vérifiés d’un même PDF, et l’enregistrer si un nom de fichier est fourni. |

Le choix `fr` ou `en` règle les titres de rubrique et la typographie ; le texte des faits reste dans sa langue d’origine. Le serveur permet de lire les sources et de générer des exports. La validation et la modification des faits restent dans l’app.

## Données locales

Par défaut, l’app et le serveur partagent `~/Library/Application Support/CV Vault/`. La base `knowledge.sqlite3` contient les PDF originaux, les pages et les faits ; `Exports/` contient les fichiers Typst. Les PDF identiques sont détectés par leur empreinte SHA-256. Supprimer une source dans la bibliothèque supprime les pages et faits associés ; les exports déjà créés restent disponibles.

CV Vault ne fait aucun appel à un service externe et ne demande ni compte ni clé API. Quand vous demandez à Codex de consulter la base, le résultat des outils MCP peut contenir des informations personnelles et fait partie du contexte de la session Codex. Les fichiers SQLite et Typst ne sont pas chiffrés par CV Vault.

Pour développer ou tester avec une base séparée, définissez `CV_VAULT_HOME` avec un chemin absolu pour les deux exécutables.

## Développement

```sh
swift test
swift build
python3 scripts/test-mcp.py "$(swift build --show-bin-path)/cv-vault-mcp"
./build.sh --universal --zip
```

- **CVVaultCore** : import PDFKit et Vision, base SQLite, faits et rendu Typst.
- **CVVaultApp** : interface native SwiftUI.
- **CVVaultMCP** : serveur JSON-RPC sur STDIO.
- **build.sh** : crée l’app et son icône, signe le bundle et prépare l’archive. La signature est ad hoc par défaut. Pour utiliser votre certificat Developer ID, réglez `SIGN_IDENTITY`.

Les tests n’utilisent que des données fictives, dans des répertoires temporaires. Typst est facultatif à l’usage et sert à vérifier la compilation réelle dans l’intégration.

[Licence MIT](LICENSE)
