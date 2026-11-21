# Packager — Design

**Status:** implemented, except Flatpak and AppImage (§5). `ExampleUI`,
`ExampleGL` and `ExampleModel` install from their bundles and run in the
runner.

`linux-app` installs a universal bundle's app for the runner,
`linux-app-host` ([Plan.md](Plan.md) §4): phase 2 of the plan. It never
compiles or links anything. The bundle has the guest's code, as a
`libapp.so` per Linux target, which `guest.py` linked when it built the
bundle (AppRuntime's `DynamicRuntime.md` §7.5), and its `Info.plist` has
the portable keys AppRuntime's manifest stage wrote (DarwinAppRuntime's
`ManifestPackager.md` §1). So a device needs the runner, and no compiler,
linker or SwiftPM; the runner and the OS update on their own, and the app's
ABI is what stays put.

```sh
linux-app validate App.app [--target linux-arm64]
linux-app package  App.app [--target …] [--output DIR] [--archive]
linux-app install  App.app [--prefix ~/.local] [--runner PATH]
linux-app run      App.app [--runner PATH] [-- URL]
```

## 1. Validation

`validate`, and every other command first, checks the bundle against this
host. The runner checks the ABI, the contracts and the library's signature
again at every launch, since it may have changed since.

| Check | Failure |
|---|---|
| `Info.plist` has the RT keys, a reverse-DNS `CFBundleIdentifier` and a single-component `CFBundleExecutable` | error |
| `RTABIVersion` ≤ the host's | error |
| Each `RTContracts` entry is implemented here, as the same kind | error; `--allow-missing-contracts` makes it a warning, and the guest sees the contract as absent |
| … at the same version or later | warning: methods added later resolve as absent |
| The bundle has `_CodeSignature/CodeResources`, and it matches every file's SHA-256 | error: the runner loads no library its bundle doesn't vouch for |
| `lib/<target>/libapp.so` is there, and is a shared library for the target's machine and word size | error |
| A declared capability this host has no contract for (motion, NFC, …) | warning |

`guest.py` has checked the rest of the library when it built it: that it
names no other library, binds as it loads, exports the three guest exports
only, and leaves undefined only what a runner supplies.

## 2. Targets

The target is this machine's (`linux-arm64` on aarch64, `linux-x86_64` on
x86_64, `linux-armv7` on armv7l), or `--target`'s. A bundle carries a
`libapp.so` for each target it was built for.

There's no wasm2c engine: it needs a C compiler, which a device doesn't
have. A bundle without a slice for a target gets one where there's a
toolchain, before it's installed: AppRuntime's
`Scripts/wasm2c-shim.py slice --bundle App.app --target linux-arm64` makes
`lib/linux-arm64/libapp.so` from `wasm32/App.wasm` and re-signs the bundle,
and the runner loads it like a native slice. Running `App.wasm` itself is
for an engine in the runner.

## 3. The runner

Apps don't get a program of their own: every app runs in `linux-app-host`,
installed once (Plan.md §4). `install` and `run` find it from `--runner`,
`LINUXAPPRUNTIME_RUNNER`, beside `linux-app`, or on `PATH`.

A PortMaster port is the exception: a handheld has no runner installed, so
the port carries one, built by `linux-app portmaster` for the handheld's
glibc ([PortMaster.md](PortMaster.md)). It's the same program for every
app.

## 4. The app

`install` writes the app into `--prefix` (`~/.local` by default):

```
lib/linux-app/<identifier>.app/Info.plist          the bundle, thinned:
lib/linux-app/<identifier>.app/resources/…
lib/linux-app/<identifier>.app/icon.png
lib/linux-app/<identifier>.app/_CodeSignature/CodeResources
lib/linux-app/<identifier>.app/lib/<target>/libapp.so   this target's only
share/applications/<identifier>.desktop
share/icons/hicolor/256x256/apps/<identifier>.png  from the bundle's icon.png
```

Thinning drops the other targets' libraries and `App.wasm`.
The signature is kept as it was: every file still in the bundle matches it,
and the runner checks the library against it. The new copy is written
beside the old one and replaces it whole.

The desktop entry names the app (`CFBundleName`), runs it
(`Exec=<runner> <identifier> %u`, the runner by its absolute path, with
`%u` so URLs reach `Application.open`, and files `Documents`), says what
it opens (`MimeType=`, the MIME types of the bundle's `RTDocumentTypes`;
groups such as `image/*` and extensions can't be said there), and matches
its windows: the host
sets SDL's app metadata, so the window's Wayland app ID and X11 class are
the identifier, which `StartupWMClass` repeats. `install` refreshes the
desktop database when `update-desktop-database` is there.

`package` writes the same tree to `--output` (default
`.build/linux-app/<identifier>/<target>`) for a distribution's package,
with the runner named by `Exec` from `PATH`, and `--archive` also writes
`<identifier>-<version>-<target>.tar.gz` of it. `run` checks the bundle and
runs it in the runner as it is.

## 5. Later

- **Flatpak and AppImage.** A Flatpak manifest carries the capabilities as
  sandbox permissions (`bluetooth` → `--system-talk-name=org.bluez`,
  `location` → `--system-talk-name=org.freedesktop.GeoClue2`, `network` →
  `--share=network`).
- **A read-only image** per app (squashfs), as AppRuntime's launcher
  mounts them (§7.8 there).
