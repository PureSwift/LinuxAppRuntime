@_exported import CRuntime
@_exported import LinuxHost
import CLinuxHost
import CacaoSDL
import Foundation
import LinuxBluetooth
import LinuxUI

/// The app's `main` (`Plan.md` §4): finds the app's bundle, checks and
/// prepares the app, calls `rt_main`, and runs Cacao's main loop with a
/// window showing the guest's renderer.
///
/// ```
/// linux-app-host [--bundle App.app] [--open URL]
/// ```
///
/// - `--bundle`: the universal bundle whose `Info.plist` describes the app
///   linked in; by default `App.app` next to the executable, or
///   `LINUXAPPRUNTIME_BUNDLE`.
/// - `--open`: a URL for the app to open once it started.
///
/// Cacao's `CACAO_SCREENSHOT=path.png` saves the first frame and quits.
public enum HostApp {

    /// Every module this host has: the SwiftUI player (DarwinUI, on Cacao)
    /// and Bluetooth.
    public static let modules: [any HostModule.Type] = [DarwinUI.self, LinuxBluetooth.self]

    /// The window's title: the app's name.
    nonisolated(unsafe) static var title = ""

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

        // Cacao's loop drains the main queue every turn; the host's own
        // loop runs its jobs and timers there.
        let ui = info.contractNames.contains(DarwinUI.contracts[0].name)
        if ui {
            MainLoop.shared.runsOnMainQueue = true
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
                HostApplication.open(url)
            }
        }
        guard ui else {
            HostLog.debug("the app has no user interface; running until interrupted")
            MainLoop.shared.run()
            exit(0)
        }
        title = info.name
        MainActor.assumeIsolated {
            SDLHost.run(HostScene())
        }
        exit(0)
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

        init(_ arguments: [String]) {
            var iterator = arguments.dropFirst().makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case "--bundle": bundle = iterator.next()
                case "--open": open = iterator.next()
                default: HostLog.warning("ignoring \(argument)")
                }
            }
        }
    }
}

/// The app's one window.
struct HostScene: App {

    var body: some Scene {
        WindowGroup(HostApp.title) {
            HostRootView()
        }
    }
}

/// The window's content: the first renderer the guest made and still holds,
/// as on Darwin (`HostRuntime.md` §4).
struct HostRootView: View {

    @ObservedObject private var scenes = RendererScenes.shared

    var body: some View {
        if let scene = scenes.scenes.first {
            RendererView(scene: scene)
                .id(scene.id)
        } else {
            Color.clear
        }
    }
}
