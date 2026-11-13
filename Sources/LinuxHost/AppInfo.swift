import Foundation
import RuntimeABI

/// The app's keys, from the universal bundle's `Info.plist`
/// (`Plan.md` §4): what it was built against and what it uses.
public struct AppInfo: Equatable, Sendable {

    /// A contract the app uses, from `RTContracts`.
    public struct Contract: Equatable, Hashable, Sendable {

        public var name: String

        public var version: UInt32

        public var kind: ContractKind

        public init(name: String, version: UInt32, kind: ContractKind) {
            self.name = name
            self.version = version
            self.kind = kind
        }
    }

    public var identifier: String

    /// `CFBundleName`, or the identifier's last part.
    public var name: String

    /// `CFBundleShortVersionString`.
    public var version: String

    /// `CFBundleVersion`.
    public var build: String

    public var abiVersion: UInt32

    public var targets: [String]

    public var capabilities: Set<Capability>

    public var contracts: [Contract]

    public init(
        identifier: String,
        name: String? = nil,
        version: String = "",
        build: String = "",
        abiVersion: UInt32,
        targets: [String] = [],
        capabilities: Set<Capability> = [],
        contracts: [Contract] = []
    ) {
        self.identifier = identifier
        self.name = name ?? identifier.split(separator: ".").last.map(String.init) ?? identifier
        self.version = version
        self.build = build
        self.abiVersion = abiVersion
        self.targets = targets
        self.capabilities = capabilities
        self.contracts = contracts
    }

    /// Reads the keys from an `Info.plist` dictionary.
    public init(infoDictionary info: [String: Any]) throws(AppInfoError) {
        guard let abiVersion = Self.uint32(info["RTABIVersion"]) else {
            throw .missing("RTABIVersion")
        }
        var contracts = [Contract]()
        for entry in info["RTContracts"] as? [[String: Any]] ?? [] {
            guard let name = entry["Name"] as? String,
                  let version = Self.uint32(entry["Version"]),
                  let kind = (entry["Kind"] as? String).flatMap(ContractKind.init(name:)) else {
                throw .malformed("RTContracts")
            }
            contracts.append(Contract(name: name, version: version, kind: kind))
        }
        self.init(
            identifier: info["CFBundleIdentifier"] as? String ?? "",
            name: info["CFBundleName"] as? String,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "",
            abiVersion: abiVersion,
            targets: info["RTTargets"] as? [String] ?? [],
            capabilities: Set((info["RTCapabilities"] as? [String] ?? []).map(Capability.init(_:))),
            contracts: contracts
        )
    }

    /// Reads a property list file: a universal bundle's `Info.plist`.
    public init(contentsOf path: String) throws(AppInfoError) {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw .missing(path)
        }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw .malformed(path)
        }
        guard let dictionary = plist as? [String: Any] else {
            throw .malformed(path)
        }
        try self.init(infoDictionary: dictionary)
    }

    public var contractNames: Set<String> {
        Set(contracts.map(\.name))
    }

    private static func uint32(_ value: Any?) -> UInt32? {
        switch value {
        case let value as UInt32: value
        case let value as Int: UInt32(exactly: value)
        case let value as NSNumber: value.uint32Value
        default: nil
        }
    }
}

/// A problem with the app's keys.
public enum AppInfoError: Error, Equatable, CustomStringConvertible {

    case missing(String)

    case malformed(String)

    public var description: String {
        switch self {
        case .missing(let key): "the app has no \(key); is it a universal bundle from guest.py?"
        case .malformed(let key): "the app's \(key) is malformed"
        }
    }
}

extension ContractKind {

    /// The `Kind` string in `RTContracts`.
    init?(name: String) {
        switch name {
        case "contract": self = .contract
        case "callback": self = .callback
        default: return nil
        }
    }
}
