// What DarwinUI uses from DarwinAppRuntime's host, here over LinuxHost:
// `AppHost.logger`, which takes OSLog-style interpolations, and
// `DarwinBundle.bundle`, whose resources images load from. The rest of this
// module is DarwinUI, copied by Scripts/sync-darwinui.sh.
import Foundation
import LinuxHost

/// A logger with OSLog's interpolations, writing through `HostLog`.
public struct HostLogger: Sendable {

    public struct Message: ExpressibleByStringInterpolation, Sendable {

        public struct StringInterpolation: StringInterpolationProtocol {
            var output = ""
            public init(literalCapacity: Int, interpolationCount: Int) { }
            public mutating func appendLiteral(_ literal: String) { output += literal }
            public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .auto) { output += "\(value)" }
        }

        let text: String

        public init(stringLiteral value: String) { text = value }

        public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.output }
    }

    public enum Privacy: Sendable { case auto, `public`, `private` }

    public func notice(_ message: Message) { HostLog.debug(message.text) }

    public func warning(_ message: Message) { HostLog.warning(message.text) }

    public func error(_ message: Message) { HostLog.error(message.text) }

    public func debug(_ message: Message) { HostLog.debug(message.text) }
}

extension AppHost {

    /// DarwinUI's log.
    public static let logger = HostLogger()
}

/// The app's bundle, whose `resources/` images load from.
public enum DarwinBundle {

    public static var bundle: Bundle {
        LinuxBundle.resources.flatMap { Bundle(path: $0) } ?? .main
    }
}
