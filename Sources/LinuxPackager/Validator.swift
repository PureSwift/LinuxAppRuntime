import DynamicRuntime
import Foundation
import LinuxBluetooth
import LinuxCoreModel
import LinuxDevice
import LinuxGraphics
import LinuxWebKit
import LinuxHost
import DynamicUI
import RuntimeABI
import RuntimeFormatting

/// What this host implements: the built-ins and its modules' contracts.
public enum HostContracts {

    /// The modules `linux-app-host` registers (`HostApp.modules`): the
    /// player's contracts, without building the player, Bluetooth,
    /// graphics, web views, files, settings, model stores, formatting and
    /// the device.
    nonisolated(unsafe) public static let modules: [any HostModule.Type] = [
        PlayerContracts.self, LinuxBluetooth.self, LinuxGraphics.self, LinuxWebKit.self, LinuxFiles.self, LinuxDefaults.self,
        LinuxModelStore.self, HostFormattingModule.self, LinuxDeviceModule.self,
    ]

    public static var provided: [String: ContractDescriptor] {
        AppCompatibility.providedContracts(modules)
    }

    /// Capabilities some contract here serves: `network` is what lets a
    /// web view's page reach the network.
    public static let capabilities: Set<Capability> = [.bluetooth, .graphics, .network]
}

/// The checks of `Packager.md` §1, which install makes before it copies an
/// app. The runner makes the ABI and contract checks again at each launch.
public struct Validator {

    public var bundle: UniversalBundle

    public var target: LinuxTarget

    /// Missing contracts warn instead of failing; the guest sees them as
    /// absent.
    public var allowMissingContracts = false

    public var provided: [String: ContractDescriptor] = HostContracts.provided

    public init(bundle: UniversalBundle, target: LinuxTarget) {
        self.bundle = bundle
        self.target = target
    }

    public func validate() -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let info = bundle.info

        if !InstalledApps.isIdentifier(info.identifier) {
            diagnostics.append(.error("CFBundleIdentifier \"\(info.identifier)\" isn't a reverse-DNS identifier"))
        }
        if !Self.isFileName(bundle.executable) {
            diagnostics.append(.error("CFBundleExecutable \"\(bundle.executable)\" isn't a file name"))
        }
        if info.abiVersion > runtimeABIVersion {
            diagnostics.append(.error("the app needs rt ABI \(info.abiVersion); this host provides \(runtimeABIVersion)"))
        }
        for contract in info.contracts {
            guard let descriptor = provided[contract.name] else {
                let message = "\(contract.name) isn't implemented on Linux"
                diagnostics.append(allowMissingContracts ? .warning(message + "; the app sees it as absent") : .error(message))
                continue
            }
            if descriptor.kind != contract.kind {
                diagnostics.append(.error("\(contract.name) is a different kind of interface on Linux"))
            } else if descriptor.version < contract.version {
                diagnostics.append(.warning("\(contract.name) is version \(descriptor.version) on Linux; the app was built against \(contract.version)"))
            }
        }
        if !FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("_CodeSignature/CodeResources").path) {
            diagnostics.append(.error("the bundle isn't signed: it has no _CodeSignature/CodeResources, which the runner checks its library against"))
        }
        for problem in bundle.codeResourceProblems() {
            diagnostics.append(.error("the bundle doesn't match its CodeResources: \(problem)"))
        }
        if let slice = bundle.slice(target) {
            for problem in SliceInspector.problems(slice, target: target) {
                diagnostics.append(.error("\(target.rawValue) slice: \(problem)"))
            }
        } else {
            diagnostics.append(.error("the bundle has no \(target.rawValue) slice (\(target.sharedLibrary))"))
        }
        for capability in info.capabilities.subtracting(HostContracts.capabilities).sorted(by: { $0.rawValue < $1.rawValue }) {
            diagnostics.append(.warning("the app declares \(capability.rawValue), which the Linux host doesn't support yet"))
        }
        return diagnostics
    }

    static func isFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
            && !value.hasPrefix("-")
    }
}

/// Reads a slice's `libapp.so`: a shared library for the target.
/// `guest.py` checked the rest when it built it: what it leaves undefined,
/// what it exports, and that it names no other library.
public enum SliceInspector {

    public static func problems(_ library: URL, target: LinuxTarget) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: library.path) else {
            return ["can't read \(library.lastPathComponent)"]
        }
        defer { try? handle.close() }
        let header = Array((try? handle.read(upToCount: 20)) ?? Data())
        guard header.count == 20, header.starts(with: [0x7F, 0x45, 0x4C, 0x46]) else {
            return ["\(library.lastPathComponent) isn't an ELF file"]
        }
        var problems: [String] = []
        let elfClass = header[4], endian = header[5]
        let expectedClass: UInt8 = target == .armv7 ? 1 : 2
        if elfClass != expectedClass || endian != 1 {
            problems.append("it's \(elfClass == 1 ? "32" : "64")-bit\(endian == 1 ? "" : " big-endian"), not as \(target.machine) is")
        }
        let type = UInt16(header[16]) | UInt16(header[17]) << 8
        if type != 3 {
            problems.append("it isn't a shared library (ELF type \(type))")
        }
        let machine = UInt16(header[18]) | UInt16(header[19]) << 8
        if machine != target.elfMachine {
            problems.append("it's for ELF machine \(machine), not \(target.elfMachine) (\(target.machine))")
        }
        return problems
    }
}

/// The SwiftUI player's contracts (`LinuxUI`'s `DarwinUI` module), as the
/// packager checks against them: the same descriptors, without Cacao.
public enum PlayerContracts: HostModule {

    public static var contracts: [ContractDescriptor] {
        [RendererProxy.descriptor, RendererDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) { }
}
