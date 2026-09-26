// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DeskViewBookScanner",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BookScannerKit", targets: ["BookScannerKit"]),
        .executable(name: "DeskViewBookScanner", targets: ["DeskViewBookScanner"]),
    ],
    targets: [
        .target(
            name: "BookScannerKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "DeskViewBookScanner",
            dependencies: ["BookScannerKit"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BookScannerKitTests",
            dependencies: ["BookScannerKit"]
        ),
    ]
)
