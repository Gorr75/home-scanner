// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RoomScanCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "RoomScanCore", targets: ["RoomScanCore"])
    ],
    targets: [
        .target(name: "RoomScanCore"),
        .testTarget(
            name: "RoomScanCoreTests",
            dependencies: ["RoomScanCore"],
            exclude: ["Fixtures"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
