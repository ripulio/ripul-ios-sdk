import Foundation
import PackagePlugin

// The theme for a host that changes no source: one Swift file generated into the build
// folder and compiled into the host's own module (docs/theming-for-hosts.md, "With no
// change to your source"). What the file does is in `Sources/RipulThemeKit/RipulThemeRedirect.swift`;
// what is written is decided by `tools/theme_redirect.py`, which leaves out any name the
// target already declares for itself.

@main
struct RipulThemeRedirectPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let sources = (target as? SourceModuleTarget)?.sourceFiles(withSuffix: "swift").map(\.path) ?? []
        return [try redirect(sources: sources, into: context.pluginWorkDirectory)]
    }
}

/// The package's own folder: this file is compiled where the package was checked out.
private let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func redirect(sources: [Path], into work: Path) throws -> Command {
    let tools = Path(package.appendingPathComponent("tools").path)
    let output = work.appending("RipulThemeRedirect.swift")
    // The target's Swift files, as a list the tool reads: a large target has more than a
    // command line holds.
    let list = work.appending("sources.txt")
    try FileManager.default.createDirectory(atPath: work.string, withIntermediateDirectories: true)
    let text = sources.map(\.string).joined(separator: "\n")
    if (try? String(contentsOfFile: list.string, encoding: .utf8)) != text {
        try text.write(toFile: list.string, atomically: true, encoding: .utf8)
    }
    return .buildCommand(
        displayName: "Ripul theme: redirect SwiftUI's fonts and colours to the theme",
        executable: Path("/usr/bin/python3"),
        arguments: [tools.appending("ripul-theme").string, "redirect", "--out", output.string, "--sources", list.string],
        inputFiles: sources + [list, tools.appending(subpath: "redirect/RipulThemeRedirect.swift.txt")]
            + ["theme_redirect.py", "theme_text.py", "theme_roles.py", "theme_usage_map.py", "theme_rewrite.py"].map { tools.appending($0) },
        outputFiles: [output])
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension RipulThemeRedirectPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let sources = target.inputFiles.filter { $0.type == .source && $0.path.extension == "swift" }.map(\.path)
        return [try redirect(sources: sources, into: context.pluginWorkDirectory)]
    }
}
#endif
