# CV Vault

App macOS native pour transformer un CV PDF en base de connaissances locale, explorer ses faits en graphe et composer des CV Typst avec Codex.

**Importer un PDF → explorer et vérifier les faits → composer un CV → exporter en Typst ou PDF.**

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
3. Ouvrez **Graphe des faits** pour parcourir les liens entre PDF, rubriques et faits. Zoomez ou filtrez par source, rubrique ou statut, puis sélectionnez un fait pour lire son texte, son extrait d’origine et ouvrir la page correspondante.
4. Dans **CV Typst**, sélectionnez vos faits vérifiés, un des cinq styles et le format A4 ou US Letter. Exportez un fichier `.typ` autonome et modifiable. Avec [Typst](https://github.com/typst/typst) installé, vous pouvez également prévisualiser le CV, vérifier son nombre de pages et enregistrer le PDF dans l’app.

Comparez les cinq styles sur le même CV fictif. [Aperçu PDF](https://github.com/Fran-cois/cv-vault/releases/download/v0.4.0/Apercu-styles-CV-Vault.pdf)

L’import s’appuie sur la position du texte dans le PDF pour lire les colonnes et rattacher les retours à la ligne au bon fait. Les pages scannées passent par la reconnaissance locale de Vision. L’app conserve le PDF original, le texte brut par page et les liens détectés. Consultez l’extrait de chaque fait avant de le valider, surtout si la mise en page est complexe ou le scan de mauvaise qualité. Chaque PDF est limité à 50 Mio et 100 pages.

Pour un PDF déjà dans la bibliothèque, ouvrez le menu **Actions PDF**, puis **Réextraire les faits**. Les faits déjà revus ou modifiés sont conservés.

## Connecter Codex

Dans l’onglet **Codex** de l’app, copiez la commande qui correspond à son emplacement. Pour une installation effectuée par `build.sh --install` :

```sh
codex mcp add cv-vault -- "$HOME/Applications/CV Vault.app/Contents/MacOS/cv-vault-mcp"
codex mcp get cv-vault
```

Le serveur s’exécute en local sur STDIO, même quand l’app est fermée. Après l’ajout, ouvrez une nouvelle session Codex ou redémarrez le client s’il ne voit pas le serveur. Vous pouvez aussi l’ajouter dans les réglages MCP de l’app Codex en choisissant STDIO et en indiquant le chemin complet du binaire. Voir la [documentation Codex sur les serveurs MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

> Avec CV Vault, liste les styles disponibles puis crée le même CV Lead Data en styles Technique et Direction. Utilise les mêmes faits vérifiés et le format A4. Sauvegarde les deux fichiers sous des noms distincts.

| Outil MCP | Usage |
| --- | --- |
| `list_sources` | Lister les PDF et leur état d’extraction. |
| `get_source` | Lire le texte et les liens d’un groupe de pages. |
| `search_facts` | Chercher dans la base par texte, rubrique, source ou statut. |
| `list_cv_styles` | Découvrir les styles, leurs identifiants et leurs descriptions en français ou en anglais. |
| `generate_cv` | Composer un `.typ` à partir de faits vérifiés d’un même PDF, choisir le modèle et le format, et l’enregistrer si un nom de fichier est fourni. |

Passez l’identifiant du style dans `generate_cv.template`.

| Identifiant | Style | Présentation |
| --- | --- | --- |
| `editorial` | Éditorial (par défaut) | Titres bleu pétrole et typographie à empattements. |
| `classic` | Classique | En-tête centré et texte monochrome. |
| `minimal` | Minimaliste | Lignes sobres et typographie compacte sans empattements. |
| `executive` | Direction | Typographie à empattements et en-tête bleu marine. |
| `technical` | Technique | Intertitres et métadonnées à chasse fixe. |

Pour structurer un CV via MCP, passez `fact_ids` et une liste ordonnée `sections`. Dans une expérience, une formation ou un projet, une entrée peut référencer `heading_fact_id`, `metadata_fact_ids` et `bullet_fact_ids`. Chaque fait de corps sélectionné doit être utilisé une seule fois, dans sa rubrique. Les faits d’identité et de contact vont dans l’en-tête.

Les formats sont `a4` et `letter`. Le choix `fr` ou `en` règle les titres de rubrique et la typographie. Le texte des faits reste dans sa langue d’origine. La validation et la modification des faits se font dans l’app.

## Données locales

Par défaut, l’app et le serveur partagent `~/Library/Application Support/CV Vault/`. La base `knowledge.sqlite3` contient les PDF originaux, les pages et les faits ; `Exports/` contient les CV exportés en Typst ou PDF. Les PDF identiques sont détectés par leur empreinte SHA-256. Supprimer une source dans la bibliothèque supprime les pages et faits associés ; les exports déjà créés restent disponibles.

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
