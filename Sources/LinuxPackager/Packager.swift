import Foundation

/// `linux-app package` and `install` (`Packager.md` §2 – §4): checks an app
/// against this host, thins its bundle to what the target runs, and writes
/// it where the runner finds it. Nothing is compiled or linked: the device
/// needs the runner, and no toolchain.
public struct Packager {

    public struct Options {
        public var target: LinuxTarget
        public var allowMissingContracts = false
        /// The install tree; `.build/linux-app/<id>/<target>` if `nil`.
        public var output: URL?
        /// Also write `<identifier>-<version>-<target>.tar.gz`.
        public var archive = false

        public init(target: LinuxTarget) {
            self.target = target
        }
    }

    /// What `package` or `install` wrote.
    public struct Result {
        /// The install tree, or the prefix installed into.
        public var root: URL
        /// The thinned bundle in it: `lib/linux-app/<identifier>.app`.
        public var bundle: URL
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

    public func validate() -> [Diagnostic] {
        var validator = Validator(bundle: bundle, target: options.target)
        validator.allowMissingContracts = options.allowMissingContracts
        return validator.validate()
    }

    /// Validates, and writes the install tree, for a distribution's package
    /// or an archive: its desktop entry runs the runner from `PATH`.
    public func package() throws(PackagerError) -> Result {
        let diagnostics = try checked()
        let root = options.output
            ?? URL(fileURLWithPath: ".build/linux-app").appendingPathComponent(bundle.info.identifier)
                .appendingPathComponent(options.target.rawValue)
        let installed = try assemble(into: root, runner: Runner.name)
        var archive: URL?
        if options.archive {
            let name = "\(bundle.info.identifier)-\(bundle.info.version.isEmpty ? "0" : bundle.info.version)-\(options.target.rawValue).tar.gz"
            let url = root.deletingLastPathComponent().appendingPathComponent(name)
            try runner.run(["tar", "-czf", url.path, "-C", root.path, "."], directory: nil, environment: [:])
            archive = url
        }
        return Result(root: root, bundle: installed, archive: archive, diagnostics: diagnostics)
    }

    /// Validates, and installs into `prefix` (`~/.local` by default), with
    /// the desktop entry running `runner` by its absolute path.
    public func install(prefix: URL, runner program: URL) throws(PackagerError) -> Result {
        let diagnostics = try checked()
        let installed = try assemble(into: prefix, runner: program.path)
        let applications = prefix.appendingPathComponent("share/applications")
        _ = try? runner.run(["update-desktop-database", applications.path], directory: nil, environment: [:])
        return Result(root: prefix, bundle: installed, archive: nil, diagnostics: diagnostics)
    }

    private func checked() throws(PackagerError) -> [Diagnostic] {
        let diagnostics = validate()
        let errors = diagnostics.filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw PackagerError(errors.map(\.description).joined(separator: "\n"))
        }
        return diagnostics
    }

    // MARK: The tree

    /// What a thinned bundle keeps: everything the runner reads, and the
    /// signature, which still holds for every file kept.
    static let kept = ["Info.plist", "resources", "icon.png", "_CodeSignature"]

    /// Writes the app into `root` (`Packager.md` §4), replacing an earlier
    /// copy; the thinned bundle. `runner` is the desktop entry's program.
    ///
    /// ```
    /// lib/linux-app/<identifier>.app/   Info.plist, resources/, icon.png,
    ///                                   _CodeSignature/, lib/<target>/libapp.so
    /// share/applications/<identifier>.desktop
    /// share/icons/hicolor/256x256/apps/<identifier>.png
    /// ```
    func assemble(into root: URL, runner: String) throws(PackagerError) -> URL {
        let identifier = bundle.info.identifier
        let files = FileManager.default
        let apps = root.appendingPathComponent(InstalledApps.directory)
        let app = apps.appendingPathComponent("\(identifier).app")
        let staged = apps.appendingPathComponent(".\(identifier).app.new")
        do {
            // The new copy is complete before it replaces the old one.
            try? files.removeItem(at: staged)
            try files.createDirectory(at: staged, withIntermediateDirectories: true)
            try thin(into: staged)
            try? files.removeItem(at: app)
            try files.moveItem(at: staged, to: app)

            let applications = root.appendingPathComponent("share/applications")
            try files.createDirectory(at: applications, withIntermediateDirectories: true)
            var entry = DesktopEntry(identifier: identifier, name: bundle.displayName, exec: runner,
                                     arguments: [identifier], version: bundle.info.version)
            entry.localizedNames = bundle.localizedDisplayNames
            entry.mimeTypes = bundle.documentMimeTypes
            try entry.text.write(to: applications.appendingPathComponent("\(identifier).desktop"), atomically: true, encoding: .utf8)

            let icons = root.appendingPathComponent("share/icons/hicolor/256x256/apps")
            let icon = icons.appendingPathComponent("\(identifier).png")
            try? files.removeItem(at: icon)
            if let source = bundle.icon {
                try files.createDirectory(at: icons, withIntermediateDirectories: true)
                try files.copyItem(at: source, to: icon)
            }
        } catch let error as PackagerError {
            throw error
        } catch {
            try? files.removeItem(at: staged)
            throw PackagerError("can't write the app into \(root.path): \(error)")
        }
        return app
    }

    /// Copies what the target runs into `directory`: the kept files, and
    /// the target's `libapp.so`.
    func thin(into directory: URL) throws {
        let files = FileManager.default
        for name in Self.kept {
            let source = bundle.url.appendingPathComponent(name)
            if files.fileExists(atPath: source.path) {
                try files.copyItem(at: source, to: directory.appendingPathComponent(name))
            }
        }
        guard let slice = bundle.slice(options.target) else {
            throw PackagerError("the bundle has no \(options.target.rawValue) slice")
        }
        let library = directory.appendingPathComponent(options.target.sharedLibrary)
        try files.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: slice, to: library)
    }
}
