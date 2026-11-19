import Foundation
import LinuxHostApp
import Testing
@testable import LinuxPackager

@Suite struct ValidatorTests {

    func diagnostics(_ fixture: Fixture, target: LinuxTarget = .arm64, allowMissing: Bool = false) throws -> [Diagnostic] {
        var validator = Validator(bundle: try fixture.bundle, target: target)
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
        #expect(try diagnostics(Fixture(), target: .x86_64).isEmpty)
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

    /// AppRuntime's `RuntimeFormatting`, which the host registers as it is.
    @Test func formattingIsImplemented() throws {
        let fixture = try Fixture(contracts: [
            ("org.pureswift.ui.Renderer", 1, "contract"),
            ("org.pureswift.formatting.Locale", 1, "contract"),
            ("org.pureswift.formatting.NumberFormat", 1, "contract"),
            ("org.pureswift.formatting.DateFormat", 1, "contract"),
        ])
        #expect(try diagnostics(fixture).isEmpty)
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
        // The runner checks the library against the signature, so there
        // must be one.
        #expect(try diagnostics(Fixture(signed: false)).map(\.message)
                == ["the bundle isn't signed: it has no _CodeSignature/CodeResources, which the runner checks its library against"])
    }

    @Test func slicesMustBeForTheTarget() throws {
        let wrong = try diagnostics(Fixture(machine: LinuxTarget.x86_64.elfMachine))
        #expect(wrong.map(\.message) == ["linux-arm64 slice: it's for ELF machine 62, not 183 (aarch64)"])
        let object = try diagnostics(Fixture(elfType: 1))
        #expect(object.map(\.message) == ["linux-arm64 slice: it isn't a shared library (ELF type 1)"])
        let bits = try diagnostics(Fixture(), target: .armv7)
        #expect(bits.map(\.message) == ["the bundle has no linux-armv7 slice (lib/linux-armv7/libapp.so)"])
        #expect(try diagnostics(Fixture(targets: [.armv7]), target: .armv7).isEmpty)
        #expect(try diagnostics(Fixture(targets: [])).map(\.message) == ["the bundle has no linux-arm64 slice (lib/linux-arm64/libapp.so)"])
    }

    @Test func capabilitiesWithoutSupportWarn() throws {
        let messages = try diagnostics(Fixture(capabilities: ["bluetooth", "location"]))
        #expect(messages == [.warning("the app declares location, which the Linux host doesn't support yet")])
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

    func packager(_ fixture: Fixture, runner: FakeRunner = FakeRunner(), output: URL? = nil) throws -> Packager {
        var options = Packager.Options(target: .arm64)
        options.output = output ?? FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        return Packager(bundle: try fixture.bundle, options: options, runner: runner)
    }

    @Test func thinsTheBundleAndBuildsNothing() throws {
        let fixture = try Fixture()
        let runner = FakeRunner()
        let result = try packager(fixture, runner: runner).package()
        let root = result.root
        let files = FileManager.default

        let app = root.appendingPathComponent("lib/linux-app/org.example.Demo.app")
        #expect(result.bundle.path == app.path)
        #expect(try files.contentsOfDirectory(atPath: app.path).sorted()
                == ["Info.plist", "_CodeSignature", "icon.png", "lib", "resources"])
        #expect(try files.contentsOfDirectory(atPath: app.appendingPathComponent("lib").path) == ["linux-arm64"])
        #expect(try files.contentsOfDirectory(atPath: app.appendingPathComponent("lib/linux-arm64").path) == ["libapp.so"])
        #expect(files.fileExists(atPath: root.appendingPathComponent("share/icons/hicolor/256x256/apps/org.example.Demo.png").path))
        #expect(!files.fileExists(atPath: root.appendingPathComponent("bin").path), "no program of its own")
        let entry = try String(contentsOf: root.appendingPathComponent("share/applications/org.example.Demo.desktop"), encoding: .utf8)
        #expect(entry.contains("Exec=linux-app-host org.example.Demo %u\n"))
        #expect(entry.contains("Name=Demo App\n"))
        #expect(runner.commands.isEmpty, "nothing compiled or linked")

        // The thinned bundle still matches its signature, for what it kept.
        let thinned = try UniversalBundle(url: app)
        #expect(thinned.codeResourceProblems().allSatisfy { $0.hasSuffix("is missing") })
        let digest = try AppLibrary.signedDigest(bundle: app.path, file: "lib/linux-arm64/libapp.so")
        #expect(digest.count == 32)

        // Packaging again replaces it.
        _ = try packager(fixture, output: root).package()
        #expect(!files.fileExists(atPath: app.deletingLastPathComponent().appendingPathComponent(".org.example.Demo.app.new").path))
    }

