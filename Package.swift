// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiRemoteSpikes",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "Packages/PiRemoteCore")],
    targets: [
        .target(
            name: "PiRPC",
            dependencies: [.product(name: "PiRemoteCore", package: "PiRemoteCore")],
            path: "Spikes/PiRPC"
        ),
        .executableTarget(
            name: "PiRPCSpike",
            dependencies: ["PiRPC"],
            path: "Spikes/PiRPCSpike"
        ),
        .testTarget(name: "PiRPCTests", dependencies: ["PiRPC"])
    ]
)
