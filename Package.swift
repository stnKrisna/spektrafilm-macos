// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpektrafilmSwiftUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpektrafilmCore", targets: ["SpektrafilmCore"]),
        .library(name: "SpektrafilmPreviewGeometry", targets: ["SpektrafilmPreviewGeometry"]),
        .executable(name: "SpektrafilmApp", targets: ["SpektrafilmApp"]),
    ],
    targets: [
        .target(
            name: "SpektrafilmCore",
            // The canonical Metal kernel source is embedded by the
            // MetalKernelSourcePlugin build tool, not compiled by SwiftPM.
            exclude: ["SpektrafilmKernels.metal"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")],
            plugins: [.plugin(name: "MetalKernelSourcePlugin")]
        ),
        .target(
            name: "SpektrafilmPreviewGeometry",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "SpektrafilmApp",
            dependencies: ["SpektrafilmCore", "SpektrafilmPreviewGeometry"],
            resources: [.copy("../../Data")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .plugin(
            name: "MetalKernelSourcePlugin",
            capability: .buildTool()
        ),
        .testTarget(
            name: "SpektrafilmCoreTests",
            dependencies: ["SpektrafilmCore"]
        ),
        .testTarget(
            name: "SpektrafilmPreviewGeometryTests",
            dependencies: ["SpektrafilmPreviewGeometry"]
        ),
    ]
)
