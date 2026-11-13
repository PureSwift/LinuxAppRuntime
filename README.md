# LinuxAppRuntime

The Linux host for [AppRuntime](https://github.com/PureSwift/AppRuntime)
apps. An AppRuntime app is guest code only: a universal bundle with
`App.wasm` and native `libapp.a` slices. This repository turns one into a
Linux program:

- the **host runtime**: `main`, a main loop that SDL, timers and D-Bus all
  wake, the runtime core behind `rt.h`, and the built-in contracts;
- the **SwiftUI player**, which lays out and draws the SwiftUI frontend's
  render IR with SDL3 and SDL3_ttf, and sends input back;
- **Bluetooth** LE central over BlueZ's D-Bus API.

**Status:** AppRuntime's `ExampleUI`, built as a `linux-arm64` slice, runs
in the player: text fields, steppers, pickers, alerts, menus, swipe actions
(as context menus), search, navigation, forms, disclosure groups,
confirmation dialogs, sheets, tab views and lazy grids all render and reach
the guest and back, headless under SDL's offscreen driver. The Bluetooth
contracts are tested against a fake BlueZ and haven't run against real
hardware. The packager is next. See the [plan](Documentation/Plan.md).

![ExampleUI on Linux](Documentation/ExampleUI.png)

## Modules

| Module | |
|---|---|
| `LinuxHost` | `AppHost` (checks, built-ins, modules, `rt_main`), `AppInfo`, `MainLoop` and its clock, `Permissions`, `Bundle`, `Application` |
| `LinuxUI` | The player's model without SDL: render store, layout, drawing to a `Canvas`, input, text editing, lazy rows, navigation, presentations |
| `LinuxSDL` | The window, `SDL_Renderer` canvas, SDL3_ttf text with fontconfig's fonts, and SDL as the main loop's driver |
| `LinuxBluetooth` | `Central`, `Peripheral`, `Service`, `Characteristic`, `Descriptor` and `Advertisement` over BlueZ, through `wendylabsinc/dbus` |
| `LinuxHostApp`, `linux-app-host` | The app's `main` |

## Building

Swift 6.4.2 (`.swift-version`), SDL3, SDL3_ttf and fontconfig:

```sh
apt-get install libsdl3-dev libsdl3-ttf-dev libfontconfig-dev fonts-dejavu-core
swift build
swift test
```

The `Dockerfile` has all of it; `Scripts/docker.sh` runs a command there,
with this checkout at `/src`:

```sh
Scripts/docker.sh swift test --scratch-path .build/linux
```

AppRuntime comes from GitHub. `APPRUNTIME_PATH` points at a local checkout
instead.

## Running an app

Build a universal bundle with a Linux slice with AppRuntime's `guest.py`
(the bundle step also needs the wasm Swift SDK), then link its slice into
`linux-app-host`:

```sh
python3 ~/Developer/AppRuntime/Scripts/guest.py bundle --product ExampleUI \
    --id org.pureswift.ExampleUI --name ExampleUI --version 1.0 --build 1 \
    --target linux-arm64 --output .build/guest
LINUXAPPRUNTIME_APP_LIBRARY=$PWD/.build/guest/org.pureswift.ExampleUI.app/lib/linux-arm64/libapp.a \
    swift build --product linux-app-host
.build/debug/linux-app-host --bundle .build/guest/org.pureswift.ExampleUI.app
```

`Scripts/run-app.sh` does the last two steps in Docker, headless; with
`--script`, it replays input and takes screenshots:

```sh
mkdir -p .build/shots
Scripts/run-app.sh .build/guest/org.pureswift.ExampleUI.app --script /src/Scripts/ExampleUI.script
```

| Variable | |
|---|---|
| `LINUXAPPRUNTIME_WINDOW_SIZE` | The window's size in points, `WIDTHxHEIGHT`; 420x760 by default |
| `LINUXAPPRUNTIME_APPEARANCE` | `light` or `dark`; the system's by default |
| `LINUXAPPRUNTIME_DEBUG` | `1` logs the host's debug messages |
| `SDL_VIDEO_DRIVER` | `wayland`, `x11`, or `offscreen` for no display |
