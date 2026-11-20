@_exported import CRuntime
@_exported import LinuxHost
import CLinuxHost
import CacaoSDL
import DynamicGraphics
import Foundation
import LinuxBluetooth
import LinuxCoreModel
import LinuxGraphics
import LinuxWebKit
import LinuxUI
import RuntimeFormatting

/// The runner (`Plan.md` §4): finds an app's bundle, checks the app
/// against this host, loads its `libapp.so`, calls `rt_main`, and runs
/// Cacao's main loop with a window showing the guest's renderer. No app is
/// linked in: every app runs in this one program.
///
/// ```
/// linux-app-host [--bundle] App.app | IDENTIFIER [[--open] URL]
/// ```
///
/// - The app: a bundle's path, or an installed app's identifier
///   (`InstalledApps`); by default `LINUXAPPRUNTIME_BUNDLE`, or `App.app`
///   next to the executable, as a PortMaster port has it.
/// - `--open`: a URL for the app to open once it started, as a desktop
///   entry's `%u` passes it.
///
/// Cacao's `CACAO_SCREENSHOT=path.png` saves the first frame and quits.
public enum HostApp {

    /// Every module this host has: the SwiftUI player (DarwinUI, on Cacao),
    /// Bluetooth, GL surfaces and web pages, which the player shows, the
    /// app's files, settings and model stores, and AppRuntime's date and
    /// number formatting over Swift Foundation.
    public static let modules: [any HostModule.Type] = [
        DarwinUI.self, LinuxBluetooth.self, LinuxGraphics.self, LinuxWebKit.self, LinuxFiles.self, LinuxDefaults.self,
        LinuxModelStore.self, HostFormattingModule.self,
    ]

    /// The window's title: the app's name.
    nonisolated(unsafe) static var title = ""

    public static func main() -> Never {
        let arguments = Arguments(CommandLine.arguments)
        let bundle: String
        switch arguments.app {
        case .bundle(let path)?:
            bundle = path
        case .identifier(let identifier)?:
            guard let found = InstalledApps.find(identifier: identifier) else {
                fail("\(identifier) isn't installed (searched \(InstalledApps.prefixes().map { $0 + "/" + InstalledApps.directory }.joined(separator: ", ")))")
            }
            bundle = found
        case nil:
            guard let found = defaultBundle() else {
                fail("no app: pass a bundle's path or an installed app's identifier")
            }
            bundle = found
        }
        let info: AppInfo
        let executable: String?
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: bundle + "/Info.plist"))
            info = try AppInfo(propertyList: data)
            let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            executable = dictionary?["CFBundleExecutable"] as? String
        } catch {
            fail("\(bundle): \(error)")
        }
        // Shown by `ps` and `top` as the app, not as the runner.
        clinuxhost_set_process_name(executable ?? info.name)

        // Cacao's loop drains the main queue every turn; the host's own
        // loop runs its jobs and timers there.
        let ui = info.contractNames.contains(DarwinUI.contracts[0].name)
        if ui {
            MainLoop.shared.runsOnMainQueue = true
        }

        // The app's ABI and contracts, checked at every launch: this
        // runner may have changed since the app was installed.
        let host = AppHost(info: info, modules: modules, bundlePath: bundle)
        do {
            try host.prepare()
        } catch {
            fail(error.description)
        }
        guard let target = LinuxTarget.native else {
            fail("this machine isn't one of the Linux targets: \(LinuxTarget.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let library: AppLibrary
        do {
            library = try AppLibrary.load(bundle: bundle, target: target, preload: preload(for: info))
        } catch {
            fail(error.description)
        }
        HostLog.debug("loaded \(library.path)")

        let status = host.start(library.entryPoints)
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

    /// The libraries an app's `libapp.so` binds to that the runner doesn't
    /// link: GLES 2.0 for an app that draws (`Surface`), which the library
    /// doesn't name itself.
    static func preload(for info: AppInfo) -> [String] {
        info.contractNames.contains(SurfaceProxy.descriptor.name) ? [LinuxGraphics.gles] : []
    }

    static func fail(_ message: String) -> Never {
        HostLog.error(message)
        exit(1)
    }

    /// `LINUXAPPRUNTIME_BUNDLE`, or `App.app` next to the executable.
    static func defaultBundle() -> String? {
        if let path = ProcessInfo.processInfo.environment["LINUXAPPRUNTIME_BUNDLE"] {
            return path
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = executable.deletingLastPathComponent().appendingPathComponent("App.app").path
        return FileManager.default.fileExists(atPath: candidate + "/Info.plist") ? candidate : nil
    }

    struct Arguments {

        enum App: Equatable {
            case bundle(String)
            case identifier(String)
        }

        var app: App?
        var open: String?

        init(_ arguments: [String]) {
            var iterator = arguments.dropFirst().makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case "--bundle":
                    app = iterator.next().map(App.bundle)
                case "--open":
                    open = iterator.next()
                case _ where app == nil && !argument.hasPrefix("-"):
                    // A path names a bundle; otherwise it's an identifier.
                    app = argument.contains("/") || argument.hasSuffix(".app") ? .bundle(argument) : .identifier(argument)
                case _ where open == nil && !argument.hasPrefix("-"):
                    open = argument
                default:
                    HostLog.warning("ignoring \(argument)")
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
