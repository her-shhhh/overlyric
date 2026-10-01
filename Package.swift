// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Overlyric",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure-Foundation logic: lyrics parsing, sync lookup, track-name cleaning, LRCLIB matching.
        .target(name: "OverlyricCore", path: "Sources/OverlyricCore"),
        // The AppKit menu-bar app.
        .executableTarget(
            name: "Overlyric",
            dependencies: ["OverlyricCore"],
            path: "Sources/Overlyric",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScriptingBridge"),
            ]
        ),
        .testTarget(name: "OverlyricCoreTests", dependencies: ["OverlyricCore"], path: "Tests/OverlyricCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
