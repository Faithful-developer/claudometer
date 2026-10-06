// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Claudometer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Claudometer", targets: ["Claudometer"]),
        .library(name: "ClaudometerCore", targets: ["ClaudometerCore"]),
    ],
    targets: [
        .target(name: "ClaudometerCore"),
        .executableTarget(
            name: "Claudometer",
            dependencies: ["ClaudometerCore"]
        ),
        .testTarget(
            name: "ClaudometerCoreTests",
            dependencies: ["ClaudometerCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
