import Foundation
import LinuxHostApp
import Testing
@testable import LinuxPackager

@Suite struct ValidatorTests {

    func diagnostics(_ fixture: Fixture, target: LinuxTarget = .arm64, engine: Engine = .slice,
                     allowMissing: Bool = false) throws -> [Diagnostic] {
        var validator = Validator(bundle: try fixture.bundle, target: target, engine: engine)
        validator.allowMissingContracts = allowMissing
        return validator.validate()
    }

    @Test func readsTheBundle() throws {
        let bundle = try Fixture().bundle
        #expect(bundle.info.identifier == "org.example.Demo")
        #expect(bundle.executable == "Demo")
        #expect(bundle.displayName == "Demo App")
        #expect(bundle.slice(.arm64) != nil && bundle.slice(.armv7) == nil)
        #expect(bundle.wasm != nil && bundle.icon != nil && bundle.resources != nil)
        #expect(throws: PackagerError.self) {
            try UniversalBundle(url: URL(fileURLWithPath: "/nonexistent.app"))
        }
    }

    @Test func aGoodBundlePasses() throws {
        #expect(try diagnostics(Fixture()).isEmpty)
        #expect(try diagnostics(Fixture(), engine: .wasm2c).isEmpty)
    }

    @Test func contractsThisHostLacks() throws {
        let fixture = try Fixture(contracts: [
            ("org.pureswift.location.LocationManager", 1, "contract"),
            ("org.pureswift.ui.Renderer", 99, "contract"),
            ("org.pureswift.ui.RendererDelegate", 1, "contract"),
        ])
        let strict = try diagnostics(fixture)
        #expect(strict.filter { $0.severity == .error }.map(\.message) == [
            "org.pureswift.location.LocationManager isn't implemented on Linux",
            "org.pureswift.ui.RendererDelegate is a different kind of interface on Linux",
        ])
        #expect(strict.contains { $0.severity == .warning && $0.message.contains("Renderer is version") })
        let lenient = try diagnostics(fixture, allowMissing: true)
        #expect(lenient.filter { $0.severity == .error }.count == 1, "the wrong kind is still an error")
    }

    @Test func newerABIsAndBadNames() throws {
        let messages = try diagnostics(Fixture(identifier: "nodots", executable: "../Demo", abi: 99)).map(\.message)
        #expect(messages.contains { $0.contains("rt ABI 99") })
        #expect(messages.contains { $0.contains("isn't a reverse-DNS identifier") })
        #expect(messages.contains { $0.contains("isn't a file name") })
    }

    @Test func tamperedBundlesFail() throws {
        let fixture = try Fixture()
        try Data([1, 2, 3]).write(to: fixture.url.appendingPathComponent("icon.png"))
        try Data().write(to: fixture.url.appendingPathComponent("resources/extra.txt"))
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("resources/en.lproj/Localizable.strings"))
        let problems = try fixture.bundle.codeResourceProblems()
        #expect(problems.sorted() == [
            "icon.png was modified",
            "resources/en.lproj/Localizable.strings is missing",
            "resources/extra.txt was added",
        ])
        #expect(try diagnostics(fixture).filter { $0.severity == .error }.count == 3)
        #expect(try Fixture(signed: false).bundle.codeResourceProblems().isEmpty, "unsigned bundles aren't checked")
    }

    @Test func slicesMustBeForTheTarget() throws {
        let wrong = try diagnostics(Fixture(machine: LinuxTarget.x86_64.elfMachine))
        #expect(wrong.map(\.message) == ["linux-arm64 slice: objects are for ELF machine [62], not 183 (aarch64)"])
        let missing = try Fixture(targets: [])
        #expect(try diagnostics(missing).map(\.message) == ["the bundle has no linux-arm64 slice; use --engine wasm2c"])
        #expect(Engine.preferred(for: try missing.bundle, target: .arm64) == .wasm2c)
        #expect(try diagnostics(Fixture(targets: [], wasm: false), engine: .wasm2c).map(\.message) == ["the bundle has no wasm32/App.wasm"])
    }

    @Test func capabilitiesWithoutSupportWarn() throws {
        let messages = try diagnostics(Fixture(capabilities: ["bluetooth", "location"]))
        #expect(messages == [.warning("the app declares location, which the Linux host doesn't support yet")])
    }

    @Test func archivesAreParsed() throws {
        let archive = Fixture.archive([("/", [0, 0, 0, 0]), ("a.o/", Fixture.elf(machine: 62) + [1]), ("b.o/", Fixture.elf(machine: 183))])
        #expect(try SliceInspector.elfMachines(archive) == [62, 183], "odd members are padded")
        #expect(throws: PackagerError.self) {
            try SliceInspector.elfMachines(Array("not an archive".utf8))
        }
    }

    @Test func theHostAndThePackagerAgreeOnModules() {
        var host: [String] = []
        for module in HostApp.modules {
            host += module.contracts.map { $0.name }
        }
        var packager: [String] = []
        for module in HostContracts.modules {
            packager += module.contracts.map { $0.name }
        }
        #expect(packager == host)
    }
}

@Suite struct PackagerTests {

    func packager(_ fixture: Fixture, runner: FakeRunner) throws -> Packager {
        var options = Packager.Options(target: .arm64, engine: .slice, hostPackage: URL(fileURLWithPath: "/src"),
                                       workRoot: FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString)"))
        options.configuration = "debug"
        return Packager(bundle: try fixture.bundle, options: options, runner: runner)
    }

