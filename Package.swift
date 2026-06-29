// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "apple-pi",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ApplePi",
            targets: ["ApplePi"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ApplePi",
            path: "Sources/ApplePi",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "ApplePiTests",
            dependencies: ["ApplePi"],
            path: "Tests/ApplePiTests"
        )
    ]
)
