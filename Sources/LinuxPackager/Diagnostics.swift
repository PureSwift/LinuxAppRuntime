/// Something `validate` found.
public struct Diagnostic: Equatable, Sendable, CustomStringConvertible {

    public enum Severity: Sendable {
        case error
        case warning
    }

    public var severity: Severity

    public var message: String

    public static func error(_ message: String) -> Diagnostic {
        Diagnostic(severity: .error, message: message)
    }

    public static func warning(_ message: String) -> Diagnostic {
        Diagnostic(severity: .warning, message: message)
    }

    public var description: String {
        "\(severity == .error ? "error" : "warning"): \(message)"
    }
}

/// Why the packager stopped.
public struct PackagerError: Error, Equatable, CustomStringConvertible {

    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}
