@_exported import CRuntime
@_exported import LinuxHost
import Foundation
import LinuxBluetooth
import LinuxSDL
import LinuxUI

/// The app's `main` (`Plan.md` §4): finds the app's bundle, starts SDL,
/// checks and prepares the app, calls `rt_main`, and runs the main loop.
///
/// ```
/// linux-app-host [--bundle App.app] [--open URL] [--script FILE]
/// ```
///
/// - `--bundle`: the universal bundle whose `Info.plist` describes the app
///   linked in; by default `App.app` next to the executable, or
///   `LINUXAPPRUNTIME_BUNDLE`.
/// - `--open`: a URL for the app to open once it started.
/// - `--script`: input to replay and screenshots to take (`HostScript`).
public enum HostApp {

    /// Every module this host has.
    public static let modules: [any HostModule.Type] = [LinuxUIModule.self, LinuxBluetooth.self]

    public static func main(_ entry: AppEntryPoints?) -> Never {
        let arguments = Arguments(CommandLine.arguments)
        guard let entry else {
            fail("this host was built without an app; build it with LINUXAPPRUNTIME_APP_LIBRARY set to an app's libapp.a")
        }
        guard let bundle = arguments.bundle ?? defaultBundle() else {
            fail("no app bundle: pass --bundle App.app")
        }
        let info: AppInfo
        do {
            info = try AppInfo(contentsOf: bundle + "/Info.plist")
        } catch {
            fail("\(bundle): \(error)")
        }

        if info.contractNames.contains(LinuxUIModule.contracts[0].name) {
            guard let sdl = SDLApp.start(title: info.name, identifier: info.identifier, version: info.version) else {
                fail("the app has a user interface, and SDL can't show it")
            }
            LinuxUIModule.presenter = sdl
        }

        let host = AppHost(info: info, modules: modules, bundlePath: bundle)
        do {
            try host.prepare()
        } catch {
            fail(error.description)
        }
        let status = host.start(entry)
        guard status == .ok else {
            fail("the app didn't start: \(status)")
        }
        if let url = arguments.open {
            MainLoop.shared.post {
                LinuxApplication.open(url)
            }
        }
        var script: HostScript?
        if let path = arguments.script {
            do {
                script = try HostScript(contentsOf: path)
            } catch {
                fail("\(path): \(error)")
            }
            script?.start()
        }
        if SDLApp.shared?.windows.isEmpty != false, script == nil {
            HostLog.debug("the app has no window; running until interrupted")
        }
        MainLoop.shared.run()
        exit(script?.failed == true ? 1 : 0)
    }

    static func fail(_ message: String) -> Never {
        HostLog.error(message)
        exit(1)
    }

    /// `App.app` next to the executable, or `LINUXAPPRUNTIME_BUNDLE`.
    static func defaultBundle() -> String? {
        if let path = ProcessInfo.processInfo.environment["LINUXAPPRUNTIME_BUNDLE"] {
            return path
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = executable.deletingLastPathComponent().appendingPathComponent("App.app").path
        return FileManager.default.fileExists(atPath: candidate + "/Info.plist") ? candidate : nil
    }

    struct Arguments {
        var bundle: String?
        var open: String?
        var script: String?

        init(_ arguments: [String]) {
            var iterator = arguments.dropFirst().makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case "--bundle": bundle = iterator.next()
                case "--open": open = iterator.next()
                case "--script": script = iterator.next()
                default: HostLog.warning("ignoring \(argument)")
                }
            }
        }
    }
}
