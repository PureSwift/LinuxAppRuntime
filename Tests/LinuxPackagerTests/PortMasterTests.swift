import Foundation
import Testing
@testable import LinuxPackager

@Suite struct PortMasterTests {

    func port(_ fixture: Fixture, output: URL, libraries: URL? = nil) throws -> PortMasterPort {
        var options = Packager.Options(target: .arm64, engine: .slice, hostPackage: URL(fileURLWithPath: "/src"))
        options.workRoot = output.appendingPathComponent("work")
        var portOptions = PortMasterPort.Options(output: output)
        portOptions.libraries = libraries
        portOptions.fonts = nil
        portOptions.porters = ["Tester"]
        return PortMasterPort(packager: Packager(bundle: try fixture.bundle, options: options, runner: CommandRunner()),
                              options: portOptions)
    }

    func temporary(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func namesFollowTheApp() throws {
        let port = try port(Fixture(executable: "Demo_App"), output: try temporary("names"))
        #expect(port.name == "demoapp")
        #expect(port.launcher == "Demo App.sh")
        #expect(PortMasterPort.architecture(.arm64) == "aarch64")
        #expect(PortMasterPort.architecture(.armv7) == "armhf")
    }

    @Test func assemblesBothArchitecturesIntoOnePort() throws {
        let output = try temporary("port")
        let libraries = try temporary("libs")
        try Data([1]).write(to: libraries.appendingPathComponent("libSDL3.so.0"))
        try FileManager.default.createDirectory(at: libraries.appendingPathComponent("licenses"), withIntermediateDirectories: true)
        try "zlib".write(to: libraries.appendingPathComponent("licenses/SDL3.txt"), atomically: true, encoding: .utf8)
        let binary = try temporary("bin").appendingPathComponent("host")
        try Data("#!/bin/sh\n".utf8).write(to: binary)

        let port = try port(Fixture(), output: output, libraries: libraries)
        _ = try port.assemble(binary: binary, architecture: "aarch64")
        let result = try port.assemble(binary: binary, architecture: "armhf")

        let files = FileManager.default
        let game = result.directory.appendingPathComponent("demo")
        for path in ["Demo.aarch64", "Demo.armhf", "libs.aarch64/libSDL3.so.0", "libs.armhf/libSDL3.so.0",
                     "App.app/Info.plist", "demo.gptk", "licenses/SDL3.txt"] {
            #expect(files.fileExists(atPath: game.appendingPathComponent(path).path), "\(path)")
        }
        #expect(!files.fileExists(atPath: game.appendingPathComponent("App.app/lib").path))
        #expect((try files.attributesOfItem(atPath: game.appendingPathComponent("Demo.armhf").path)[.posixPermissions] as? Int) == 0o755)

        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: result.directory.appendingPathComponent("port.json"))) as? [String: Any])
        let attributes = try #require(json["attr"] as? [String: Any])
        #expect(attributes["arch"] as? [String] == ["aarch64", "armhf"])
        #expect(attributes["porter"] as? [String] == ["Tester"])
        #expect(json["name"] as? String == "demo.zip")
        #expect(json["items"] as? [String] == ["Demo App.sh", "demo"])

        let launcher = try String(contentsOf: result.directory.appendingPathComponent("Demo App.sh"), encoding: .utf8)
        #expect(launcher.contains(#"GAMEDIR="/$directory/ports/demo""#))
        #expect(launcher.contains(#"./Demo.${DEVICE_ARCH} --bundle "$GAMEDIR/App.app""#))
        #expect(launcher.contains("source $controlfolder/control.txt"))
        #expect(launcher.contains("pm_finish"))
        #expect(files.fileExists(atPath: result.directory.appendingPathComponent("screenshot.png").path), "the icon stands in")
        #expect(try String(contentsOf: result.directory.appendingPathComponent("gameinfo.xml"), encoding: .utf8)
            .contains("<path>./Demo App.sh</path>"))
        #expect(files.fileExists(atPath: result.zip.path))
    }

    @Test func glibcVersionsCompareNumerically() {
        #expect(ELF.newest(["2.4", "2.35", "2.17"]) == "2.35")
        #expect(ELF.newest([]) == nil)
        #expect(ELF.requiredGLIBC(URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    #if os(Linux)
    @Test func readsGLIBCVersionsFromELF() throws {
        let version = try #require(ELF.requiredGLIBC(URL(fileURLWithPath: "/bin/sh")))
        #expect(version.hasPrefix("2."))
    }
    #endif
}
