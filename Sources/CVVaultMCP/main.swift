import CVVaultCore
import Darwin
import Foundation

func writeJSON<T: Encodable>(_ result: T) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var encoded = try encoder.encode(result)
    encoded.append(0x0a)
    try FileHandle.standardOutput.write(contentsOf: encoded)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case nil:
        var transport = MCPTransport(tools: CVTools(base: try KnowledgeBase()))
        try transport.run()
    case "import-pdf" where arguments.count == 2:
        let result = try KnowledgeBase().importPDF(at: URL(fileURLWithPath: arguments[1]))
        try writeJSON(result)
    case "reextract" where arguments.count == 2:
        let result = try KnowledgeBase().reextractPDF(sourceID: arguments[1])
        try writeJSON(result)
    default:
        let usage = "Usage: cv-vault-mcp [import-pdf <path> | reextract <source-id>]\n"
        try FileHandle.standardError.write(contentsOf: Data(usage.utf8))
        exit(2)
    }
} catch {
    let message = "CV Vault: \(error.localizedDescription)\n"
    try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    exit(1)
}
