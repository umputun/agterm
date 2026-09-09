// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "agtermCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "agtermCore", targets: ["agtermCore"]),
        .library(name: "AgtermResponsibility", targets: ["AgtermResponsibility"]),
        .executable(name: "agtermctl", targets: ["agtermctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
    ],
    targets: [
        .target(name: "agtermCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .target(name: "AgtermResponsibility"),
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

#if os(macOS)
package.products.append(.executable(name: "agterm-session-host", targets: ["agterm-session-host"]))
package.targets += [
    .target(name: "SessionHostTrampoline"),
    .target(name: "SessionHostRuntime", dependencies: ["SessionHostTrampoline", "AgtermResponsibility", "agtermCore"]),
    .executableTarget(name: "agterm-session-host", dependencies: ["SessionHostRuntime"]),
    .testTarget(name: "SessionHostRuntimeTests", dependencies: ["SessionHostRuntime", "agterm-session-host"]),
]
#endif
