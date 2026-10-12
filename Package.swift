// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FaceHugger", platforms: [.macOS("27.0")], products: [
    .library(name: "FaceHuggerCore", targets: ["FaceHuggerCore"])
], targets: [
    .target(name: "FaceHuggerCore"),
    .testTarget(name: "FaceHuggerCoreTests", dependencies: ["FaceHuggerCore"])
])
