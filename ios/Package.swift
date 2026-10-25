// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "TVRemote", platforms: [.macOS(.v14), .iOS(.v17)], products: [
    .library(name: "TVRemoteCore", targets: ["TVRemoteCore"])
], targets: [
    .target(name: "TVRemoteCore", path: "Sources/Core"),
    .testTarget(name: "TVRemoteCoreTests", dependencies: ["TVRemoteCore"], path: "Tests")
], swiftLanguageVersions: [.v5])
