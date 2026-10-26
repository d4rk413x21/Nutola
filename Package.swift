// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Nutola",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
    ],
    targets: [
        // Tiny ObjC shim whose sole job is to run an AVAudioNode tap-install (and
        // similar AVF calls) inside an @try/@catch. Swift's `do/catch` cannot catch
        // ObjC NSExceptions, so an AVAudioFormat mismatch during a live route change
        // (e.g. plugging in Bluetooth headphones mid-recording) raises through the
        // ObjC runtime and becomes SIGABRT, killing the app. This wraps it instead.
        .target(
            name: "ExceptionCatch",
            path: "Sources/ExceptionCatch",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Nutola",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "ExceptionCatch",
            ],
            path: "Sources/Nutola",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "zoom-info",
            path: "Sources/ZoomInfo",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NutolaTests",
            dependencies: ["Nutola"],
            path: "Tests/NutolaTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
