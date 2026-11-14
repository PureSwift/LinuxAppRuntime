import ArgumentParser
import Foundation
import LinuxPackager

/// `linux-app`: turns a universal bundle into a Linux app
/// (`Documentation/Packager.md`).
@main
struct LinuxApp: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "linux-app",
        abstract: "Package AppRuntime apps for Linux.",
        subcommands: [Validate.self, Package.self, Install.self, Run.self, PortMaster.self]
    )
}

/// What every command takes.
struct BundleOptions: ParsableArguments {

    @Argument(help: "The universal bundle, from guest.py bundle.")
    var bundle: String

    @Option(help: "linux-arm64 or linux-x86_64; this machine's by default.")
    var target: String?

    @Option(help: "slice or wasm2c; a slice if the bundle has one.")
    var engine: String?

    @Flag(help: "Warn about contracts this host lacks instead of failing; the app sees them as absent.")
    var allowMissingContracts = false

    @Option(help: "LinuxAppRuntime's source; LINUXAPPRUNTIME_PATH, or where linux-app was built from.")
    var hostPackage: String?

    @Option(help: "AppRuntime's checkout, for wasm2c; APPRUNTIME_PATH, or the one SwiftPM resolves.")
    var appruntime: String?

    @Option(help: "The work directory for generated host packages and builds.")
    var work = ".build/linux-app"

        @Flag(name: .shortAndLong, help: "Show the commands the packager runs.")
    var verbose = false

