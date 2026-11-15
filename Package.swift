// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CVVault",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CVVault", targets: ["CVVaultApp"]),
        .executable(name: "cv-vault-mcp", targets: ["CVVaultMCP"]),
    ],
    targets: [
        .target(name: "CVVaultCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "CVVaultApp", dependencies: ["CVVaultCore"]),
        .executableTarget(name: "CVVaultMCP", dependencies: ["CVVaultCore"]),
        .testTarget(name: "CVVaultCoreTests", dependencies: ["CVVaultCore"]),
    ],
    swiftLanguageModes: [.v5]
)
