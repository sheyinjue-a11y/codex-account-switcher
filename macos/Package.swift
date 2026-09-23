// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexAccountSwitcher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexAccountSwitcher", targets: ["SwitcherApp"])],
    targets: [
        .target(name: "SwitcherCore"),
        .executableTarget(name: "SwitcherApp", dependencies: ["SwitcherCore"]),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"])
    ]
)
