// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PodcastReady",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic.git", from: "1.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "PodcastReady",
            dependencies: ["SwiftAnthropic"],
            path: "PodcastReady",
            exclude: ["Info.plist"]
        ),
    ]
)
