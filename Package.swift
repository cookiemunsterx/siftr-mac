// swift-tools-version: 6.0
// Siftr for Mac. Build the app with ./build.sh (plain `swift build`
// makes only the bare program, without the .app around it).
import PackageDescription

let package = Package(
    name: "Siftr",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Whisper on Apple's Neural Engine, for lyrics (pinned: new versions come in on purpose)
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
    ],
    targets: [
        // The rules: scanning, song keys, the decision database, copying,
        // the queue. Foundation + SQLite only, so an iPad/iPhone version can
        // reuse it as-is.
        .target(name: "SifterCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // The Mac app: window, menus, the web view that draws the screen.
        .executableTarget(name: "Siftr", dependencies: [
            "SifterCore",
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        .testTarget(name: "SifterCoreTests", dependencies: ["SifterCore"]),
    ]
)
