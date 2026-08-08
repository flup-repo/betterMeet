// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "betterMeet",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "betterMeet", targets: ["betterMeet"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "betterMeet",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the binary so TCC can attribute the
                // system-audio-capture permission to betterMeet itself when it
                // runs as a LaunchAgent (no .app bundle to carry a plist).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/betterMeet/Info.plist",
                ]),
            ],
            plugins: [
                .plugin(name: "InfoPlistDependencyPlugin"),
            ]
        ),
        .plugin(
            name: "InfoPlistDependencyPlugin",
            capability: .buildTool()
        ),
    ]
)
