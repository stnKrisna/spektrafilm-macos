import Foundation
import PackagePlugin

/// Embeds `Sources/SpektrafilmCore/Shaders/SpektrafilmKernels.metal` into the
/// SpektrafilmCore target as a Swift string literal. SwiftPM cannot compile
/// .metal files in library targets, so the kernels are compiled at runtime
/// via `MTLDevice.makeLibrary(source:)`. The generated Swift file is written
/// to the plugin work directory and compiled into the target automatically.
@main
struct MetalKernelSourcePlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let metal = context.package.directoryURL
            .appending(path: "Sources/SpektrafilmCore/SpektrafilmKernels.metal")
        let script = context.package.directoryURL
            .appending(path: "Scripts/generate-metal-kernel-source.sh")
        let output = context.pluginWorkDirectoryURL
            .appending(path: "MetalKernelSource.generated.swift")
        return [
            .buildCommand(
                displayName: "Generate Metal kernel source from SpektrafilmKernels.metal",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path, metal.path, output.path],
                inputFiles: [metal, script],
                outputFiles: [output]
            )
        ]
    }
}
