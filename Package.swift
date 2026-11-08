// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacCleaner",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacCleanerCore", targets: ["MacCleanerCore"]),
        .executable(name: "MacCleanerApp", targets: ["MacCleanerApp"])
    ],
    targets: [
        .target(
            name: "MacCleanerCore",
            path: "Sources/MacCleanerCore"
        ),
        .executableTarget(
            name: "MacCleanerApp",
            dependencies: ["MacCleanerCore"],
            path: "Sources/MacCleanerApp"
        ),
        .testTarget(
            name: "MacCleanerTests",
            dependencies: ["MacCleanerCore"],
            path: "Tests/MacCleanerTests"
        )
    ]
)
