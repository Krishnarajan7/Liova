// swift-tools-version: 6.0
import PackageDescription

/// LiovaKit holds every module except the thin app target.
///
/// Dependency direction (arrows point at dependencies):
///
///     LiovaUI ──► LiovaCore ──► LiovaPluginKit ◄── LiovaIPC ◄── liova (CLI)
///     LiovaFeatures ──► LiovaCore, LiovaUI, LiovaProviders
///
/// LiovaPluginKit depends on nothing, so plugins and clients compile against it alone.
let package = Package(
    name: "LiovaKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiovaPluginKit", targets: ["LiovaPluginKit"]),
        .library(name: "LiovaCore", targets: ["LiovaCore"]),
        .library(name: "LiovaUI", targets: ["LiovaUI"]),
        .library(name: "LiovaProviders", targets: ["LiovaProviders"]),
        .library(name: "LiovaFeatures", targets: ["LiovaFeatures"]),
        .library(name: "LiovaIPC", targets: ["LiovaIPC"]),
        .executable(name: "liova", targets: ["LiovaCLI"]),
    ],
    targets: [
        .target(name: "LiovaPluginKit"),
        .target(name: "LiovaCore", dependencies: ["LiovaPluginKit"]),
        .target(name: "LiovaUI", dependencies: ["LiovaCore"]),
        .target(name: "LiovaProviders"),
        .target(name: "LiovaFeatures", dependencies: ["LiovaCore", "LiovaUI", "LiovaProviders"]),
        .target(name: "LiovaIPC", dependencies: ["LiovaPluginKit"]),
        .executableTarget(name: "LiovaCLI", dependencies: ["LiovaIPC", "LiovaPluginKit"]),
        .testTarget(name: "LiovaPluginKitTests", dependencies: ["LiovaPluginKit"]),
        .testTarget(name: "LiovaCoreTests", dependencies: ["LiovaCore"]),
        .testTarget(name: "LiovaUITests", dependencies: ["LiovaUI"]),
        .testTarget(name: "LiovaProvidersTests", dependencies: ["LiovaProviders"]),
        .testTarget(name: "LiovaFeaturesTests", dependencies: ["LiovaFeatures"]),
        .testTarget(name: "LiovaIPCTests", dependencies: ["LiovaIPC"]),
    ],
    swiftLanguageModes: [.v6]
)
