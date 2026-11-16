import Foundation

/// `linux-app package`, `install` and `run` (`Packager.md` §2 – §4).
public struct Packager {

    public struct Options {
        public var target: LinuxTarget
        public var engine: Engine
        /// `release` or `debug`.
        public var configuration = "release"
        public var allowMissingContracts = false
        /// The install tree; `<work>/out` if `nil`.
        public var output: URL?
        /// Also write `<identifier>-<version>-<target>.tar.gz`.
        public var archive = false
        /// Link the Swift runtime in (`--static-swift-stdlib`).
        public var staticSwift = true
        /// More `swift build` arguments: `--swift-sdk`, `--destination`.
        public var buildArguments: [String] = []
        public var hostPackage: URL
        /// AppRuntime, for the wasm2c engine.
        public var appRuntime: URL?
        /// `.build/linux-app` in the current directory by default.
        public var workRoot: URL

        public init(target: LinuxTarget, engine: Engine, hostPackage: URL,
                    workRoot: URL = URL(fileURLWithPath: ".build/linux-app")) {
            self.target = target
            self.engine = engine
            self.hostPackage = hostPackage
            self.workRoot = workRoot
        }
    }

    /// What `package` made.
    public struct Result {
        /// The install tree.
        public var root: URL
        /// `bin/<executable>` in it.
        public var executable: URL
        public var archive: URL?
        public var diagnostics: [Diagnostic]
    }

    public var bundle: UniversalBundle

    public var options: Options

    public var runner: CommandRunning

    public init(bundle: UniversalBundle, options: Options, runner: CommandRunning = CommandRunner()) {
        self.bundle = bundle
        self.options = options
        self.runner = runner
    }

    /// The app's work directory: its generated host package and build.
    public var work: URL {
        options.workRoot.appendingPathComponent(bundle.info.identifier).appendingPathComponent(options.target.rawValue)
    }

    public func validate() -> [Diagnostic] {
        var validator = Validator(bundle: bundle, target: options.target, engine: options.engine)
        validator.allowMissingContracts = options.allowMissingContracts
        return validator.validate()
    }

