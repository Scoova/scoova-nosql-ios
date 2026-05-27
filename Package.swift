// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScoovaNoSQL",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "ScoovaNoSQL", targets: ["ScoovaNoSQL"]),
    ],
    targets: [
        .target(
            name: "ScoovaNoSQL",
            path: "Sources/ScoovaNoSQL"
        ),
        // Live end-to-end smoke runner. Excluded from published `products`.
        .executableTarget(
            name: "LiveSmoke",
            dependencies: ["ScoovaNoSQL"],
            path: "Sources/LiveSmoke"
        ),
        .testTarget(
            name: "ScoovaNoSQLTests",
            dependencies: ["ScoovaNoSQL"],
            path: "Tests/ScoovaNoSQLTests"
        ),
    ]
)
