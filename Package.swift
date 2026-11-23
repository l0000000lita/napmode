// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nap-mode",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NapMode", targets: ["NapMode"])
    ],
    targets: [
        .target(name: "NapCore"),
        .executableTarget(name: "NapMode", dependencies: ["NapCore"]),
        .executableTarget(name: "NapCoreTests", dependencies: ["NapCore"], path: "Tests/NapCoreTests")
    ]
)
