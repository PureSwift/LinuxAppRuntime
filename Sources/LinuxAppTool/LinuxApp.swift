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

    @Option(help: "linux-arm64, linux-x86_64 or linux-armv7; this machine's by default.")
    var target: String?

    @Flag(help: "Warn about contracts this host lacks instead of failing; the app sees them as absent.")
    var allowMissingContracts = false

    @Flag(name: .shortAndLong, help: "Show the commands the packager runs.")
    var verbose = false

    func load() throws -> (UniversalBundle, LinuxTarget) {
        let bundle = try UniversalBundle(url: URL(fileURLWithPath: self.bundle))
        if let name = self.target {
            guard let named = LinuxTarget(rawValue: name) else {
                throw ValidationError("unknown target \(name); one of \(LinuxTarget.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return (bundle, named)
        }
        guard let native = LinuxTarget.native else {
            throw ValidationError("this machine isn't a Linux target; pass --target")
        }
        return (bundle, native)
    }

    func packager() throws -> Packager {
        let (bundle, target) = try load()
        var options = Packager.Options(target: target)
        options.allowMissingContracts = allowMissingContracts
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
            let (bundle, target) = try options.load()
            var validator = Validator(bundle: bundle, target: target)
            validator.allowMissingContracts = options.allowMissingContracts
            let diagnostics = validator.validate()
            report(diagnostics)
            if diagnostics.contains(where: { $0.severity == .error }) {
                throw ExitCode.failure
            }
            print("ok: \(bundle.info.identifier) for \(target.rawValue)")
        }
    }

    struct Package: ParsableCommand {

        static let configuration = CommandConfiguration(
            abstract: "Write the app's install tree: its bundle thinned to one target, and its desktop entry.")

        @OptionGroup var options: BundleOptions

        @Option(help: "The install tree's directory; .build/linux-app/<id>/<target> by default.")
        var output: String?

        @Flag(help: "Also write <id>-<version>-<target>.tar.gz next to the tree.")
        var archive = false

        func run() throws {
            var packager = try options.packager()
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

        static let configuration = CommandConfiguration(
            abstract: "Install the app for the user, to run in the installed runner. Nothing is built.")

        @OptionGroup var options: BundleOptions

        @Option(help: "Where to install; ~/.local by default.")
        var prefix: String?

        @Option(help: "The runner the desktop entry starts; LINUXAPPRUNTIME_RUNNER, the one next to linux-app, or linux-app-host on PATH.")
        var runner: String?

        func run() throws {
            let packager = try options.packager()
            let program = try Runner.locate(runner)
            let prefix = prefix.map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local")
            let result = try packager.install(prefix: prefix, runner: program)
            report(result.diagnostics)
            print(result.bundle.path)
        }
    }

    struct Run: ParsableCommand {

        static let configuration = CommandConfiguration(abstract: "Check the app and run it in the runner, as it is.")

        @OptionGroup var options: BundleOptions

        @Option(help: "The runner; as for install.")
        var runner: String?

        @Argument(parsing: .postTerminator, help: "More arguments for the runner, after --: a URL to open.")
        var arguments: [String] = []

        func run() throws {
            let (bundle, target) = try options.load()
            var validator = Validator(bundle: bundle, target: target)
            validator.allowMissingContracts = options.allowMissingContracts
            let diagnostics = validator.validate()
            report(diagnostics)
            if diagnostics.contains(where: { $0.severity == .error }) {
                throw ExitCode.failure
            }
            let process = Process()
            process.executableURL = try Runner.locate(runner)
            process.arguments = ["--bundle", bundle.url.path] + arguments
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

        @Option(help: "LinuxAppRuntime's source, which the port's runner is built from; LINUXAPPRUNTIME_PATH, or where linux-app was built from.")
        var hostPackage: String?

        @Option(help: "The runner's build directory.")
        var work = ".build/linux-app/runner"

        func run() throws {
            let environment = ProcessInfo.processInfo.environment
            let destination = destination ?? environment["LINUXAPPRUNTIME_SWIFT_DESTINATION"]
            let packager = try options.packager()
            var portOptions = PortMasterPort.Options(output: URL(fileURLWithPath: output))
            portOptions.source = try Runner.source(hostPackage)
            portOptions.scratch = URL(fileURLWithPath: work)
            // SwiftPM's default build system ignores destination files.
            portOptions.buildArguments = destination.map { ["--build-system", "native", "--destination", $0] } ?? []
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
