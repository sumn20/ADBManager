// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ADBManager",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ADBManager",
            path: "Sources/ADBManager"
        ),
        .testTarget(
            name: "ADBManagerTests",
            dependencies: ["ADBManager"],
            path: "Tests/ADBManagerTests"
        )
    ]
)
