// swift-tools-version:6.4
import Foundation
import PackageDescription

/// The Linux host for AppRuntime apps (`Documentation/Plan.md`).
///
/// `linux-app-host` is the runner: it loads an app's `libapp.so`, which
/// defines `rt_main`, `rt_dispatch` and `rt_finalize`, and links no app.
/// AppRuntime comes without its `GuestExports` trait, so the host's own
/// `DynamicRuntime` binds to the runtime directly.
///
/// The environment:
///
/// - `APPRUNTIME_PATH`: a local AppRuntime checkout instead of GitHub;
///   `CACAO_PATH` likewise for PureSwift/Cacao.
let environment = ProcessInfo.processInfo.environment

let appRuntime: Package.Dependency = {
    if let path = environment["APPRUNTIME_PATH"] {
        return .package(name: "AppRuntime", path: path, traits: [])
    }
    return .package(url: "https://github.com/PureSwift/AppRuntime.git", branch: "master", traits: [])
}()

/// Cacao: the SwiftUI API on Linux, drawn with Silica and SDL3, which the
/// player is written against. `CACAO_PATH` points at a local checkout.
let cacao: Package.Dependency = {
    if let path = environment["CACAO_PATH"] {
        return .package(name: "Cacao", path: path)
    }
    return .package(url: "https://github.com/PureSwift/Cacao.git", branch: "develop")
}()

/// The player is DarwinAppRuntime's SwiftUI renderer: on Linux its
/// `import SwiftUI` and `import Combine` are Cacao's modules of those names.
#if os(Linux)
let swiftUI: [Target.Dependency] = [
    .product(name: "SwiftUI", package: "Cacao"),
    .product(name: "Combine", package: "Cacao"),
    .product(name: "Cacao", package: "Cacao"),
]
#else
let swiftUI: [Target.Dependency] = []
#endif

func runtime(_ product: String) -> Target.Dependency {
    .product(name: product, package: "AppRuntime")
}

