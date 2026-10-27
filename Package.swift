// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lookout",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Lookout", targets: ["Lookout"]),
               .executable(name: "LookoutFanHelper", targets: ["LookoutFanHelper"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "FanControlProtocol"),
        .executableTarget(name: "LookoutFanHelper", dependencies: ["LookoutCore", "FanControlProtocol"]),
        .target(name: "LookoutCore", dependencies: ["CSMC"], resources: [.process("Resources")]),
        .executableTarget(name: "Lookout", dependencies: ["LookoutCore", "FanControlProtocol", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "LookoutCoreTests", dependencies: ["LookoutCore"]),
        .testTarget(name: "LookoutTests", dependencies: ["Lookout"])
    ]
)
