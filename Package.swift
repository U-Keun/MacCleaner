// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacCleaner",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "MacCleanerCore", targets: ["MacCleanerCore"]),
        .executable(name: "MacCleaner", targets: ["MacCleaner"]),
        .executable(name: "MacCleanerUI", targets: ["MacCleanerUI"]),
    ],
    targets: [
        .target(
            name: "MacCleanerCore"
        ),
        .executableTarget(
            name: "MacCleaner",
            dependencies: ["MacCleanerCore"]
        ),
        .executableTarget(
            name: "MacCleanerUI",
            dependencies: ["MacCleanerCore"]
        ),
        .testTarget(
            name: "MacCleanerTests",
            dependencies: ["MacCleaner", "MacCleanerCore"]
        ),
    ]
)
