import Foundation

/// `linux-app-host`, the runner every installed app runs in (`Plan.md` §4,
/// `Packager.md` §3). Installing an app doesn't build anything: the runner
/// is installed once, and updated on its own.
public enum Runner {

    /// The runner's program name.
    public static let name = "linux-app-host"

    /// The installed runner: `explicit`, then `LINUXAPPRUNTIME_RUNNER`, then
    /// the one next to `linux-app`, then the first on `PATH`.
    public static func locate(
        _ explicit: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tool: String? = InstalledApps.runnerPath()
    ) throws(PackagerError) -> URL {
        var candidates = [explicit, environment["LINUXAPPRUNTIME_RUNNER"]].compactMap { $0 }
        if let tool {
            candidates.append((tool as NSString).deletingLastPathComponent + "/" + name)
        }
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate).standardizedFileURL
        }
        throw PackagerError("can't find \(name); install it, or pass --runner or set LINUXAPPRUNTIME_RUNNER")
    }

    /// This package's source, for building a runner a PortMaster port
    /// carries: `--host-package`, then `LINUXAPPRUNTIME_PATH`, then the tree
    /// `linux-app` was built from.
    public static func source(_ explicit: String? = nil) throws(PackagerError) -> URL {
        let candidates = [explicit, ProcessInfo.processInfo.environment["LINUXAPPRUNTIME_PATH"]].compactMap { $0 }
            .map { URL(fileURLWithPath: $0) }
            + [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()]
        for candidate in candidates {
            let manifest = candidate.appendingPathComponent("Package.swift")
            if let text = try? String(contentsOf: manifest, encoding: .utf8), text.contains("name: \"LinuxAppRuntime\"") {
                return candidate.standardizedFileURL
            }
        }
        throw PackagerError("can't find LinuxAppRuntime's source; pass --host-package or set LINUXAPPRUNTIME_PATH")
    }

    /// Builds the runner from `source`; the executable's path. Any app runs
    /// in it, so it's built once per target. `extraArguments` go to `swift
    /// build`, such as a Swift SDK for another architecture. With
    /// `staticSwift`, the Swift runtime, Foundation and Dispatch are linked
    /// in, so it runs where Swift isn't installed.
    public static func build(
        source: URL,
        scratch: URL,
        configuration: String = "release",
        staticSwift: Bool = true,
        extraArguments: [String] = [],
        runner: CommandRunning
    ) throws(PackagerError) -> URL {
        var arguments = ["swift", "build", "--package-path", source.path, "--scratch-path", scratch.path,
                         "-c", configuration, "--product", name]
        if staticSwift {
            arguments.append("--static-swift-stdlib")
        }
        arguments += extraArguments
        try runner.run(arguments, directory: nil, environment: [:])
        let bin = try runner.run(arguments + ["--show-bin-path"], directory: nil, environment: [:])
            .split(separator: "\n").last.map(String.init) ?? ""
        return URL(fileURLWithPath: bin.trimmingCharacters(in: .whitespaces)).appendingPathComponent(name)
    }
}
