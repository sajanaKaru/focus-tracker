// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FocusTracker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FocusTracker", targets: ["FocusTracker"])
    ],
    targets: [
        .target(name: "FocusCore"),
        .executableTarget(name: "FocusTracker", dependencies: ["FocusCore"]),
        .testTarget(name: "FocusCoreTests", dependencies: ["FocusCore"])
    ]
)
