// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacGist",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MacGistCore"),
        .executableTarget(name: "MacGist", dependencies: ["MacGistCore"]),
        .testTarget(name: "MacGistTests", dependencies: ["MacGistCore"]),
    ]
)
