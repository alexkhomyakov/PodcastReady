// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PodcastReady",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PodcastReady",
            path: "PodcastReady",
            exclude: ["Info.plist", "PodcastReady.entitlements", "Resources"]
        ),
    ]
)
