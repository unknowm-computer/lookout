// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lookout",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Lookout", targets: ["Lookout"]),
               .executable(name: "LookoutFanHelper", targets: ["LookoutFanHelper"]),
               .executable(name: "LookoutWindowHelper", targets: ["LookoutWindowHelper"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "FanControlProtocol"),
        .target(name: "FanSupport", dependencies: ["CSMC"]),
        .target(name: "WindowLayoutModel"),
        .target(name: "WindowHelperProtocol", dependencies: ["WindowLayoutModel"]),
        .target(name: "WindowLayoutRuntime", dependencies: ["WindowLayoutModel", "WindowHelperProtocol", "FanControlProtocol"]),
        .executableTarget(name: "LookoutWindowHelper", dependencies: ["WindowLayoutRuntime"]),
        .executableTarget(name: "LookoutFanHelper", dependencies: ["FanSupport", "FanControlProtocol"]),
        .target(name: "LookoutCore", dependencies: ["CSMC", "FanSupport", "WindowLayoutModel"], resources: [.process("Resources")]),
        .executableTarget(name: "Lookout", dependencies: ["LookoutCore", "FanControlProtocol", "WindowHelperProtocol", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "LookoutCoreTests", dependencies: ["LookoutCore"]),
        .testTarget(name: "LookoutTests", dependencies: ["Lookout", "WindowLayoutRuntime"])
    ]
)
