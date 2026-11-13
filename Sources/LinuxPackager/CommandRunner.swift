import Foundation

/// Runs the packager's tools: `swift`, `python3`, `tar`. Tests replace it.
public protocol CommandRunning {

    /// Runs `arguments[0]` (from `PATH`) with the rest; its output, or an
    /// error with its output if it fails.
    @discardableResult
    func run(_ arguments: [String], directory: URL?, environment: [String: String]) throws(PackagerError) -> String
}

/// Runs commands with Foundation's `Process`, echoing them when verbose.
public struct CommandRunner: CommandRunning {

    public var verbose: Bool

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    public func run(_ arguments: [String], directory: URL?, environment: [String: String]) throws(PackagerError) -> String {
        if verbose {
            FileHandle.standardError.write(Data("$ \(arguments.joined(separator: " "))\n".utf8))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var merged = ProcessInfo.processInfo.environment
        merged.merge(environment) { $1 }
        process.environment = merged
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw PackagerError("can't run \(arguments[0]): \(error)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let tail = text.split(separator: "\n").suffix(30).joined(separator: "\n")
            throw PackagerError("\(arguments.prefix(3).joined(separator: " ")) … failed (\(process.terminationStatus)):\n\(tail)")
        }
        return text
    }
}
