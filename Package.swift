// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lookout",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Lookout", targets: ["Lookout"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "LookoutCore"),
        .executableTarget(name: "Lookout", dependencies: ["LookoutCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "LookoutCoreTests", dependencies: ["LookoutCore"]),
        .testTarget(name: "LookoutTests", dependencies: ["Lookout"])
    ]
)
