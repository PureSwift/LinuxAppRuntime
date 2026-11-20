import Foundation

/// A Linux target of AppRuntime's slices (`guest.py targets`).
public enum LinuxTarget: String, CaseIterable, Sendable {

    case arm64 = "linux-arm64"
    case x86_64 = "linux-x86_64"
    case armv7 = "linux-armv7"

    /// `e_machine` of the target's ELF objects.
    public var elfMachine: UInt16 {
        switch self {
        case .arm64: 183
        case .x86_64: 62
        case .armv7: 40
        }
    }

    /// `uname -m`'s name for the machine.
    public var machine: String {
        switch self {
        case .arm64: "aarch64"
        case .x86_64: "x86_64"
        case .armv7: "armv7l"
        }
    }

    /// This machine's target; nil on one that isn't a Linux target.
    public static var native: LinuxTarget? {
        target(machine: machineName)
    }

    /// `uname -m`: `aarch64`, `x86_64`, `armv7l`.
    public static var machineName: String {
        var name = utsname()
        uname(&name)
        return withUnsafeBytes(of: &name.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public static func target(machine: String) -> LinuxTarget? {
        switch machine {
        case "aarch64", "arm64": .arm64
        case "x86_64", "amd64": .x86_64
        case "armv7l", "armv7": .armv7
        default: nil
        }
    }
}
