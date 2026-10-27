// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AlbumImporter",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "AlbumImporter", targets: ["AlbumImporter"]),
        .executable(name: "albumctl", targets: ["albumctl"]),
    ],
    targets: [
        .target(name: "AlbumCore"),
        .executableTarget(name: "AlbumImporter", dependencies: ["AlbumCore"]),
        .executableTarget(name: "albumctl", dependencies: ["AlbumCore"]),
        .testTarget(name: "AlbumCoreTests", dependencies: ["AlbumCore"]),
    ]
)
