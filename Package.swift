// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Netra",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Netra",
            path: "Sources/Netra"
        ),
        .testTarget(
            name: "NetraTests",
            dependencies: ["Netra"],
            path: "Tests/NetraTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
