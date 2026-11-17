// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mtgrec",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "mtgrec",
            path: "Sources/mtgrec",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
