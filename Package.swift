// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Backchannel",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Backchannel", path: "Sources/Backchannel")
    ]
)
