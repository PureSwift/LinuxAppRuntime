import DynamicFiles
import Foundation
import RuntimeHost
import Testing
@testable import LinuxHost

/// Records the one answer an operation gets.
final class RecordingCallback: FileCallback {

    var answer: String?

    func didComplete() { answer = "complete" }

    func didRead(_ data: [UInt8]) { answer = "read \(String(decoding: data, as: UTF8.self))" }

    func didList(_ names: [String]) { answer = "list \(names.joined(separator: ","))" }

    func didGetAttributes(kind: Int32, size: Int64, modified: Int64) {
        answer = "attributes \(kind) \(size) \(modified > 0)"
    }

    func didFail(_ error: Int32) { answer = "fail \(error)" }
}

/// `HostFiles` is configured once for the process: one test at a time.
@Suite(.serialized) struct LinuxFilesTests {

    @Test func xdgDirectories() throws {
        let directories = try LinuxFiles.directories(
            identifier: "org.example.App", resources: "/apps/App.app/resources",
            environment: ["HOME": "/home/ada", "XDG_RUNTIME_DIR": "/run/user/1000"], userID: 1000)
        #expect(directories == [
            .documents: "/home/ada/.local/share/org.example.App/Documents",
            .data: "/home/ada/.local/share/org.example.App/Data",
            .caches: "/home/ada/.cache/org.example.App",
            .temporary: "/run/user/1000/org.example.App",
            .bundle: "/apps/App.app/resources",
        ])
    }

    @Test func xdgVariablesAndTheirDefaults() throws {
        let directories = try LinuxFiles.directories(
            identifier: "org.example.App", resources: nil,
            environment: ["HOME": "/home/ada", "XDG_DATA_HOME": "/data/ada", "XDG_CACHE_HOME": "relative/is/ignored"],
            userID: 1000)
        #expect(directories[.documents] == "/data/ada/org.example.App/Documents")
        #expect(directories[.caches] == "/home/ada/.cache/org.example.App")
        // Without a runtime directory, the app's own under /tmp.
        #expect(directories[.temporary] == "/tmp/org.example.App-1000")
        // No bundle, no bundle directory: its files aren't found.
        #expect(directories[.bundle] == nil)
    }

    @Test func aContainer() throws {
        let directories = try LinuxFiles.directories(
            identifier: "org.example.App", resources: "/roms/ports/app/App.app/resources",
            environment: ["HOME": "/home/ada", "LINUXAPPRUNTIME_CONTAINER": "/roms/ports/app/conf"])
        #expect(directories == [
            .documents: "/roms/ports/app/conf/Documents",
            .data: "/roms/ports/app/conf/Data",
            .caches: "/roms/ports/app/conf/Caches",
            .temporary: "/roms/ports/app/conf/tmp",
            .bundle: "/roms/ports/app/App.app/resources",
        ])
        #expect(throws: LinuxFilesError.self) {
            try LinuxFiles.directories(identifier: "org.example.App", resources: nil,
                                       environment: ["LINUXAPPRUNTIME_CONTAINER": "conf"])
        }
    }

    @Test func identifiersMustNameADirectory() {
        for identifier in ["", ".", "..", "org/example", "a\0b"] {
            #expect(throws: LinuxFilesError.self) {
                try LinuxFiles.directories(identifier: identifier, resources: nil, environment: ["HOME": "/home/ada"])
            }
        }
        #expect(throws: LinuxFilesError.self) {
            try LinuxFiles.directories(identifier: "org.example.App", resources: nil, environment: [:])
        }
    }

    /// The contract end to end: `HostFiles` in a container, answering on
    /// the main loop.
    @Test func filesAnswerOnTheMainLoop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linux-files-\(UUID())")
        let resources = root.appendingPathComponent("App.app/resources")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("levels"), withIntermediateDirectories: true)
        try Data("level one".utf8).write(to: resources.appendingPathComponent("levels/1.map"))
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try LinuxFiles.directories(
            identifier: "org.example.App", resources: resources.path,
            environment: ["LINUXAPPRUNTIME_CONTAINER": root.appendingPathComponent("conf").path])
        try HostFiles.configure(HostFiles.Configuration(directories: directories, deliver: LinuxFiles.deliver))
        let files = HostFiles.shared()

        func perform(_ operation: (RecordingCallback) -> Void) -> String? {
            let callback = RecordingCallback()
            operation(callback)
            MainLoop.shared.run { callback.answer != nil }
            return callback.answer
        }
        let documents = FileDirectory.documents.rawValue
        // The writable directories are there from the start.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("conf/Documents").path))
        #expect(perform { files.read(FileDirectory.bundle.rawValue, path: "levels/1.map", offset: 0, length: -1, callback: $0) }
                == "read level one")
        #expect(perform { files.write(documents, path: "saves/slot1.sav", data: Array("saved".utf8), mode: 0, callback: $0) }
                == "complete")
        #expect(perform { files.write(documents, path: "saves/slot1.sav", data: Array(" more".utf8), mode: 1, callback: $0) }
                == "complete")
        #expect(perform { files.read(documents, path: "saves/slot1.sav", offset: 0, length: -1, callback: $0) } == "read saved more")
        #expect(perform { files.list(documents, path: "", callback: $0) } == "list saves/")
        #expect(perform { files.attributes(documents, path: "saves/slot1.sav", callback: $0) } == "attributes 0 10 true")
        #expect(perform { files.copy(FileDirectory.bundle.rawValue, path: "levels", toDirectory: documents, toPath: "levels", callback: $0) }
                == "complete")
        #expect(perform { files.write(FileDirectory.bundle.rawValue, path: "x", data: [], mode: 0, callback: $0) }
                == "fail \(FileError.readOnly.rawValue)")
        #expect(perform { files.read(documents, path: "../escape", offset: 0, length: -1, callback: $0) }
                == "fail \(FileError.invalidPath.rawValue)")
        #expect(try String(contentsOf: root.appendingPathComponent("conf/Documents/levels/1.map"), encoding: .utf8) == "level one")
    }
}
