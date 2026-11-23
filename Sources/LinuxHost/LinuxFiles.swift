import DynamicFiles
import DynamicRuntime
import Foundation
import RuntimeABI
import RuntimeHost

/// The `Files` contract (AppRuntime's `Files.md`): `RuntimeHost`'s
/// `HostFiles`, with the app's directories where Linux keeps them, and
/// answers on the main loop (`Plan.md` §9). `LinuxDefaults` keeps the
/// app's settings beside them.
///
/// | Directory | `LINUXAPPRUNTIME_CONTAINER` set | Otherwise (XDG) |
/// |---|---|---|
/// | `documents` | `<container>/Documents` | `$XDG_DATA_HOME/<id>/Documents` |
/// | `data` | `<container>/Data` | `$XDG_DATA_HOME/<id>/Data` |
/// | `caches` | `<container>/Caches` | `$XDG_CACHE_HOME/<id>` |
/// | `temporary` | `<container>/tmp` | `$XDG_RUNTIME_DIR/<id>`, or `/tmp/<id>-<uid>` |
/// | `bundle` | the bundle's `resources/` | the same |
///
/// `<id>` is the app's bundle identifier. `XDG_DATA_HOME` defaults to
/// `~/.local/share` and `XDG_CACHE_HOME` to `~/.cache`. `temporary` is the
/// app's own, since it's emptied at every start.
public enum LinuxFiles: HostModule {

    public static var contracts: [ContractDescriptor] {
        HostFilesModule.contracts
    }

    /// Says where the app's files are, then registers `Files`. The
    /// directories come from the app's identifier and `LinuxBundle`, which
    /// `AppHost` sets up first.
    public static func register(in registrar: some ContractRegistrar) {
        configureIfNeeded()
        HostFilesModule.register(in: registrar)
    }

    /// Whether `HostFiles` knows where the app's files are.
    nonisolated(unsafe) public private(set) static var isConfigured = false

    /// Says where the app's files are, once: for `Files`, and for modules
    /// that find the app's files without it, such as media.
    public static func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        let identifier = LinuxBundle.info.identifier
        do {
            let directories = try self.directories(identifier: identifier, resources: LinuxBundle.resources, environment: environment)
            try HostFiles.configure(HostFiles.Configuration(directories: directories, deliver: deliver))
            HostLog.debug("files: \(directories.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))")
        } catch {
            // Every operation then fails, and says so through its callback.
            HostLog.error("files: \(error)")
        }
    }

    /// The environment the directories come from; replaceable for tests.
    nonisolated(unsafe) public static var environment = ProcessInfo.processInfo.environment

    /// Answers go to the main loop, from `HostFiles`' queue.
    static let deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = { answer in
        MainLoop.shared.post(answer)
    }

    /// Where each directory is for the app `identifier`.
    public static func directories(
        identifier: String,
        resources: String?,
        environment: [String: String],
        userID: UInt32 = getuid()
    ) throws(LinuxFilesError) -> [FileDirectory: String] {
        guard isPathComponent(identifier) else {
            throw LinuxFilesError("the bundle identifier \"\(identifier)\" can't name a directory")
        }
        var directories: [FileDirectory: String] = [:]
        if let container = nonEmpty(environment["LINUXAPPRUNTIME_CONTAINER"]) {
            guard container.hasPrefix("/") else {
                throw LinuxFilesError("LINUXAPPRUNTIME_CONTAINER must be an absolute path")
            }
            directories[.documents] = container + "/Documents"
            directories[.data] = container + "/Data"
            directories[.caches] = container + "/Caches"
            directories[.temporary] = container + "/tmp"
        } else {
            guard let home = nonEmpty(environment["HOME"]) else {
                throw LinuxFilesError("neither LINUXAPPRUNTIME_CONTAINER nor HOME is set")
            }
            let data = absolute(environment["XDG_DATA_HOME"]) ?? home + "/.local/share"
            let cache = absolute(environment["XDG_CACHE_HOME"]) ?? home + "/.cache"
            directories[.documents] = data + "/" + identifier + "/Documents"
            directories[.data] = data + "/" + identifier + "/Data"
            directories[.caches] = cache + "/" + identifier
            if let runtime = absolute(environment["XDG_RUNTIME_DIR"]) {
                directories[.temporary] = runtime + "/" + identifier
            } else {
                directories[.temporary] = "/tmp/\(identifier)-\(userID)"
            }
        }
        if let resources {
            directories[.bundle] = resources
        }
        return directories
    }

    static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The XDG specification ignores relative paths in its variables.
    static func absolute(_ value: String?) -> String? {
        nonEmpty(value).flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    /// One path component: not empty, `.` or `..`, and no `/` or NUL.
    static func isPathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

/// Why the app's directories couldn't be decided.
public struct LinuxFilesError: Error, CustomStringConvertible {

    public var description: String

    init(_ description: String) {
        self.description = description
    }
}
