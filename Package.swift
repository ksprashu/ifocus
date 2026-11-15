// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iFocus",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "iFocusCore", targets: ["iFocusCore"]),
        .executable(name: "ifocus", targets: ["iFocusApp"]),
    ],
    targets: [
        .target(name: "iFocusCore"),
        .target(name: "iFocusMac", dependencies: ["iFocusCore"]),
        .executableTarget(name: "iFocusApp", dependencies: ["iFocusCore", "iFocusMac"]),
        .testTarget(name: "iFocusCoreTests", dependencies: ["iFocusCore"]),
    ],
    swiftLanguageModes: [.v6]
)
