// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StatusBoardKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
    ],
    products: [
        .library(name: "StatusBoardKit", targets: ["StatusBoardKit"]),
        .executable(name: "sbctl", targets: ["sbctl"]),
    ],
    targets: [
        .target(
            name: "StatusBoardKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "sbctl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StatusBoardKitTests",
            dependencies: ["StatusBoardKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