/// Host code is single-threaded on the main loop (§6.4), and the contract
/// protocols are nonisolated, so it uses the Swift 5 language mode, like
/// AppRuntime's own host-side targets.
let host: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "LinuxAppRuntime",
    platforms: [
        // For development on a Mac, as Cacao: the player is Apple's SwiftUI
        // there.
        .macOS(.v14),
    ],
    products: [
        .library(name: "LinuxHost", targets: ["LinuxHost"]),
        .library(name: "LinuxUI", targets: ["LinuxUI"]),
        .library(name: "LinuxBluetooth", targets: ["LinuxBluetooth"]),
        .library(name: "LinuxGraphics", targets: ["LinuxGraphics"]),
        .library(name: "LinuxWebKit", targets: ["LinuxWebKit"]),
        .library(name: "LinuxCoreModel", targets: ["LinuxCoreModel"]),
        .library(name: "LinuxDevice", targets: ["LinuxDevice"]),
        .library(name: "LinuxDBus", targets: ["LinuxDBus"]),
        .library(name: "LinuxLocation", targets: ["LinuxLocation"]),
        .library(name: "LinuxHostApp", targets: ["LinuxHostApp"]),
        .executable(name: "linux-app-host", targets: ["LinuxAppHost"]),
        .executable(name: "linux-app", targets: ["LinuxAppTool"]),
    ],
    dependencies: [
        appRuntime,
        cacao,
        // D-Bus, which Bluetooth talks to BlueZ over, and Location to
        // GeoClue; it has no releases.
        .package(url: "https://github.com/wendylabsinc/dbus.git", revision: "5727296ecaef9655b781f82c7ebde5c9f0d45551"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // SHA-256, for bundles' CodeResources; the D-Bus package uses it too.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // Model stores: CoreModel's SQLite backend, and the SQLite it's
        // over, which is compiled in on Linux. Both masters, until they're
        // released: they answer requests as CoreModel's in-memory evaluation
        // does (PureSwift/CoreModel-SQLite#14, PureSwift/CoreModel#41).
        .package(url: "https://github.com/PureSwift/CoreModel-SQLite.git", branch: "master"),
        .package(url: "https://github.com/PureSwift/CoreModel.git", branch: "master"),
        .package(url: "https://github.com/PureSwift/SQLite.git", from: "0.2.2"),
    ],
    targets: [

        // MARK: - Host runtime

        .target(
            name: "LinuxHost",
            dependencies: [runtime("CRuntime"), runtime("RuntimeCore"), runtime("RuntimeNative"), runtime("DynamicRuntime"), runtime("RuntimeABI"),
                           runtime("RuntimeHost"), runtime("DynamicFiles"), .product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: host
        ),

        // MARK: - SwiftUI player

        // DarwinAppRuntime's DarwinUI, copied by Scripts/sync-darwinui.sh,
        // over Cacao's SwiftUI.
        .target(
            name: "LinuxUI",
            dependencies: ["LinuxHost", "LinuxGraphics", "LinuxWebKit", runtime("DynamicUI"), runtime("DynamicRuntime"), runtime("RuntimeNative")] + swiftUI,
            exclude: ["DARWINUI_REVISION"],
            swiftSettings: host
        ),

        // MARK: - Bluetooth

        .target(
            name: "LinuxBluetooth",
            dependencies: [
                "LinuxHost", runtime("DynamicBluetooth"), runtime("RuntimeNative"),
                .product(name: "DBUS", package: "dbus"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: host
        ),

        // MARK: - Graphics

        // GL surfaces over EGL, loaded at run time: the host links no GL.
        .target(
            name: "LinuxGraphics",
            dependencies: ["LinuxHost", runtime("DynamicGraphics"), runtime("DynamicRuntime"), runtime("RuntimeABI")],
            swiftSettings: host
        ),

        // MARK: - Web views

        // WPE WebKit, loaded at run time: the host links no WebKit.
        .target(
            name: "LinuxWebKit",
            dependencies: ["LinuxHost", runtime("DynamicWebKit"), runtime("DynamicRuntime"), runtime("RuntimeABI")],
            swiftSettings: host
        ),

        // MARK: - Model stores

        // The guest's CoreModel, through the ModelStore contracts, to
        // CoreModel-SQLite.
        .target(
            name: "LinuxCoreModel",
            dependencies: [
                "LinuxHost", runtime("DynamicCoreModel"), runtime("RuntimeCoreModel"), runtime("DynamicFiles"), runtime("DynamicRuntime"),
                runtime("RuntimeABI"), runtime("RuntimeHost"),
                .product(name: "CoreModelSQLite", package: "CoreModel-SQLite"),
                .product(name: "SQLite", package: "SQLite"),
            ],
            swiftSettings: host
        ),

        // MARK: - Device

        // The machine: /etc, DMI, the device tree, and power and heat in
        // sysfs.
        .target(
            name: "LinuxDevice",
            dependencies: ["LinuxHost", runtime("DynamicDevice"), runtime("DynamicRuntime")],
            swiftSettings: host
        ),

        // MARK: - D-Bus

        // The system and session buses, for the modules that talk to
        // system services: calls, properties and signals, on the main loop.
        .target(
            name: "LinuxDBus",
            dependencies: [
                "LinuxHost",
                .product(name: "DBUS", package: "dbus"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: host
        ),

        // MARK: - Location

        // GeoClue 2 on the system bus.
        .target(
            name: "LinuxLocation",
            dependencies: ["LinuxHost", "LinuxDBus", runtime("DynamicLocation"), runtime("DynamicRuntime"), .product(name: "DBUS", package: "dbus")],
            swiftSettings: host
        ),

        // MARK: - App

        // What the runner's process supplies that libc may not
        // (arc4random_buf), and prctl, which Swift can't call.
        .target(name: "CLinuxHost"),
        .target(
            name: "LinuxHostApp",
            dependencies: ["LinuxHost", "LinuxUI", "LinuxBluetooth", "LinuxGraphics", "LinuxWebKit", "LinuxCoreModel", "LinuxDevice", "LinuxLocation", "CLinuxHost", runtime("CRuntime"), runtime("RuntimeFormatting"),
                           runtime("DynamicGraphics"), .product(name: "CacaoSDL", package: "Cacao")],
            swiftSettings: host
        ),
        .executableTarget(
            name: "LinuxAppHost",
            dependencies: ["LinuxHostApp"],
            exclude: ["exports.list"],
            swiftSettings: host,
            // The runner exports rt.h's functions for the app's libapp.so,
            // and the linker keeps them though nothing here calls them.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "--dynamic-list=\(Context.packageDirectory)/Sources/LinuxAppHost/exports.list"],
                             .when(platforms: [.linux])),
            ]
        ),

        // MARK: - Packager

        // The contract modules give `validate` the descriptors of what this
        // host implements: the player's from DynamicUI, so the packager
        // doesn't build Cacao.
        .target(
            name: "LinuxPackager",
            dependencies: ["LinuxHost", "LinuxBluetooth", "LinuxGraphics", "LinuxWebKit", "LinuxCoreModel", "LinuxDevice", "LinuxLocation", runtime("RuntimeFormatting"), runtime("DynamicUI"),
                           .product(name: "Crypto", package: "swift-crypto")]
        ),
        .executableTarget(
            name: "LinuxAppTool",
            dependencies: ["LinuxPackager", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),

        // MARK: - Tests

        .testTarget(name: "LinuxHostTests", dependencies: ["LinuxHost", runtime("DynamicFiles"), .product(name: "Crypto", package: "swift-crypto")],
                    swiftSettings: host),
        .testTarget(
            name: "LinuxUITests",
            dependencies: ["LinuxUI", runtime("DynamicUI"), runtime("DynamicRuntime"), .product(name: "Cacao", package: "Cacao")] + swiftUI,
            swiftSettings: host
        ),
        .testTarget(name: "LinuxBluetoothTests", dependencies: ["LinuxBluetooth"], swiftSettings: host),
        .testTarget(name: "LinuxGraphicsTests", dependencies: ["LinuxGraphics", runtime("DynamicGraphics")], swiftSettings: host),
        .testTarget(
            name: "LinuxCoreModelTests",
            dependencies: ["LinuxCoreModel", runtime("DynamicCoreModel"), runtime("RuntimeCoreModel"),
                           .product(name: "CoreModelSQLite", package: "CoreModel-SQLite")],
            swiftSettings: host
        ),
        .testTarget(name: "LinuxDeviceTests", dependencies: ["LinuxDevice", runtime("DynamicDevice")], swiftSettings: host),
        .testTarget(name: "LinuxDBusTests", dependencies: ["LinuxDBus", .product(name: "DBUS", package: "dbus")], swiftSettings: host),
        .testTarget(name: "LinuxLocationTests", dependencies: ["LinuxLocation", "LinuxDBus", runtime("DynamicLocation"), .product(name: "DBUS", package: "dbus")],
                    swiftSettings: host),
        .testTarget(name: "LinuxWebKitTests", dependencies: ["LinuxWebKit", runtime("DynamicWebKit")], swiftSettings: host),
        .testTarget(name: "LinuxPackagerTests", dependencies: ["LinuxPackager", "LinuxHostApp"]),
    ]
)
