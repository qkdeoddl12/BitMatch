// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BitMatch",
    // Core Audio only reports which apps are playing from macOS 14.2 on.
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "BitMatch", path: "Sources/BitMatch")
    ]
)
