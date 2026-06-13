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
    dependencies: [
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .executableTarget(
            name: "ApplePi",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
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
