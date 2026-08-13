// swift-tools-version: 6.0

import PackageDescription

// The core is a library rather than part of the executable so it can be tested
// without launching a UI: everything that writes to your project directory --
// secrets, generated headers, the PlatformIO environments -- lives there.
let package = Package(
    name: "ESPNowFlasher",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FlasherCore"),
        .executableTarget(
            name: "ESPNowFlasher",
            dependencies: ["FlasherCore"]
        ),
        .testTarget(
            name: "FlasherCoreTests",
            dependencies: ["FlasherCore"]
        ),
    ]
)
