import Foundation

/// Where `linux-app install` puts an app, and how the runner finds it by
/// its identifier (`Plan.md` §4, `Packager.md` §4):
/// `<prefix>/lib/linux-app/<identifier>.app`, the app's bundle thinned to
/// what this machine runs.
public enum InstalledApps {

    /// The apps' directory under a prefix.
    public static let directory = "lib/linux-app"

    /// The installed bundle of `identifier` under `prefix`.
    public static func bundle(identifier: String, prefix: String) -> String {
        prefix + "/" + directory + "/" + identifier + ".app"
    }

    /// The prefixes searched, in order: `LINUXAPPRUNTIME_PREFIXES` (a
    /// colon-separated list) if it's set; otherwise the user's
    /// (`~/.local`), the runner's own (`<prefix>/bin/linux-app-host`), then
    /// `/usr/local` and `/usr`.
    public static func prefixes(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: String? = runnerPath()
    ) -> [String] {
        if let list = environment["LINUXAPPRUNTIME_PREFIXES"], !list.isEmpty {
            return list.split(separator: ":").map(String.init)
        }
        var prefixes: [String] = []
        if let home = environment["HOME"], home.hasPrefix("/") {
            prefixes.append(home + "/.local")
        }
        if let runner {
            let bin = (runner as NSString).deletingLastPathComponent
            if (bin as NSString).lastPathComponent == "bin" {
                prefixes.append((bin as NSString).deletingLastPathComponent)
            }
        }
        for prefix in ["/usr/local", "/usr"] where !prefixes.contains(prefix) {
            prefixes.append(prefix)
        }
        return prefixes
    }

    /// The first installed bundle of `identifier` in `prefixes`.
    public static func find(identifier: String, prefixes: [String] = prefixes()) -> String? {
        guard isIdentifier(identifier) else { return nil }
        return prefixes.lazy
            .map { bundle(identifier: identifier, prefix: $0) }
            .first { FileManager.default.fileExists(atPath: $0 + "/Info.plist") }
    }

    /// A bundle identifier, which names a directory: `org.example.App`.
    public static func isIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// This process's executable, with links resolved.
    public static func runnerPath() -> String? {
        let path = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe"))
            ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return path.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }
}
