// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kiri",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Kiri", path: "Sources/Kiri")
    ]
)
