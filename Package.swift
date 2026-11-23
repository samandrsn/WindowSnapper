// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowSnapper",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic (geometry, cycling, matching, saved-layout models). No AppKit, fully testable.
        .target(name: "SnapCore"),
        // The menu bar app itself.
        .executableTarget(name: "WindowSnapper", dependencies: ["SnapCore"]),
        .testTarget(name: "SnapCoreTests", dependencies: ["SnapCore"]),
    ]
)
