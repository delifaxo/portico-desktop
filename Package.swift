// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Portico",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Portico", targets: ["PorticoApp"]),
        .executable(name: "PorticoCoolingHelper", targets: ["PorticoCoolingHelper"]),
        .library(name: "PorticoCore", targets: ["PorticoCore"])
    ],
    targets: [
        .target(name: "CoolingSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "PorticoCore", dependencies: ["CoolingSMC"]),
        .executableTarget(name: "PorticoCoolingHelper", dependencies: ["PorticoCore", "CoolingSMC"]),
        .executableTarget(name: "PorticoApp", dependencies: ["PorticoCore"]),
        .testTarget(name: "PorticoCoreTests", dependencies: ["PorticoCore"])
    ],
    swiftLanguageModes: [.v5]
)
