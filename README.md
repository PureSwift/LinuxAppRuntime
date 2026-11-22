# LinuxAppRuntime

The Linux host for [AppRuntime](https://github.com/PureSwift/AppRuntime)
apps. An AppRuntime app is guest code only: a universal bundle with
`App.wasm` and a `libapp.so` for each Linux target. This repository runs
one on Linux:

- the **runner**, `linux-app-host`: one program every app runs in, which
  loads the app's `libapp.so`; `main`, a main loop for timers and D-Bus,
  the runtime core behind `rt.h`, and the built-in contracts;
- the **SwiftUI player**: DarwinAppRuntime's renderer of the SwiftUI
  frontend's render IR, on [Cacao](https://github.com/PureSwift/Cacao),
  SwiftUI for Linux;
- **Bluetooth** LE central over BlueZ's D-Bus API;
- **GL surfaces**: OpenGL ES 2.0 in a SwiftUI view, over EGL;
- **web views**: WPE WebKit pages in a SwiftUI view;
- the **packager**, `linux-app`, which installs an app for the runner by
  copying files: its bundle thinned to this machine's `libapp.so`. Nothing
  is compiled or linked, so a device needs the runner and no toolchain.

**Status:** AppRuntime's `ExampleUI`, built as a `linux-arm64` slice, runs
in the player on Cacao, headless under SDL's offscreen driver, and the
player passes DarwinUI's own tests there. PortMaster ports don't build on
Cacao yet ([PortMaster.md](Documentation/PortMaster.md) §7). The Bluetooth
contracts are tested against a fake BlueZ and haven't run against real
hardware. The runner loads `ExampleUI`, `ExampleGL` and `ExampleModel`
from their bundles, and `linux-app` installs them for it. See the
[plan](Documentation/Plan.md) and the [packager](Documentation/Packager.md).

![ExampleUI on Linux](Documentation/ExampleUI.png)

`ExampleGL` draws its triangle in a `GLSurface` the same way, with Mesa's
llvmpipe:

![ExampleGL on Linux](Documentation/ExampleGL.png)

`ExampleWeb` shows a page in a `WebView` with WPE WebKit:

![ExampleWeb on Linux](Documentation/ExampleWeb.png)

`ExampleFiles` reads its welcome text from the bundle and lists the notes
in its `documents`:

![ExampleFiles on Linux](Documentation/ExampleFiles.png)

`ExampleModel` keeps to-do lists in a model store with CoreModel, kept in
SQLite. At its second launch it reads back what's there, here two to-dos
added to its database between launches:

![ExampleModel on Linux](Documentation/ExampleModel.png)

## Modules

| Module | |
|---|---|
| `LinuxHost` | `AppHost` (built-ins, modules, `rt_main`), `MainLoop` and its clock, the `Bundle` built-in, `LinuxFiles` and `LinuxDefaults`, the app's files and settings in XDG's directories or a container ([plan](Documentation/Plan.md) §9), over AppRuntime's shared `RuntimeHost` (`AppInfo`, compatibility checks, `HostModule`, `Permissions`, `Application`, `HostFiles`, `HostDefaults`) |
| `LinuxUI` | The SwiftUI player: DarwinAppRuntime's `DarwinUI`, copied by `Scripts/sync-darwinui.sh`, over Cacao's `SwiftUI` |
| `LinuxBluetooth` | `BluetoothCentral`, `BluetoothPeripheral`, `BluetoothService`, `BluetoothCharacteristic`, `BluetoothDescriptor` and `BluetoothAdvertisement` over BlueZ, through `LinuxDBus` |
| `LinuxGraphics` | `Surface`: GLES 2.0 drawn in EGL pbuffers, loaded at run time, and read back into the player's `GLSurface` view ([plan](Documentation/Plan.md) §7) |
| `LinuxWebKit` | `WebContent`: WPE WebKit pages, loaded at run time, drawn into shared memory and shown by the player's `WebView` view ([plan](Documentation/Plan.md) §8) |
| `LinuxCoreModel` | `LinuxModelStore`: the app's CoreModel stores in SQLite, through AppRuntime's `HostModelStore` and CoreModel-SQLite ([plan](Documentation/Plan.md) §9) |
| `LinuxDevice` | `Device`: the machine, its battery, power mode and heat, from `/etc`, DMI, the device tree and sysfs, and its orientation and proximity from iio-sensor-proxy ([plan](Documentation/Plan.md) §10) |
| `LinuxDBus` | `Bus`: the system and session buses for the modules that talk to system services, over PureSwift/DBus, with calls, properties and signals delivered on the main loop ([plan](Documentation/Plan.md) §11.1) |
| `LinuxLocation` | `LocationManager`: the device's location from GeoClue 2 on the system bus, which its agent authorizes by the app's desktop ID; no heading ([plan](Documentation/Plan.md) §11) |
| `LinuxDocuments` | `Documents`: AppRuntime's `HostDocuments` with the desktop portal's file chooser on the session bus, for opening, folders and saving, and bookmarks in the app's data ([plan](Documentation/Plan.md) §12) |
| `LinuxMotion` | Motion: the accelerometer, gyroscope, magnetometer and barometer from the kernel's IIO sensors in sysfs, device motion fused from them, and a pedometer and activity recognizer that are unavailable ([plan](Documentation/Plan.md) §13) |
| `LinuxHostApp`, `linux-app-host` | The app's `main`: the host, and Cacao's window and loop. It also registers AppRuntime's `RuntimeFormatting`, dates and numbers over Swift Foundation, and `RuntimeNetworking`, HTTP over `URLSession` and libcurl ([plan](Documentation/Plan.md) §3) |
| `LinuxPackager`, `linux-app` | The packager: validation, thinning a bundle to one target, the install tree, PortMaster ports |

## Building

Swift 6.4.2 (`.swift-version`) on Debian 13; SDL 3.4, Cairo, FreeType,
fontconfig and Wayland for Cacao; EGL and GLES 2.0, which GL surfaces load
at run time and apps that draw link (Mesa's draw without a GPU); and WPE
WebKit, which web views load at run time:

```sh
apt-get install cmake ninja-build git libcairo2-dev libfreetype-dev libfontconfig-dev \
    libwayland-dev wayland-protocols fonts-dejavu-core \
    libegl1 libegl-mesa0 libgles-dev libgl1-mesa-dri \
    libwpewebkit-2.0-1 libwpebackend-fdo-1.0-1 libwayland-server0
Scripts/build-sdl3.sh /usr -DCMAKE_INSTALL_LIBDIR=lib/$(uname -m)-linux-gnu
swift build
swift test
```

Debian's SDL is 3.2, and PureSwift/SDL needs 3.4, so `build-sdl3.sh`
builds it. Ubuntu 26.04 doesn't package WPE WebKit. In a container, WebKit's
web processes need `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`: its
bubblewrap sandbox can't make namespaces there.

The `Dockerfile` has all of it; `Scripts/docker.sh` runs a command there,
with this checkout at `/src`:

```sh
Scripts/docker.sh swift test --scratch-path .build/linux
```

AppRuntime and Cacao (its `develop` branch) come from GitHub.
`APPRUNTIME_PATH` and `CACAO_PATH` point at local checkouts instead, and
`Scripts/docker.sh` mounts them.
`Scripts/sync-darwinui.sh` updates the player from a DarwinAppRuntime
checkout beside this one.

## Packaging an app

Build a universal bundle with a Linux slice with AppRuntime's `guest.py`
(the bundle step also needs the wasm Swift SDK):

```sh
python3 ~/Developer/AppRuntime/Scripts/guest.py bundle --product ExampleUI \
    --id org.pureswift.ExampleUI --name ExampleUI --version 1.0 --build 1 \
    --target linux-arm64 --output .build/guest
```

Then, on Linux, build the runner once:

```sh
swift build --product linux-app-host --product linux-app
.build/debug/linux-app-host .build/guest/org.pureswift.ExampleUI.app
```

and install apps for it:

```sh
.build/debug/linux-app validate .build/guest/org.pureswift.ExampleUI.app
.build/debug/linux-app install .build/guest/org.pureswift.ExampleUI.app --runner .build/debug/linux-app-host
.build/debug/linux-app-host org.pureswift.ExampleUI
```

`install` copies the bundle, thinned to `Info.plist`, `resources/`, the
icon, its signature and this machine's `libapp.so`, to
`~/.local/lib/linux-app/<id>.app`, and writes a desktop entry that starts
the runner with the app's identifier. `package` writes the same tree
elsewhere for a distribution's package, and `--archive` a tarball of it;
`run` checks a bundle and runs it as it is. The runner takes:

| Argument | |
|---|---|
| `App.app` or `--bundle App.app` | A bundle |
| An identifier | An installed app, found in `~/.local`, the runner's prefix, `/usr/local` or `/usr` (`LINUXAPPRUNTIME_PREFIXES`) |
| `--open URL`, or a URL after the app | A URL for the app to open |

It checks the app's ABI and contracts at every launch, and its `libapp.so`
against the bundle's `CodeResources` before loading it.

`Scripts/run-app.sh` runs a bundle in the runner in Docker, headless,
saving its first frame:

```sh
mkdir -p .build/shots
Scripts/run-app.sh .build/guest/org.pureswift.ExampleUI.app .build/shots/ExampleUI.png
```

## PortMaster

`linux-app portmaster` makes a [PortMaster](https://portmaster.games) port
for aarch64 and armhf handhelds: the runner built for their older glibc
and named after the app, the bundle thinned to its `libapp.so` for each
architecture, SDL3 built for them, a launcher, gamepad controls and the
catalogue's metadata
([design](Documentation/PortMaster.md)). Ports don't build on Cacao yet:
their images need Cairo built for old glibc, and Cacao needs the handheld
options the earlier player had (§7 there). In Docker:

```sh
Scripts/portmaster.sh build .build/guest/org.pureswift.ExampleUI.app all --porter "Your Name"
Scripts/portmaster.sh test aarch64
```

The bundle needs `linux-arm64` and `linux-armv7` slices (`guest.py bundle
--target linux-arm64 --target linux-armv7`). Ports go to
`.build/portmaster/<port>/`, laid out as in PortMaster's repository, and
`<port>.zip`.

| Variable | |
|---|---|
| `LINUXAPPRUNTIME_DEBUG` | `1` logs the host's debug messages |
| `LINUXAPPRUNTIME_CONTAINER` | An absolute path that holds the app's files (`Documents`, `Data`, `Caches`, `tmp`) settings (`Defaults`), model stores (`Stores`) and bookmarks (`Bookmarks`), in place of XDG's directories |
| `CACAO_SCREENSHOT` | Saves the first frame to a PNG and quits |
| `CACAO_SHOW_STATISTICS` | `1` shows Cacao's frame times |
| `SDL_VIDEO_DRIVER` | `wayland`, `x11`, `kmsdrm`, or `offscreen` for no display |