    @Test func writesTheInstallTree() throws {
        let fixture = try Fixture()
        let runner = FakeRunner()
        let result = try packager(fixture, runner: runner).package()
        let root = result.root
        let files = FileManager.default

        #expect(try files.destinationOfSymbolicLink(atPath: root.appendingPathComponent("bin/Demo").path) == "../lib/org.example.Demo/Demo")
        let program = root.appendingPathComponent("lib/org.example.Demo/Demo").path
        #expect((try files.attributesOfItem(atPath: program)[.posixPermissions] as? Int) == 0o755)
        let app = root.appendingPathComponent("lib/org.example.Demo/App.app")
        #expect(try files.contentsOfDirectory(atPath: app.path).sorted() == ["Info.plist", "icon.png", "resources"])
        #expect(files.fileExists(atPath: root.appendingPathComponent("share/icons/hicolor/256x256/apps/org.example.Demo.png").path))
        let entry = try String(contentsOf: root.appendingPathComponent("share/applications/org.example.Demo.desktop"), encoding: .utf8)
        #expect(entry.contains("Exec=Demo %u\n"))
        #expect(entry.contains("Name=Demo App\n"))

        // The build: a generated package for the app's library.
        let build = try #require(runner.commands.first)
        #expect(build.starts(with: ["swift", "build", "--package-path"]))
        #expect(build.contains("--static-swift-stdlib"), "Swift is linked in")
        #expect(build[build.firstIndex(of: "--product")! + 1] == HostPackage.product)
        let manifest = try String(contentsOf: URL(fileURLWithPath: build[3]).appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#".package(name: "LinuxAppRuntime", path: "/src")"#))
        #expect(manifest.contains("/lib/libapp-"), "a copy named for its contents, so a new library relinks")

        // Packaging again replaces the tree.
        _ = try packager(fixture, runner: runner).package()
    }

    @Test func installsWithAnAbsolutePath() throws {
        let fixture = try Fixture()
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("prefix with space-\(UUID().uuidString)")
        let result = try packager(fixture, runner: FakeRunner()).install(prefix: prefix)
        #expect(result.executable.path == prefix.appendingPathComponent("bin/Demo").path)
        let entry = try String(contentsOf: prefix.appendingPathComponent("share/applications/org.example.Demo.desktop"), encoding: .utf8)
        #expect(entry.contains("Exec=\"\(prefix.path)/bin/Demo\" %u"))
    }

    @Test func refusesInvalidBundles() throws {
        let fixture = try Fixture(contracts: [("org.example.Missing", 1, "contract")])
        let runner = FakeRunner()
        #expect(throws: PackagerError.self) {
            try packager(fixture, runner: runner).package()
        }
        #expect(runner.commands.isEmpty)
    }

    @Test func archives() throws {
        var packager = try packager(Fixture(), runner: FakeRunner())
        packager.options.archive = true
        let result = try packager.package()
        #expect(result.archive?.lastPathComponent == "org.example.Demo-1.2-linux-arm64.tar.gz")
    }

    @Test func desktopEntriesNameTheAppInEachLanguage() throws {
        let fixture = try Fixture(signed: false)
        let plist = fixture.url.appendingPathComponent("Info.plist")
        var info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        info["RTDisplayNameKey"] = "app.name"
        info["CFBundleLocalizations"] = ["en", "pt-BR", "zh-Hans"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        for (language, name) in [("pt-BR", "Demonstração"), ("zh-Hans", "演示")] {
            let directory = fixture.url.appendingPathComponent("resources/\(language).lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "\"app.name\" = \"\(name)\";".write(to: directory.appendingPathComponent("Manifest.strings"), atomically: true, encoding: .utf8)
        }
        let bundle = try fixture.bundle
        #expect(bundle.localizedDisplayNames == ["pt_BR": "Demonstração", "zh_CN": "演示"])
        var entry = DesktopEntry(identifier: "a.b", name: "Demo", exec: "demo", version: "1")
        entry.localizedNames = bundle.localizedDisplayNames
        #expect(entry.text.contains("Name=Demo\nName[pt_BR]=Demonstração\nName[zh_CN]=演示\nExec=demo %u\n"))
    }

    @Test func desktopEntriesEscape() {
        #expect(DesktopEntry.escape(" lead\\tab\t") == "\\slead\\\\tab\\t")
        #expect(DesktopEntry.quote("/opt/My App/bin/x") == "\"/opt/My App/bin/x\"")
        #expect(DesktopEntry.quote("/usr/bin/100%") == "/usr/bin/100%%")
        #expect(DesktopEntry.quote("/a/$HOME") == "\"/a/\\\\$HOME\"", "escaped inside quotes, then as a string")
    }

    @Test func swiftLiterals() {
        #expect(literal("a\"b\\c\n") == #""a\"b\\c\n""#)
    }

    @Test func targets() {
        #expect(LinuxTarget.target(machine: "aarch64") == .arm64)
        #expect(LinuxTarget.target(machine: "x86_64") == .x86_64)
        #expect(LinuxTarget.target(machine: "riscv64") == nil)
        #expect(LinuxTarget.native != nil)
    }
}