    @Test func installsForTheRunner() throws {
        let fixture = try Fixture()
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("prefix with space-\(UUID().uuidString)")
        let runner = URL(fileURLWithPath: "/opt/linux app/bin/linux-app-host")
        let result = try packager(fixture).install(prefix: prefix, runner: runner)
        #expect(result.bundle.path == InstalledApps.bundle(identifier: "org.example.Demo", prefix: prefix.path))
        let entry = try String(contentsOf: prefix.appendingPathComponent("share/applications/org.example.Demo.desktop"), encoding: .utf8)
        #expect(entry.contains("Exec=\"/opt/linux app/bin/linux-app-host\" org.example.Demo %u"))
        // The runner finds it by its identifier.
        #expect(InstalledApps.find(identifier: "org.example.Demo", prefixes: ["/nonexistent", prefix.path]) == result.bundle.path)
        #expect(InstalledApps.find(identifier: "org.example.Other", prefixes: [prefix.path]) == nil)
        #expect(InstalledApps.find(identifier: "../etc", prefixes: [prefix.path]) == nil)
    }

    @Test func refusesInvalidBundles() throws {
        let fixture = try Fixture(contracts: [("org.example.Missing", 1, "contract")])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(UUID().uuidString)")
        #expect(throws: PackagerError.self) {
            try packager(fixture, output: output).package()
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func archives() throws {
        var packager = try packager(Fixture())
        packager.options.archive = true
        let result = try packager.package()
        #expect(result.archive?.lastPathComponent == "org.example.Demo-1.2-linux-arm64.tar.gz")
    }

    @Test func findsTheRunner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let program = directory.appendingPathComponent("linux-app-host")
        try Data("#!/bin/sh\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        #expect(try Runner.locate(nil, environment: ["PATH": "/nonexistent:\(directory.path)"], tool: nil) == program)
        #expect(try Runner.locate(nil, environment: [:], tool: directory.appendingPathComponent("linux-app").path) == program)
        #expect(throws: PackagerError.self) {
            try Runner.locate(nil, environment: ["PATH": "/nonexistent"], tool: nil)
        }
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
        let runner = DesktopEntry(identifier: "a.b", name: "Demo", exec: "/usr/bin/linux-app-host", arguments: ["a.b"], version: "1")
        #expect(runner.text.contains("Exec=/usr/bin/linux-app-host a.b %u\n"))
    }

    @Test func desktopEntriesEscape() {
        #expect(DesktopEntry.escape(" lead\\tab\t") == "\\slead\\\\tab\\t")
        #expect(DesktopEntry.quote("/opt/My App/bin/x") == "\"/opt/My App/bin/x\"")
        #expect(DesktopEntry.quote("/usr/bin/100%") == "/usr/bin/100%%")
        #expect(DesktopEntry.quote("/a/$HOME") == "\"/a/\\\\$HOME\"", "escaped inside quotes, then as a string")
    }

    @Test func targets() {
        #expect(LinuxTarget.target(machine: "aarch64") == .arm64)
        #expect(LinuxTarget.target(machine: "x86_64") == .x86_64)
        #expect(LinuxTarget.target(machine: "riscv64") == nil)
        #expect(LinuxTarget.native != nil)
    }
}
