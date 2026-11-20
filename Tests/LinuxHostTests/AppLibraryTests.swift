import Crypto
import Foundation
import RuntimeHost
import Testing
@testable import LinuxHost

/// The runner's loader: libraries compiled here with the toolchain's clang,
/// as a slice's `libapp.so` would be, in signed bundles.
@Suite struct AppLibraryTests {

    static var compiler: String? {
        ["/usr/bin/clang", "/usr/local/bin/clang"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var canLoad: Bool {
        #if os(Linux)
        compiler != nil && LinuxTarget.native != nil
        #else
        false
        #endif
    }

    /// A bundle whose library is `source`, compiled for this machine, and
    /// signed unless `signed` is false.
    func bundle(_ source: String, signed: Bool = true, flags: [String] = []) throws -> (path: String, target: LinuxTarget) {
        let target = try #require(LinuxTarget.native)
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("app-\(UUID().uuidString)/App.app")
        let lib = bundle.appendingPathComponent("lib/\(target.rawValue)")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let c = bundle.deletingLastPathComponent().appendingPathComponent("app.c")
        try source.write(to: c, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Self.compiler))
        process.arguments = ["-shared", "-fPIC", "-nostdlib", "-Wl,-z,now", "-o", lib.appendingPathComponent("libapp.so").path, c.path] + flags
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        if signed {
            try sign(bundle)
        }
        return (bundle.path, target)
    }

    func sign(_ bundle: URL) throws {
        var files: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(atPath: bundle.path))
        for case let path as String in enumerator where !path.hasPrefix("_CodeSignature") {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent(path).path, isDirectory: &isDirectory)
            if !isDirectory.boolValue {
                files[path] = Data(SHA256.hash(data: try Data(contentsOf: bundle.appendingPathComponent(path))))
            }
        }
        let signature = bundle.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["files": files], format: .xml, options: 0)
            .write(to: signature.appendingPathComponent("CodeResources"))
    }

    /// The three guest exports, and `rt_main` answering `status`.
    func app(status: Int32 = 0, body: String = "") -> String {
        """
        #include <stdint.h>
        \(body)
        int32_t rt_main(void) { return \(status); }
        int32_t rt_dispatch(uint32_t context, uint32_t index, uint32_t self, const uint64_t *args, uint32_t nargs,
                            uint64_t *ret, uint32_t nret) { return 0; }
        void rt_finalize(uint32_t context) { }
        """
    }

    @Test(.enabled(if: AppLibraryTests.canLoad)) func loadsTheSliceAndFindsItsExports() throws {
        let (bundle, target) = try bundle(app(status: 7))
        let library = try AppLibrary.load(bundle: bundle, target: target)
        #expect(library.path == bundle + "/lib/\(target.rawValue)/libapp.so")
        #expect(library.entryPoints.main().rawValue == 7)
    }

    @Test(.enabled(if: AppLibraryTests.canLoad)) func refusesALibraryItsSignatureDoesNotList() throws {
        let unsigned = try bundle(app(), signed: false)
        #expect(loadError(unsigned) == "the app isn't signed: it has no _CodeSignature/CodeResources")

        // Changed after it was signed.
        let (path, target) = try bundle(app())
        try Data("not the library".utf8).write(to: URL(fileURLWithPath: path + "/" + target.sharedLibrary))
        #expect(loadError((path, target)) == "\(target.sharedLibrary) doesn't match the bundle's CodeResources")

        // Signed without it.
        let other = try bundle(app())
        let manifest = URL(fileURLWithPath: other.path + "/_CodeSignature/CodeResources")
        try PropertyListSerialization.data(fromPropertyList: ["files": [String: Data]()], format: .xml, options: 0).write(to: manifest)
        #expect(loadError(other) == "_CodeSignature/CodeResources doesn't list \(other.target.sharedLibrary)")
    }

    /// The library binds every symbol as it loads, so one the process
    /// lacks fails the launch, by name.
    @Test(.enabled(if: AppLibraryTests.canLoad)) func namesWhatTheProcessLacks() throws {
        let missing = try bundle(app(body: """
            extern int32_t rt_not_in_this_runner(void);
            int32_t rt_uses(void) { return rt_not_in_this_runner(); }
            """))
        let error = try #require(loadError(missing))
        #expect(error.hasPrefix("can't load \(missing.target.sharedLibrary):"))
        #expect(error.contains("rt_not_in_this_runner"))
    }

    @Test(.enabled(if: AppLibraryTests.canLoad)) func preloadsWhatTheAppDraws() throws {
        let (bundle, target) = try bundle(app())
        #expect(throws: AppLibraryError.self) {
            try AppLibrary.load(bundle: bundle, target: target, preload: ["libnot-installed.so.9"])
        }
        // The C library is always there to preload.
        #expect(throws: Never.self) {
            try AppLibrary.load(bundle: bundle, target: target, preload: ["libc.so.6"])
        }
    }

    @Test(.enabled(if: AppLibraryTests.canLoad)) func aMissingSlice() throws {
        let (bundle, target) = try bundle(app())
        let other = LinuxTarget.allCases.first { $0 != target }!
        let error = try #require(loadError((bundle, other)))
        #expect(error.contains("_CodeSignature/CodeResources doesn't list \(other.sharedLibrary)"))
    }

    func loadError(_ bundle: (path: String, target: LinuxTarget)) -> String? {
        do {
            _ = try AppLibrary.load(bundle: bundle.path, target: bundle.target)
            return nil
        } catch {
            return error.description
        }
    }

    // MARK: Finding installed apps

    @Test func prefixes() {
        #expect(InstalledApps.prefixes(environment: ["HOME": "/home/ada"], runner: "/opt/rt/bin/linux-app-host")
                == ["/home/ada/.local", "/opt/rt", "/usr/local", "/usr"])
        #expect(InstalledApps.prefixes(environment: ["HOME": "/home/ada"], runner: "/usr/bin/linux-app-host")
                == ["/home/ada/.local", "/usr", "/usr/local"])
        #expect(InstalledApps.prefixes(environment: ["LINUXAPPRUNTIME_PREFIXES": "/a:/b", "HOME": "/home/ada"], runner: nil) == ["/a", "/b"])
        #expect(InstalledApps.bundle(identifier: "org.example.App", prefix: "/usr") == "/usr/lib/linux-app/org.example.App.app")
        #expect(InstalledApps.isIdentifier("org.example.App"))
        #expect(!InstalledApps.isIdentifier("nodots") && !InstalledApps.isIdentifier("../x.y") && !InstalledApps.isIdentifier("a..b"))
    }
}
