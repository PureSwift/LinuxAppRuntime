import DynamicRuntime
import Foundation
import LinuxBluetooth
import LinuxCoreModel
import LinuxGraphics
import LinuxWebKit
import LinuxHost
import DynamicUI
import RuntimeABI

/// What this host implements: the built-ins and its modules' contracts.
public enum HostContracts {

    /// The modules `linux-app-host` registers (`HostApp.modules`): the
    /// player's contracts, without building the player, Bluetooth,
    /// graphics, web views, files, settings and model stores.
    nonisolated(unsafe) public static let modules: [any HostModule.Type] = [
        PlayerContracts.self, LinuxBluetooth.self, LinuxGraphics.self, LinuxWebKit.self, LinuxFiles.self, LinuxDefaults.self,
        LinuxModelStore.self,
    ]

    public static var provided: [String: ContractDescriptor] {
        AppCompatibility.providedContracts(modules)
    }

    /// Capabilities some contract here serves: `network` is what lets a
    /// web view's page reach the network.
    public static let capabilities: Set<Capability> = [.bluetooth, .graphics, .network]
}

/// How the guest's code gets into the app (`Packager.md` §2).
public enum Engine: String, CaseIterable, Sendable {
    /// The bundle's sealed `libapp.a` for the target.
    case slice
    /// `App.wasm` translated to C by AppRuntime's wasm2c shim.
    case wasm2c

    /// A slice if the bundle has one, else wasm2c.
    public static func preferred(for bundle: UniversalBundle, target: LinuxTarget) -> Engine {
        bundle.slice(target) != nil ? .slice : .wasm2c
    }
}

/// The checks of `Packager.md` §1.
public struct Validator {

    public var bundle: UniversalBundle

    public var target: LinuxTarget

    public var engine: Engine

    /// Missing contracts warn instead of failing; the guest sees them as
    /// absent.
    public var allowMissingContracts = false

    public var provided: [String: ContractDescriptor] = HostContracts.provided

    public init(bundle: UniversalBundle, target: LinuxTarget, engine: Engine) {
        self.bundle = bundle
        self.target = target
        self.engine = engine
    }

    public func validate() -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let info = bundle.info

        if !Self.isIdentifier(info.identifier) {
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
        for problem in bundle.codeResourceProblems() {
            diagnostics.append(.error("the bundle doesn't match its CodeResources: \(problem)"))
        }
        switch engine {
        case .slice:
            if let slice = bundle.slice(target) {
                for problem in SliceInspector.problems(slice, target: target) {
                    diagnostics.append(.error("\(target.rawValue) slice: \(problem)"))
                }
            } else {
                diagnostics.append(.error("the bundle has no \(target.rawValue) slice; use --engine wasm2c"))
            }
        case .wasm2c:
            if bundle.wasm == nil {
                diagnostics.append(.error("the bundle has no wasm32/App.wasm"))
            }
        }
        for capability in info.capabilities.subtracting(HostContracts.capabilities).sorted(by: { $0.rawValue < $1.rawValue }) {
            diagnostics.append(.warning("the app declares \(capability.rawValue), which the Linux host doesn't support yet"))
        }
        return diagnostics
    }

    /// `org.example.App`: two or more dot-separated parts of letters,
    /// digits, `-` and `_`.
    static func isIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    static func isFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
            && !value.hasPrefix("-")
    }
}

/// Reads a slice's archive: every ELF object in it must be for the target.
public enum SliceInspector {

    public static func problems(_ archive: URL, target: LinuxTarget) -> [String] {
        guard let data = FileManager.default.contents(atPath: archive.path) else {
            return ["can't read \(archive.path)"]
        }
        let machines: [UInt16]
        do {
            machines = try elfMachines(Array(data))
        } catch {
            return [error.message]
        }
        if machines.isEmpty {
            return ["the archive has no ELF objects"]
        }
        let wrong = Set(machines.filter { $0 != target.elfMachine })
        return wrong.isEmpty ? [] : ["objects are for ELF machine \(wrong.sorted()), not \(target.elfMachine) (\(target.machine))"]
    }

    /// `e_machine` of each ELF member of a `!<arch>` archive.
    static func elfMachines(_ bytes: [UInt8]) throws(PackagerError) -> [UInt16] {
        let magic = Array("!<arch>\n".utf8)
        guard bytes.starts(with: magic) else {
            throw PackagerError("not an ar archive")
        }
        var machines: [UInt16] = []
        var offset = magic.count
        while offset + 60 <= bytes.count {
            let header = bytes[offset..<offset + 60]
            guard header.suffix(2).elementsEqual([0x60, 0x0A]) else {
                throw PackagerError("malformed archive member at \(offset)")
            }
            let sizeField = String(decoding: header.dropFirst(48).prefix(10), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeField), offset + 60 + size <= bytes.count else {
                throw PackagerError("malformed archive member size at \(offset)")
            }
            let body = bytes[(offset + 60)..<(offset + 60 + size)]
            if body.count >= 20, body.starts(with: [0x7F, 0x45, 0x4C, 0x46]) {
                let start = body.startIndex
                machines.append(UInt16(body[start + 18]) | UInt16(body[start + 19]) << 8)
            }
            offset += 60 + size + (size % 2)
        }
        return machines
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
