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
        ),
        .executable(
            name: "ApplePiAskpass",
            targets: ["ApplePiAskpass"]
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
        .executableTarget(
            name: "ApplePiAskpass",
            path: "Sources/ApplePiAskpass"
        ),
        .testTarget(
            name: "ApplePiTests",
            dependencies: ["ApplePi"],
            path: "Tests/ApplePiTests"
        )
    ]
)
