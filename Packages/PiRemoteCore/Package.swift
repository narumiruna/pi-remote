// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiRemoteCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PiRemoteCore", targets: ["PiRemoteCore"])],
    targets: [
        .target(name: "PiRemoteCore"),
        .testTarget(name: "PiRemoteCoreTests", dependencies: ["PiRemoteCore"])
    ]
)
