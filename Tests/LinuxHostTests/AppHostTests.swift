import DynamicRuntime
import Foundation
import RuntimeABI
import RuntimeCore
import RuntimeNative
import Testing
@testable import LinuxHost

/// A module with one contract, for the checks.
enum TestModule: HostModule {

    static let descriptor = ContractDescriptor(name: "org.example.Test", kind: .contract, version: 2, methods: [])

    static var contracts: [ContractDescriptor] {
        [descriptor]
    }

    nonisolated(unsafe) static var registered = 0

    static func register(in registrar: some ContractRegistrar) {
        registered += 1
        registrar.register(descriptor, statics: nil)
    }
}

@Suite(.serialized) struct AppHostTests {

    static let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key><string>org.example.App</string>
            <key>CFBundleName</key><string>Example</string>
            <key>CFBundleShortVersionString</key><string>1.2</string>
            <key>CFBundleVersion</key><string>7</string>
            <key>RTABIVersion</key><integer>1</integer>
            <key>RTTargets</key><array><string>linux-arm64</string></array>
            <key>RTCapabilities</key><array><string>bluetooth</string></array>
            <key>RTContracts</key>
            <array>
                <dict>
                    <key>Name</key><string>org.example.Test</string>
                    <key>Version</key><integer>1</integer>
                    <key>Kind</key><string>contract</string>
                </dict>
            </array>
        </dict>
        </plist>
        """

    func write(_ contents: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("Info-\(UUID().uuidString).plist").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func readsTheBundleKeys() throws {
        let info = try AppInfo(contentsOf: try write(Self.plist))
        #expect(info.identifier == "org.example.App")
        #expect(info.name == "Example")
        #expect(info.version == "1.2")
        #expect(info.build == "7")
        #expect(info.abiVersion == 1)
        #expect(info.targets == ["linux-arm64"])
        #expect(info.capabilities == [.bluetooth])
        #expect(info.contracts == [AppInfo.Contract(name: "org.example.Test", version: 1, kind: .contract)])
    }

    @Test func rejectsMissingAndMalformedKeys() throws {
        #expect(throws: AppInfoError.missing("RTABIVersion")) {
            try AppInfo(infoDictionary: [:])
        }
        #expect(throws: AppInfoError.malformed("RTContracts")) {
            try AppInfo(infoDictionary: ["RTABIVersion": 1, "RTContracts": [["Name": "x"]]])
        }
        #expect(throws: AppInfoError.self) {
            try AppInfo(contentsOf: "/nonexistent/Info.plist")
        }
    }

    @Test func registersOnlyTheModulesTheAppUses() throws {
        let native = NativeRuntime(runtime: HostRuntime())
        TestModule.registered = 0
        let unused = AppInfo(identifier: "a", abiVersion: 1)
        try AppHost(info: unused, modules: [TestModule.self], native: native).prepare()
        #expect(TestModule.registered == 0)

        let used = AppInfo(identifier: "a", abiVersion: 1, contracts: [.init(name: "org.example.Test", version: 1, kind: .contract)])
        let host = AppHost(info: used, modules: [TestModule.self], native: native)
        try host.prepare()
        #expect(TestModule.registered == 1)
        #expect(host.warnings.isEmpty)
    }

    @Test func refusesWhatThisHostCantRun() {
        let native = NativeRuntime(runtime: HostRuntime())
        let newer = AppInfo(identifier: "a", abiVersion: runtimeABIVersion + 1)
        #expect(throws: AppHostError.self) {
            try AppHost(info: newer, modules: [], native: native).prepare()
        }
        let missing = AppInfo(identifier: "a", abiVersion: 1, contracts: [.init(name: "org.example.Missing", version: 1, kind: .contract)])
        #expect(throws: AppHostError.incompatible("org.example.Missing isn't implemented by this host")) {
            try AppHost(info: missing, modules: [], native: native).prepare()
        }
        let wrongKind = AppInfo(identifier: "a", abiVersion: 1, contracts: [.init(name: "org.example.Test", version: 1, kind: .callback)])
        #expect(throws: AppHostError.self) {
            try AppHost(info: wrongKind, modules: [TestModule.self], native: native).prepare()
        }
    }

    @Test func warnsAboutOlderContracts() throws {
        let native = NativeRuntime(runtime: HostRuntime())
        let info = AppInfo(identifier: "a", abiVersion: 1, contracts: [.init(name: "org.example.Test", version: 3, kind: .contract)])
        let host = AppHost(info: info, modules: [TestModule.self], native: native)
        try host.prepare()
        #expect(host.warnings.count == 1)
    }

    // MARK: Built-ins

    @Test func permissionsFollowTheDeclaredCapabilities() {
        LinuxPermissions.declared = [.bluetooth]
        LinuxPermissions.providers = [.bluetooth: GrantedPermission()]
        #expect(LinuxPermissions.status(.bluetooth) == PermissionStatus.granted.rawValue)
        #expect(LinuxPermissions.status(.location) == PermissionStatus.denied.rawValue, "not declared")
        LinuxPermissions.declared = [.bluetooth, .location]
        #expect(LinuxPermissions.status(.location) == PermissionStatus.unavailable.rawValue, "no provider")
    }

    @Test func bundleLanguagesAndStrings() throws {
        LinuxBundle.environment = ["LANGUAGE": "pt_BR:fr", "LANG": "de_DE.UTF-8"]
        #expect(LinuxBundle.preferredLanguages() == ["pt-BR", "fr", "de-DE"])
        LinuxBundle.environment = ["LANG": "C"]
        #expect(LinuxBundle.preferredLanguages() == ["en"])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resources-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("pt.lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "\"hello\" = \"olá\";".write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        LinuxBundle.resources = root.path
        LinuxBundle.environment = ["LANGUAGE": "pt_BR"]
        #expect(LinuxBundle.localizedString("hello", table: nil) == "olá", "pt-BR falls back to pt")
        #expect(LinuxBundle.localizedString("missing", table: nil) == nil)
        LinuxBundle.environment = ProcessInfo.processInfo.environment
        LinuxBundle.resources = nil
    }
}
