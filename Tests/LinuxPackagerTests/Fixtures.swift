import Crypto
import Foundation
@testable import LinuxPackager

/// A universal bundle on disk, as `guest.py bundle` writes one.
struct Fixture {

    let url: URL

    init(
        identifier: String = "org.example.Demo",
        executable: String = "Demo",
        abi: Int = 1,
        contracts: [(name: String, version: Int, kind: String)] = [("org.pureswift.ui.Renderer", 1, "contract")],
        capabilities: [String] = [],
        machine: UInt16 = LinuxTarget.arm64.elfMachine,
        elfType: UInt16 = 3,
        targets: [LinuxTarget] = [.arm64, .x86_64],
        wasm: Bool = true,
        signed: Bool = true
    ) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)/\(identifier).app")
        let files = FileManager.default
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": executable,
            "CFBundleName": "Demo App",
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "3",
            "RTABIVersion": abi,
            "RTCapabilities": capabilities,
            "RTContracts": contracts.map { ["Name": $0.name, "Version": $0.version, "Kind": $0.kind] },
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        for target in targets {
            let directory = url.appendingPathComponent("lib/\(target.rawValue)")
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let elfMachine = target == .arm64 ? machine : target.elfMachine
            // What a runner loads: a Linux slice is only its libapp.so.
            try Data(Self.elf(machine: elfMachine, type: target == .arm64 ? elfType : 3, is64: target != .armv7))
                .write(to: directory.appendingPathComponent("libapp.so"))
        }
        if wasm {
            try files.createDirectory(at: url.appendingPathComponent("wasm32"), withIntermediateDirectories: true)
            try Data([0, 0x61, 0x73, 0x6D, 1, 0, 0, 0]).write(to: url.appendingPathComponent("wasm32/App.wasm"))
        }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url.appendingPathComponent("icon.png"))
        try files.createDirectory(at: url.appendingPathComponent("resources/en.lproj"), withIntermediateDirectories: true)
        try "\"hello\" = \"Hello\";".write(to: url.appendingPathComponent("resources/en.lproj/Localizable.strings"),
                                           atomically: true, encoding: .utf8)
        if signed {
            try sign()
        }
    }

    /// Writes `_CodeSignature/CodeResources` for the files there now.
    func sign() throws {
        let bundle = try UniversalBundle(url: url)
        var hashes: [String: Data] = [:]
        for path in bundle.allFiles(under: url) where !path.hasPrefix("_CodeSignature/") {
            hashes[path] = Data(SHA256.hash(data: try Data(contentsOf: url.appendingPathComponent(path))))
        }
        let signature = url.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["files": hashes], format: .xml, options: 0)
            .write(to: signature.appendingPathComponent("CodeResources"))
    }

    var bundle: UniversalBundle {
        get throws { try UniversalBundle(url: url) }
    }

    /// A minimal ELF header: `e_machine`, `e_type` (3 a shared library, 1
    /// an object) and its class.
    static func elf(machine: UInt16, type: UInt16 = 3, is64: Bool = true) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 64)
        header[0...3] = [0x7F, 0x45, 0x4C, 0x46]
        header[4] = is64 ? 2 : 1
        header[5] = 1
        header[16] = UInt8(type & 0xFF)
        header[17] = UInt8(type >> 8)
        header[18] = UInt8(machine & 0xFF)
        header[19] = UInt8(machine >> 8)
        return header
    }
}

/// Plays `swift build`: records commands and makes the binary it would.
final class FakeRunner: CommandRunning {

    var commands: [[String]] = []

    let bin = FileManager.default.temporaryDirectory.appendingPathComponent("bin-\(UUID().uuidString)")

    func run(_ arguments: [String], directory: URL?, environment: [String: String]) throws(PackagerError) -> String {
        commands.append(arguments)
        if arguments.starts(with: ["swift", "build"]) {
            if arguments.last == "--show-bin-path" {
                return bin.path + "\n"
            }
            let product = arguments[arguments.firstIndex(of: "--product")! + 1]
            try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try? Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent(product))
        }
        return ""
    }
}
