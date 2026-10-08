// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "StayVibe",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "StayVibeCore"),
        .executableTarget(
            name: "StayVibe",
            dependencies: ["StayVibeCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "StayVibeCoreTests", dependencies: ["StayVibeCore"]),
    ]
)
