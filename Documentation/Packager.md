# Packager — Design

**Status:** implemented, except Flatpak, AppImage and cross-building (§5).
`ExampleUI` packages from its bundle with either engine, and the packaged
app runs.

`linux-app` turns a universal bundle into a Linux app: phase 2 of the
[plan](Plan.md). It never compiles guest Swift. The bundle already has the
guest's code, as a sealed `libapp.a` per target and `App.wasm`, and its
`Info.plist` has the portable keys AppRuntime's manifest stage wrote
(DarwinAppRuntime's `ManifestPackager.md` §1).

```sh
linux-app validate App.app [--target linux-arm64]
linux-app package  App.app [--target …] [--engine slice|wasm2c] [--output DIR] [--archive]
linux-app install  App.app [--prefix ~/.local]
linux-app run      App.app [-- host arguments]
```

## 1. Validation

`validate`, and every other command first, checks the bundle against this
host:

| Check | Failure |
|---|---|
| `Info.plist` has the RT keys, a reverse-DNS `CFBundleIdentifier` and a single-component `CFBundleExecutable` | error |
| `RTABIVersion` ≤ the host's | error |
| Each `RTContracts` entry is implemented here, as the same kind | error; `--allow-missing-contracts` makes it a warning, and the guest sees the contract as absent |
| … at the same version or later | warning: methods added later resolve as absent |
| `_CodeSignature/CodeResources` matches every file's SHA-256 | error: a corrupt or tampered bundle |
| The engine's input: `lib/<target>/libapp.a` for `slice`, `wasm32/App.wasm` for `wasm2c` | error |
| The slice is an archive of ELF objects for the target's machine | error |
| A declared capability this host has no contract for (location, motion, NFC, …) | warning |

## 2. Targets and engines

The target is the build machine's (`linux-arm64` on aarch64, `linux-x86_64`
on x86_64); cross-building waits on Swift SDKs for Linux targets.

- **`slice`** (the default when the bundle has one) links the bundle's
  `lib/<target>/libapp.a`.
- **`wasm2c`** (the default otherwise) runs AppRuntime's
  `Scripts/wasm2c-shim.py build` on `App.wasm`, which needs WABT (`apt
  install wabt`) and clang, and links its `libapp.a` the same way.
  Ubuntu's `wabt` 1.0.36 leaves out two files its runtime source includes
  (`wasm-rt-impl-tableops.inc`, `wasm-rt-mem-impl-helper.inc`); the
  `Dockerfile` adds them from the same release. The
  AppRuntime checkout comes from `--appruntime`, `APPRUNTIME_PATH`, or the
  one SwiftPM resolved for the host build.

## 3. Building the host

As on Darwin, the host is built per app from a generated SwiftPM package in
the work directory (`.build/linux-app/<identifier>/<target>`, reused
between builds):

```
Package.swift   an executable product, LinuxAppMain, depending on this
                package's LinuxHostApp, linking the app's libapp.a; the
                tree names its copy CFBundleExecutable
Sources/<Executable>/main.swift
                HostApp.main(AppEntryPoints(main: rt_main, …))
```

`swift build -c release` (or `--configuration debug`) builds it. The app's library is copied in as `lib/libapp-<hash>.a`: SwiftPM
doesn't relink when a library named in linker flags changes, but a new name
changes the manifest. This
package is found from `--host-package`, `LINUXAPPRUNTIME_PATH`, or the
source tree `linux-app` was built from.

## 4. The app

`package` writes an install tree under `--output` (default
`.build/linux-app/<identifier>/<target>/out`):

```
bin/<executable>                                  → ../lib/<identifier>/<executable>
lib/<identifier>/<executable>                     the host, linked with the app
lib/<identifier>/App.app/Info.plist               the bundle, without lib/ and wasm32/
lib/<identifier>/App.app/resources/…
share/applications/<identifier>.desktop
share/icons/hicolor/256x256/apps/<identifier>.png from the bundle's icon.png
```

The host finds `App.app` next to its executable, through the `bin/`
symlink. `--archive` also writes `<identifier>-<version>-<target>.tar.gz`
of the tree.

The desktop entry names the app (`CFBundleName`), runs it (`Exec`, with
`%u` so URLs reach `Application.open`), and matches its windows: the host
sets SDL's app metadata, so the window's Wayland app ID and X11 class are
the identifier, which `StartupWMClass` repeats.

`install` packages and copies the tree into `--prefix` (`~/.local` by
default), with `Exec` an absolute path, and refreshes the desktop database
when `update-desktop-database` is there. `run` packages a debug build into
the work directory and runs it.

## 5. Later

- **Flatpak and AppImage.** A Flatpak manifest carries the capabilities as
  sandbox permissions (`bluetooth` → `--system-talk-name=org.bluez`,
  `network` → `--share=network`).
- **Localized names** in the desktop entry, from the bundle's
  `<language>.lproj` tables.
- **Cross-building** for another architecture with a Swift SDK.