    /// Validates, builds the host with the app, and writes the install tree.
    public func package() throws(PackagerError) -> Result {
        let diagnostics = validate()
        let errors = diagnostics.filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw PackagerError(errors.map(\.description).joined(separator: "\n"))
        }
        let library = try library()
        let binary = try buildHost(library: library)
        let root = options.output ?? work.appendingPathComponent("out")
        try assemble(binary: binary, into: root, exec: bundle.executable)
        var archive: URL?
        if options.archive {
            let name = "\(bundle.info.identifier)-\(bundle.info.version.isEmpty ? "0" : bundle.info.version)-\(options.target.rawValue).tar.gz"
            let url = root.deletingLastPathComponent().appendingPathComponent(name)
            try runner.run(["tar", "-czf", url.path, "-C", root.path, "."], directory: nil, environment: [:])
            archive = url
        }
        return Result(root: root, executable: root.appendingPathComponent("bin/\(bundle.executable)"),
                      archive: archive, diagnostics: diagnostics)
    }

    /// Builds the host linked with `library`; the executable's path.
    func buildHost(library: URL) throws(PackagerError) -> URL {
        let directory = work.appendingPathComponent("host")
        let host = HostPackage(directory: directory, hostPackage: options.hostPackage,
                               executable: bundle.executable, library: try HostPackage.stage(library, in: directory),
                               linksGL: bundle.info.capabilities.contains(.graphics))
        return try host.build(configuration: options.configuration, staticSwift: options.staticSwift,
                              extraArguments: options.buildArguments, runner: runner)
    }

    /// The app's library for the engine.
    func library() throws(PackagerError) -> URL {
        switch options.engine {
        case .slice:
            guard let slice = bundle.slice(options.target) else {
                throw PackagerError("the bundle has no \(options.target.rawValue) slice")
            }
            return slice
        case .wasm2c:
            guard let wasm = bundle.wasm else {
                throw PackagerError("the bundle has no wasm32/App.wasm")
            }
            var appRuntime = options.appRuntime
            if appRuntime == nil {
                // The checkout SwiftPM resolves for the host build.
                let host = HostPackage(directory: work.appendingPathComponent("host"), hostPackage: options.hostPackage,
                                       executable: bundle.executable, library: wasm)
                try host.write()
                try runner.run(["swift", "package", "--package-path", host.directory.path, "--scratch-path",
                                host.directory.appendingPathComponent(".build").path, "resolve"], directory: nil, environment: [:])
                appRuntime = host.resolvedAppRuntime
            }
            guard let appRuntime else {
                throw PackagerError("wasm2c needs AppRuntime's checkout; pass --appruntime or set APPRUNTIME_PATH")
            }
            return try Wasm2c(appRuntime: appRuntime).build(wasm: wasm, output: work.appendingPathComponent("wasm2c"), runner: runner)
        }
    }

    // MARK: The tree

    /// Writes the install tree of `Packager.md` §4 into `root`, replacing an
    /// earlier one. `exec` is the desktop entry's program.
    func assemble(binary: URL, into root: URL, exec: String) throws(PackagerError) {
        let identifier = bundle.info.identifier
        let files = FileManager.default
        let lib = root.appendingPathComponent("lib/\(identifier)")
        do {
            for path in ["bin/\(bundle.executable)", "lib/\(identifier)", "share/applications/\(identifier).desktop",
                         "share/icons/hicolor/256x256/apps/\(identifier).png"] {
                let url = root.appendingPathComponent(path)
                if files.fileExists(atPath: url.path) || (try? files.destinationOfSymbolicLink(atPath: url.path)) != nil {
                    try files.removeItem(at: url)
                }
            }
            try files.createDirectory(at: lib, withIntermediateDirectories: true)
            let program = lib.appendingPathComponent(bundle.executable)
            try files.copyItem(at: binary, to: program)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)

            // The bundle without its code, which is in the program now.
            let app = lib.appendingPathComponent("App.app")
            try files.createDirectory(at: app, withIntermediateDirectories: true)
            for name in try files.contentsOfDirectory(atPath: bundle.url.path)
            where !["lib", "wasm32", "_CodeSignature"].contains(name) {
                try files.copyItem(at: bundle.url.appendingPathComponent(name), to: app.appendingPathComponent(name))
            }

            let bin = root.appendingPathComponent("bin")
            try files.createDirectory(at: bin, withIntermediateDirectories: true)
            try files.createSymbolicLink(atPath: bin.appendingPathComponent(bundle.executable).path,
                                         withDestinationPath: "../lib/\(identifier)/\(bundle.executable)")

            let applications = root.appendingPathComponent("share/applications")
            try files.createDirectory(at: applications, withIntermediateDirectories: true)
            var entry = DesktopEntry(identifier: identifier, name: bundle.displayName, exec: exec, version: bundle.info.version)
            entry.localizedNames = bundle.localizedDisplayNames
            try entry.text.write(to: applications.appendingPathComponent("\(identifier).desktop"), atomically: true, encoding: .utf8)

            if let icon = bundle.icon {
                let icons = root.appendingPathComponent("share/icons/hicolor/256x256/apps")
                try files.createDirectory(at: icons, withIntermediateDirectories: true)
                try files.copyItem(at: icon, to: icons.appendingPathComponent("\(identifier).png"))
            }
        } catch let error as PackagerError {
            throw error
        } catch {
            throw PackagerError("can't write the app into \(root.path): \(error)")
        }
    }

    /// Packages into `prefix` (`~/.local` by default), with the desktop
    /// entry running the program by its absolute path.
    public func install(prefix: URL) throws(PackagerError) -> Result {
        var staged = self
        staged.options.output = nil
        let result = try staged.package()
        let binary = result.root.appendingPathComponent("lib/\(bundle.info.identifier)/\(bundle.executable)")
        let exec = prefix.appendingPathComponent("bin/\(bundle.executable)").path
        try assemble(binary: binary, into: prefix, exec: exec)
        let applications = prefix.appendingPathComponent("share/applications")
        _ = try? runner.run(["update-desktop-database", applications.path], directory: nil, environment: [:])
        return Result(root: prefix, executable: URL(fileURLWithPath: exec), archive: nil, diagnostics: result.diagnostics)
    }
}
