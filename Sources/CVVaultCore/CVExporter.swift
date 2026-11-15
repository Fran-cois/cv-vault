import Darwin
import Foundation

public enum CVLanguage: String, CaseIterable, Codable, Sendable {
    case fr, en
}

public enum CVExportError: LocalizedError {
    case emptySelection
    case unverifiedFact
    case multipleSources
    case duplicateFact
    case invalidName
    case fileExists
    case invalidDirectory
    case missingSourceStyle

    public var errorDescription: String? {
        switch self {
        case .emptySelection: return "Select at least one verified fact with text."
        case .unverifiedFact: return "Only verified facts can be exported."
        case .multipleSources: return "An export can only contain facts from one source."
        case .duplicateFact: return "Each fact can only be selected once."
        case .invalidName: return "Use a short file name with letters, numbers, spaces, hyphens or underscores."
        case .fileExists: return "A CV with that name already exists. Choose a different name."
        case .invalidDirectory: return "The export directory must be a local directory and cannot be a symbolic link."
        case .missingSourceStyle: return "Original style requires the appearance of the imported PDF."
        }
    }
}

public enum CVExporter {
    public static var defaultOutputDirectory: URL {
        KnowledgeBase.defaultDataDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    // Facts and UI labels are data. All user content is written inside escaped Typst strings.
    public static func generate(
        facts: [CVFact],
        labels: [FactCategory: String] = [:],
        language: CVLanguage = .fr,
        title: String? = nil,
        template: CVTemplate = .editorial,
        paper: CVPaper? = nil,
        sections: [CVSection]? = nil,
        sourceStyle: CVSourceStyle? = nil
    ) throws -> String {
        guard !facts.isEmpty,
              facts.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CVExportError.emptySelection
        }
        guard facts.allSatisfy({ $0.status == .verified }) else { throw CVExportError.unverifiedFact }
        guard Set(facts.map(\.sourceID)).count == 1 else { throw CVExportError.multipleSources }
        guard Set(facts.map(\.id)).count == facts.count else { throw CVExportError.duplicateFact }

        return try CVLayout.render(
            facts: facts, labels: labels, language: language, title: title,
            template: template, paper: paper, composition: sections, sourceStyle: sourceStyle
        )
    }

    /// Exports are private files, created once. A caller cannot pass a path as a file name.
    @discardableResult
    public static func save(
        typst: String,
        name: String,
        directory: URL = defaultOutputDirectory
    ) throws -> URL {
        try save(data: Data(typst.utf8), name: name, fileExtension: ".typ", directory: directory)
    }

    @discardableResult
    public static func save(
        pdf: Data,
        name: String,
        directory: URL = defaultOutputDirectory
    ) throws -> URL {
        try save(data: pdf, name: name, fileExtension: ".pdf", directory: directory)
    }

    private static func save(data: Data, name: String, fileExtension: String, directory: URL) throws -> URL {
        var basename = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        if basename.lowercased().hasSuffix(fileExtension) { basename.removeLast(fileExtension.count) }
        let allowed = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: " -_"))
        guard !basename.isEmpty, basename.utf8.count <= 120,
              basename == basename.trimmingCharacters(in: .whitespaces),
              basename.unicodeScalars.allSatisfy(allowed.contains),
              basename.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            throw CVExportError.invalidName
        }
        guard directory.isFileURL else { throw CVExportError.invalidDirectory }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let dirFD = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard dirFD >= 0 else { throw CVExportError.invalidDirectory }
        defer { Darwin.close(dirFD) }

        let filename = basename + fileExtension
        let fd = filename.withCString { openat(dirFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else {
            let code = errno
            if code == EEXIST || code == ELOOP { throw CVExportError.fileExists }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let length = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                    if length == -1, errno == EINTR { continue }
                    guard length > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += length
                }
            }
        } catch {
            Darwin.close(fd)
            filename.withCString { _ = unlinkat(dirFD, $0, 0) }
            throw error
        }
        guard Darwin.close(fd) == 0 else {
            let code = errno
            filename.withCString { _ = unlinkat(dirFD, $0, 0) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return directory.appendingPathComponent(filename)
    }

    public static func sectionTitle(_ category: FactCategory, _ language: CVLanguage) -> String {
        let titles: (String, String)
        switch category {
        case .identity: titles = ("Identité", "Identity")
        case .contact: titles = ("Coordonnées", "Contact")
        case .summary: titles = ("Profil", "Profile")
        case .experience: titles = ("Expérience", "Experience")
        case .education: titles = ("Formation", "Education")
        case .skills: titles = ("Compétences", "Skills")
        case .languages: titles = ("Langues", "Languages")
        case .certifications: titles = ("Certifications", "Certifications")
        case .projects: titles = ("Projets", "Projects")
        case .publications: titles = ("Publications", "Publications")
        case .awards: titles = ("Distinctions", "Awards")
        case .other: titles = ("Autres informations", "Other information")
        }
        return language == .fr ? titles.0 : titles.1
    }
}
