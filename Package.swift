// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiRemoteSpikes",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PiRemoteHost", targets: ["PiRemoteHost"]),
        .library(name: "PiRemoteClient", targets: ["PiRemoteClient"]),
        .library(name: "PiRemoteConnection", targets: ["PiRemoteConnection"])
    ],
    dependencies: [.package(path: "Packages/PiRemoteCore")],
    targets: [
        .target(
            name: "PiRPC",
            dependencies: [.product(name: "PiRemoteCore", package: "PiRemoteCore")],
            path: "Packages/PiRPC/Sources/PiRPC"
        ),
        .executableTarget(
            name: "PiRPCSpike",
            dependencies: ["PiRPC"],
            path: "Spikes/PiRPCSpike"
        ),
        .testTarget(name: "PiRPCTests", dependencies: ["PiRPC"]),
        .target(
            name: "PiRemoteTransport",
            dependencies: [.product(name: "PiRemoteCore", package: "PiRemoteCore")],
            path: "Spikes/SecureTransport"
        ),
        .executableTarget(
            name: "TransportServerSpike",
            dependencies: ["PiRemoteTransport"],
            path: "Spikes/TransportServerSpike"
        ),
        .testTarget(name: "SecureTransportTests", dependencies: ["PiRemoteTransport"]),
        .target(name: "PiRemoteSecurity", dependencies: [.product(name: "PiRemoteCore", package: "PiRemoteCore")], path: "Packages/PiRemoteSecurity/Sources/PiRemoteSecurity"),
        .target(name: "PiRemoteConnection", dependencies: [.product(name: "PiRemoteCore", package: "PiRemoteCore")], path: "Packages/PiRemoteConnection/Sources/PiRemoteConnection"),
        .target(name: "PiRemoteHost", dependencies: ["PiRPC", "PiRemoteSecurity", .product(name: "PiRemoteCore", package: "PiRemoteCore")], path: "Packages/PiRemoteHost/Sources/PiRemoteHost"),
        .target(name: "PiRemoteClient", dependencies: ["PiRemoteConnection", "PiRemoteSecurity", .product(name: "PiRemoteCore", package: "PiRemoteCore")], path: "Packages/PiRemoteClient/Sources/PiRemoteClient"),
        .testTarget(name: "HostTests", dependencies: ["PiRemoteHost", "PiRemoteClient"]),
        .executableTarget(name: "NativeWorkflowCheck", dependencies: ["PiRemoteHost"], path: "Spikes/NativeWorkflowCheck"),
        .executableTarget(name: "NativeProviderCheck", dependencies: ["PiRemoteHost"], path: "Spikes/NativeProviderCheck")
    ]
)
