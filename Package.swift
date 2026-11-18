// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mirrorpress",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Mirrorpress", path: "Sources/Mirrorpress"),
        .testTarget(name: "MirrorpressTests", dependencies: ["Mirrorpress"], path: "Tests/MirrorpressTests"),
    ]
)
