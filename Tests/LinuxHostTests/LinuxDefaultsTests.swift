import Foundation
import RuntimeHost
import Testing
@testable import LinuxHost

/// `HostDefaults.storage` is one for the process: one test at a time.
@Suite(.serialized) struct LinuxDefaultsTests {

    @Test func paths() throws {
        #expect(try LinuxDefaults.path(identifier: "org.example.App", environment: ["HOME": "/home/ada"])
                == "/home/ada/.config/org.example.App/Defaults")
        #expect(try LinuxDefaults.path(identifier: "org.example.App",
                                       environment: ["HOME": "/home/ada", "XDG_CONFIG_HOME": "/etc/ada"])
                == "/etc/ada/org.example.App/Defaults")
        // A relative XDG_CONFIG_HOME is ignored, as the specification says.
        #expect(try LinuxDefaults.path(identifier: "org.example.App",
                                       environment: ["HOME": "/home/ada", "XDG_CONFIG_HOME": "config"])
                == "/home/ada/.config/org.example.App/Defaults")
        #expect(try LinuxDefaults.path(identifier: "org.example.App",
                                       environment: ["HOME": "/home/ada", "LINUXAPPRUNTIME_CONTAINER": "/roms/ports/app/conf"])
                == "/roms/ports/app/conf/Defaults")
    }

    @Test func pathsThatCantBe() {
        #expect(throws: LinuxFilesError.self) {
            try LinuxDefaults.path(identifier: "../org.example.App", environment: ["HOME": "/home/ada"])
        }
        #expect(throws: LinuxFilesError.self) {
            try LinuxDefaults.path(identifier: "org.example.App", environment: ["LINUXAPPRUNTIME_CONTAINER": "conf"])
        }
        #expect(throws: LinuxFilesError.self) {
            try LinuxDefaults.path(identifier: "org.example.App", environment: [:])
        }
    }

    /// Settings in a container's file outlast the launch that set them.
    @Test func settingsAreThereAtTheNextLaunch() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("linux-defaults-\(UUID())")
        defer { try? FileManager.default.removeItem(at: container) }
        let path = try LinuxDefaults.path(identifier: "org.example.App",
                                          environment: ["LINUXAPPRUNTIME_CONTAINER": container.path])
        defer { HostDefaults.storage = nil }

        HostDefaults.storage = try FileDefaultsStorage(path: path)
        let defaults = HostDefaults.standard()
        #expect(defaults.setString("Ada", key: "name"))
        #expect(defaults.setData([1, 2, 3], key: "token"))
        #expect(defaults.setString("", key: "empty"))
        #expect(!defaults.setString("x", key: ""))
        defaults.remove("token")
        #expect(FileManager.default.fileExists(atPath: container.appendingPathComponent("Defaults").path))

        // The next launch reads the file again.
        HostDefaults.storage = try FileDefaultsStorage(path: path)
        #expect(defaults.string("name") == "Ada")
        #expect(defaults.string("empty") == "")
        #expect(defaults.data("token") == nil)
        #expect(defaults.keys() == ["empty", "name"])
    }
}