    func load() throws -> (UniversalBundle, LinuxTarget, Engine) {
        let bundle = try UniversalBundle(url: URL(fileURLWithPath: self.bundle))
        let target: LinuxTarget
        if let name = self.target {
            guard let named = LinuxTarget(rawValue: name) else {
                throw ValidationError("unknown target \(name); one of \(LinuxTarget.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            target = named
        } else {
            guard let native = LinuxTarget.native else {
                throw ValidationError("this machine isn't a Linux target; pass --target")
            }
            target = native
        }
        let engine: Engine
        if let name = self.engine {
            guard let named = Engine(rawValue: name) else {
                throw ValidationError("unknown engine \(name); slice or wasm2c")
            }
            engine = named
        } else {
            engine = .preferred(for: bundle, target: target)
        }
        return (bundle, target, engine)
    }

    func packager(configuration: String = "release", buildArguments: [String] = []) throws -> Packager {
        let (bundle, target, engine) = try load()
        if let native = LinuxTarget.native, native != target, buildArguments.isEmpty {
            throw ValidationError("building for \(target.rawValue) on \(native.rawValue) isn't supported yet")
        }
        var options = Packager.Options(target: target, engine: engine, hostPackage: try HostPackage.locate(hostPackage))
        options.configuration = configuration
        options.allowMissingContracts = allowMissingContracts
        options.appRuntime = Wasm2c.locate(appruntime)
        options.buildArguments = buildArguments
        options.workRoot = URL(fileURLWithPath: work)
        return Packager(bundle: bundle, options: options, runner: CommandRunner(verbose: verbose))
    }
}

func report(_ diagnostics: [Diagnostic]) {
    for diagnostic in diagnostics {
        FileHandle.standardError.write(Data("linux-app: \(diagnostic)\n".utf8))
    }
}

extension LinuxApp {

    struct Validate: ParsableCommand {

        static let configuration = CommandConfiguration(abstract: "Check a bundle against this host.")

        @OptionGroup var options: BundleOptions

        func run() throws {
            let (bundle, target, engine) = try options.load()
            var validator = Validator(bundle: bundle, target: target, engine: engine)
            validator.allowMissingContracts = options.allowMissingContracts
            let diagnostics = validator.validate()
            report(diagnostics)
            if diagnostics.contains(where: { $0.severity == .error }) {
                throw ExitCode.failure
            }
            print("ok: \(bundle.info.identifier) for \(target.rawValue) with \(engine.rawValue)")
        }
    }

    struct Package: ParsableCommand {

        static let configuration = CommandConfiguration(abstract: "Build the app and write its install tree.")

        @OptionGroup var options: BundleOptions

        @Option(help: "The install tree's directory; .build/linux-app/<id>/<target>/out by default.")
        var output: String?

        @Option(help: "release or debug.")
        var configuration = "release"

        @Flag(help: "Also write <id>-<version>-<target>.tar.gz next to the tree.")
        var archive = false

        func run() throws {
            var packager = try options.packager(configuration: configuration)
            packager.options.output = output.map { URL(fileURLWithPath: $0) }
            packager.options.archive = archive
            let result = try packager.package()
            report(result.diagnostics)
            print(result.root.path)
            if let archive = result.archive {
                print(archive.path)
            }
        }
    }

    struct Install: ParsableCommand {

        static let configuration = CommandConfiguration(abstract: "Package the app and install it for the user.")

        @OptionGroup var options: BundleOptions

        @Option(help: "Where to install; ~/.local by default.")
        var prefix: String?

        func run() throws {
            let packager = try options.packager()
            let prefix = prefix.map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local")
            let result = try packager.install(prefix: prefix)
            report(result.diagnostics)
            print(result.executable.path)
        }
    }

    struct Run: ParsableCommand {

        static let configuration = CommandConfiguration(abstract: "Package a debug build and run it.")

        @OptionGroup var options: BundleOptions

        @Argument(parsing: .postTerminator, help: "Arguments for the app's host, after --.")
        var arguments: [String] = []

        func run() throws {
            let packager = try options.packager(configuration: "debug")
            let result = try packager.package()
            report(result.diagnostics)
            let process = Process()
            process.executableURL = result.executable
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            throw ExitCode(process.terminationStatus)
        }
    }

    struct PortMaster: ParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "portmaster",
            abstract: "Make a PortMaster port for aarch64 or armhf handhelds.",
            discussion: "Run it in the image of Docker/portmaster-<arch>.Dockerfile (Scripts/portmaster.sh), "
                + "which has the toolchain, SDL3 built for old glibc, and the variables this reads."
        )

        @OptionGroup var options: BundleOptions

        @Option(help: "Where the port's folder and zip go.")
        var output = ".build/portmaster"

        @Option(help: "A Swift SDK's destination file, to build for another architecture; LINUXAPPRUNTIME_SWIFT_DESTINATION.")
        var destination: String?

        @Option(help: "Libraries to bundle; LINUXAPPRUNTIME_PORT_LIBS.")
        var libraries: String?

        @Option(help: "Fonts to bundle.")
        var fonts = "/usr/share/fonts/truetype/dejavu"

        @Option(help: "The porter's name, for port.json (repeatable).")
        var porter: [String] = []

        @Option(help: "port.json's description.")
        var description: String?

        @Option(help: "A screenshot; the app's icon by default.")
        var screenshot: String?

        func run() throws {
            let environment = ProcessInfo.processInfo.environment
            let destination = destination ?? environment["LINUXAPPRUNTIME_SWIFT_DESTINATION"]
            // SwiftPM's default build system ignores destination files.
            let packager = try options.packager(buildArguments: destination.map { ["--build-system", "native", "--destination", $0] } ?? [])
            var portOptions = PortMasterPort.Options(output: URL(fileURLWithPath: output))
            portOptions.libraries = (libraries ?? environment["LINUXAPPRUNTIME_PORT_LIBS"]).map { URL(fileURLWithPath: $0) }
            portOptions.fonts = URL(fileURLWithPath: fonts)
            portOptions.porters = porter
            portOptions.description = description
            portOptions.screenshot = screenshot.map { URL(fileURLWithPath: $0) }
            if portOptions.libraries == nil {
                FileHandle.standardError.write(Data("linux-app: warning: no libraries to bundle; handhelds don't have SDL3\n".utf8))
            }
            let result = try PortMasterPort(packager: packager, options: portOptions).package()
            report(result.diagnostics)
            print(result.directory.path)
            print(result.zip.path)
            if let glibc = result.minimumGLIBC {
                print("min_glibc: \(glibc)")
            }
        }
    }
}
