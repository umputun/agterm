// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "agtermCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "agtermCore", targets: ["agtermCore"]),
        .executable(name: "agtermctl", targets: ["agtermctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
    ],
    targets: [
        .target(name: "agtermCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .testTarget(name: "agtermCoreTests", dependencies: ["agtermCore"]),
        .target(
            name: "agtermctlKit",
            dependencies: [
                "agtermCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "agtermctl", dependencies: ["agtermctlKit"]),
        .testTarget(name: "agtermctlKitTests", dependencies: ["agtermctlKit"]),
    ],
    swiftLanguageModes: [.v6]
)
