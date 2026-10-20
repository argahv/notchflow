// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NotchFlow",
    platforms: [.macOS("14.6")],
    products: [.library(name: "NotchCore", targets: ["NotchCore"])],
    targets: [
        .target(name: "NotchCore"),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"])
    ]
)
