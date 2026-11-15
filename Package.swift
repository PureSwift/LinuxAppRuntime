// swift-tools-version:6.4
import Foundation
import PackageDescription

/// The Linux host for AppRuntime apps (`Documentation/Plan.md`).
///
/// AppRuntime comes without its `GuestExports` trait: the app's library, a
/// sealed slice, defines `rt_dispatch` and `rt_finalize`, and the host's own
/// `DynamicRuntime` binds to the runtime directly.
///
/// The environment:
///
/// - `APPRUNTIME_PATH`: a local AppRuntime checkout instead of GitHub; `SDL_PATH`
///   likewise for PureSwift/SDL.
/// - `LINUXAPPRUNTIME_APP_LIBRARY`: an app's `libapp.a` (a `linux-arm64` or
///   `linux-x86_64` slice from `guest.py slice`), which `linux-app-host`
///   links. Without it, `linux-app-host` builds without an app and says so
///   when run.
let environment = ProcessInfo.processInfo.environment

let appRuntime: Package.Dependency = {
    if let path = environment["APPRUNTIME_PATH"] {
        return .package(name: "AppRuntime", path: path, traits: [])
    }
    return .package(url: "https://github.com/PureSwift/AppRuntime.git", branch: "master", traits: [])
}()

/// `SDL_PATH` points at a local PureSwift/SDL checkout instead of GitHub.
let sdl: Package.Dependency = {
    if let path = environment["SDL_PATH"] {
        return .package(name: "SDL", path: path)
    }
    return .package(url: "https://github.com/PureSwift/SDL.git", branch: "master")
}()

let appLibrary = environment["LINUXAPPRUNTIME_APP_LIBRARY"].flatMap { path in
    FileManager.default.fileExists(atPath: path) ? path : nil
}

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
        // For development on a Mac: the targets without SDL build there.
        .macOS(.v13),
    ],
    products: [
        .library(name: "LinuxHost", targets: ["LinuxHost"]),
        .library(name: "LinuxUI", targets: ["LinuxUI"]),
        .library(name: "LinuxSDL", targets: ["LinuxSDL"]),
        .library(name: "LinuxBluetooth", targets: ["LinuxBluetooth"]),
        .library(name: "LinuxHostApp", targets: ["LinuxHostApp"]),
        .executable(name: "linux-app-host", targets: ["LinuxAppHost"]),
        .executable(name: "linux-app", targets: ["LinuxAppTool"]),
    ],
    dependencies: [
        appRuntime,
        // SDL3 and SDL3_ttf, through PureSwift's SDL.
        sdl,
        // D-Bus, which Bluetooth talks to BlueZ over; it has no releases.
        .package(url: "https://github.com/wendylabsinc/dbus.git", revision: "5727296ecaef9655b781f82c7ebde5c9f0d45551"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // SHA-256, for bundles' CodeResources; the D-Bus package uses it too.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [

        // MARK: - Host runtime

        .target(
            name: "LinuxHost",
            dependencies: [runtime("CRuntime"), runtime("RuntimeCore"), runtime("RuntimeNative"), runtime("DynamicRuntime"), runtime("RuntimeABI"), runtime("RuntimeHost")],
            swiftSettings: host
        ),

        // MARK: - SwiftUI player

        .target(
            name: "LinuxUI",
            dependencies: ["LinuxHost", runtime("DynamicUI"), runtime("RuntimeNative")],
            swiftSettings: host
        ),
        .target(
            name: "LinuxSDL",
            dependencies: [
                "LinuxUI",
                .product(name: "SDL3Swift", package: "SDL"),
                .product(name: "CSDL3TTF", package: "SDL"),
            ],
            swiftSettings: host,
            // Also here: static Swift builds don't take the module map's
            // link directives.
            linkerSettings: [.linkedLibrary("SDL3"), .linkedLibrary("SDL3_ttf")]
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

        // MARK: - App

        // libc functions app slices need that older glibc lacks.
        .target(name: "CLinuxHost"),
        .target(
            name: "LinuxHostApp",
            dependencies: ["LinuxHost", "LinuxUI", "LinuxSDL", "LinuxBluetooth", "CLinuxHost", runtime("CRuntime")],
            swiftSettings: host
        ),
        .executableTarget(
            name: "LinuxAppHost",
            dependencies: ["LinuxHostApp"],
            swiftSettings: host + (appLibrary != nil ? [.define("APP_LINKED")] : []),
            linkerSettings: appLibrary.map { [.unsafeFlags([$0])] } ?? []
        ),

        // MARK: - Packager

        // The contract modules give `validate` the descriptors of what this
        // host implements; none of them needs SDL.
        .target(
            name: "LinuxPackager",
            dependencies: ["LinuxHost", "LinuxUI", "LinuxBluetooth", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .executableTarget(
            name: "LinuxAppTool",
            dependencies: ["LinuxPackager", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),

        // MARK: - Tests

        .testTarget(name: "LinuxHostTests", dependencies: ["LinuxHost"], swiftSettings: host),
        .testTarget(name: "LinuxUITests", dependencies: ["LinuxUI"], swiftSettings: host),
        .testTarget(name: "LinuxSDLTests", dependencies: ["LinuxSDL"], swiftSettings: host),
        .testTarget(name: "LinuxBluetoothTests", dependencies: ["LinuxBluetooth"], swiftSettings: host),
        .testTarget(name: "LinuxPackagerTests", dependencies: ["LinuxPackager", "LinuxHostApp"]),
    ]
)
