# Linux host — Plan

**Status:** phases 1 and 2 are implemented; the packager has its own
design, [Packager.md](Packager.md), and so do PortMaster ports,
[PortMaster.md](PortMaster.md). Differences from the design below:

- **The player** is DarwinAppRuntime's SwiftUI renderer on
  [Cacao](https://github.com/PureSwift/Cacao) (§5), in place of the player
  this plan first had, which laid out and drew the IR with SDL itself.
- **PortMaster ports** don't build on Cacao yet: they need Cairo built for
  their glibc, and Cacao options for fullscreen, scale and a drawn pointer
  ([PortMaster.md](PortMaster.md) §7).
- **Bluetooth** is tested against a fake bus that plays BlueZ's objects and
  signals; it hasn't run against `bluetoothd` and a device.
- **AppRuntime's `guest.py bundle`** needed one fix to run on Linux: it
  reads the contracts section with Embedded concurrency, which Linux
  toolchains ship only for their own triple. The bundle step still needs the
  wasm Swift SDK, so bundles are built on a Mac for now.

The Linux host for [AppRuntime](https://github.com/PureSwift/AppRuntime)
apps, the counterpart of DarwinAppRuntime. An AppRuntime app is guest code
only: a universal bundle with `App.wasm` and native `libapp.a` slices
(`linux-arm64`, `linux-x86_64`, `linux-armv7`). This repository turns one
into a Linux program:

- the **host runtime**: `main`, the event loop, the runtime core behind
  `rt.h`, and the contract implementations over Linux services;
- the **SwiftUI player**: DarwinAppRuntime's renderer of the SwiftUI
  frontend's render IR, on Cacao's SwiftUI for Linux;
- **Bluetooth** over BlueZ's D-Bus API;
- the **packager**, `linux-app` ([Packager.md](Packager.md)).

References like §7.6 are to `Documentation/DynamicRuntime.md` in AppRuntime;
the render IR is `Documentation/RenderIR.md` there. Perry
(MillerTechnologyPeru/Perry) runs iOS binaries on Linux and already talks to
BlueZ; this host reuses its approach (BlueZ through `wendylabsinc/dbus`), not
its code, since Perry implements Apple's ABI and this host implements
AppRuntime's contracts.

## 1. Scope

| In | Later |
|---|---|
| arm64 and x86_64 Linux with glibc (Debian 13, Ubuntu 24.04+) | armv7, musl |
| Native slices linked into the host | wasm2c (AppRuntime's shim, as on Darwin); WasmKit for development |
| Wayland and X11 through SDL3; a headless driver for tests | Multiple windows |
| `Renderer`, Bluetooth `Central` and friends, the built-ins | Location (GeoClue), Device (UPower, sysfs), Networking (libcurl), Formatting (ICU), Motion (iio-sensor-proxy), NFC (neard) |

## 2. Process model

```
┌────────────────────── app (one executable) ──────────────────────┐
│ LinuxHostApp main                                                │
│   ├── runtime core: RuntimeCore + RuntimeNative (rt_* symbols)   │
│   ├── MainLoop: timers, jobs from other threads                  │
│   ├── LinuxBluetooth: BlueZ over D-Bus (NIO threads → MainLoop)  │
│   ├── LinuxUI: DarwinUI, render IR → SwiftUI views → events      │
│   │     └── Cacao: SwiftUI, Silica/Cairo, SDL3 windows and input │
│   └── libapp.a: the app's sealed linux-arm64 / linux-x86_64 slice│
└──────────────────────────────────────────────────────────────────┘
```

Everything that calls the guest runs on the main thread (§6.4). Work on
other threads (D-Bus, later networking) posts its results to the
`MainLoop`.

### 2.1 The main loop

`MainLoop` owns the main thread:

1. run timers that are due (the `Clock` built-in schedules on them);
2. run jobs posted from other threads;
3. wait until the next timer or a posted job.

A `MainLoopDriver` does the waiting; the default one waits on a semaphore.
With a window, Cacao's SDL loop owns the main thread instead and drains the
main dispatch queue every turn, at least every 16 ms: the `MainLoop` then
runs on that queue (`runsOnMainQueue`), its jobs and timers dispatched to it.
`MainLoopClock` is the `HostClock`: `CLOCK_MONOTONIC` for `now`, the loop's
timers for `schedule`.

## 3. Modules

| Module | Contents |
|---|---|
| `LinuxHost` | `AppHost` (built-ins, modules, `rt_main`), `MainLoop`, `MainLoopClock`, the `Bundle` built-in; over AppRuntime's `RuntimeHost`, which every host shares: `AppInfo` (the bundle's `Info.plist` keys), the compatibility checks, `HostModule`, and the `Permissions` and `Application` built-ins |
| `LinuxUI` | The SwiftUI player: DarwinAppRuntime's `DarwinUI`, copied by `Scripts/sync-darwinui.sh`, over Cacao's `SwiftUI` and `Combine` modules; `Host.swift` gives it the logger and bundle it takes from its host |
| `LinuxBluetooth` | `Central`, `Peripheral`, `Service`, `Characteristic`, `Descriptor`, `Advertisement` over BlueZ |
| `LinuxHostApp` | `main`: reads the app's keys, starts the host, and runs Cacao's SDL loop with one window showing the guest's first renderer |
| `LinuxPackager`, `linux-app` | The packager (§8, [Packager.md](Packager.md)) |

The package depends on AppRuntime without its `GuestExports` trait, like
DarwinAppRuntime, so the slice's `rt_dispatch` and `rt_finalize` are the
only ones linked (`HostRuntime.md` §8 in DarwinAppRuntime).

## 4. Startup

1. Read the app's keys (`RTABIVersion`, `RTContracts`, `RTCapabilities`,
   `CFBundleIdentifier`, version and build) from the universal bundle's
   `Info.plist`: the path from `--bundle`, or `App.app` next to the
   executable.
2. Check the ABI and contract versions (§7.6); refuse a newer ABI or a
   contract this host lacks.
3. `NativeRuntime.shared.bindDirectly()`; set capabilities; set the clock.
4. Register the built-ins (`Permissions`, `Bundle`, `Application`) and each
   module the app uses (`LinuxUI` for `Renderer`, `LinuxBluetooth`).
5. Call `rt_main`. When the guest calls `Renderer.make`, the player adds
   its scene; the first tree is there before `rt_main` returns.
6. Run Cacao's loop until the window closes, the window showing the first
   scene (or, for an app with no renderer, the `MainLoop` until it's
   interrupted).

## 5. The SwiftUI player

The player is DarwinAppRuntime's: `DarwinUI`, its renderer of the render IR
into SwiftUI views (DarwinAppRuntime's `SwiftUIRenderer.md`), on
[Cacao](https://github.com/PureSwift/Cacao), which implements SwiftUI for
Linux: evaluation, layout, controls, navigation and presentations, drawn
with Silica over Cairo and shown with SDL3 through PureSwift/SDL. Apple and
Linux hosts then share one player.

- **Its sources** are copied from DarwinAppRuntime by
  `Scripts/sync-darwinui.sh`, unchanged but for `import DarwinHost` (here
  `LinuxHost`) and its `#if os(macOS)` code, which is for any platform but
  iOS. `Sources/LinuxUI/DARWINUI_REVISION` records the commit. On Linux,
  `import SwiftUI` and `import Combine` are Cacao's modules of those names,
  as in Cacao's own `Compatibility/DarwinUI`.
- **Its tests** come along: DarwinUI's own, and Cacao's version of its
  rendering test, which hosts `RendererView` in a Cacao view graph. One is
  disabled on Linux: Swift Testing's main-actor tests don't run on the
  thread `Thread.isMainThread` knows, so a renderer released in one removes
  its scene a turn later.
- **The window** is Cacao's: the host app is a Cacao `App` whose window
  shows the first scene in `RendererScenes`, as the Darwin host's does.
  `CACAO_SCREENSHOT=path.png` saves the first frame and quits.

## 6. Bluetooth over BlueZ

One process-wide `BlueZHub` holds a D-Bus connection to the system bus
(`wendylabsinc/dbus`, as Perry uses), a copy of BlueZ's objects from
`GetManagedObjects` kept current by `InterfacesAdded`, `InterfacesRemoved`
and `PropertiesChanged`, and one wrapper object per BlueZ path. D-Bus
replies and signals are posted to the `MainLoop`, so the guest is only
called on the main thread. `BlueZBus` abstracts the connection, so the
contract logic is tested with a fake bus.

| Contract | BlueZ |
|---|---|
| `authorizationStatus`, `requestAuthorization` | `allowed`: Linux has no per-app prompt; the sandbox's `bluetooth` capability and `rt_class` gate access |
| `state` | No BlueZ or no adapter: `unsupported`; access denied on the bus: `unauthorized`; `Adapter1.Powered`: `poweredOn` / `poweredOff` |
| `scan` | `SetDiscoveryFilter({Transport: le, UUIDs, DuplicateData})`, `StartDiscovery`; a device is reported when it appears or its `RSSI`, `ManufacturerData` or `ServiceData` changes, once per scan unless duplicates are allowed; services filtered on the host too, since cached devices skip BlueZ's filter |
| `connect` | `Device1.Connect`; `didConnect` once `Connected` and `ServicesResolved`; the timeout is a main-loop timer that disconnects |
| `cancelConnection` | `Device1.Disconnect`, `didDisconnect` with `0` |
| `retrievePeripherals` | Devices by address (`Peripheral.identifier`) |
| `retrieveConnectedPeripherals` | Connected devices with any of the services in `UUIDs` |
| `discoverServices`, `discoverCharacteristics`, `discoverDescriptors` | BlueZ resolves the database on connection: the `GattService1`, `GattCharacteristic1` and `GattDescriptor1` objects under the device |
| `readValue`, `writeValue` | `ReadValue({})`, `WriteValue(value, {type: request / command})` |
| `setNotifyValue` | `StartNotify` / `StopNotify`; values arrive as `PropertiesChanged` of `Value` |
| `readRSSI` | `Device1.RSSI` (BlueZ reports it while discovering) |
| `maximumWriteLength` | `GattCharacteristic1.MTU` − 3 without response, 512 with |
| `Advertisement` | `Name`, `ManufacturerData` (company ID first, little-endian), `UUIDs`, `ServiceData`, `TxPower` |

GATT operations are queued per peripheral, and every call gets exactly one
callback; a disconnect fails what's queued with `notConnected`. BlueZ
errors map to `BluetoothError` (`org.bluez.Error.NotConnected` →
`notConnected`, `NotPermitted` / `NotAuthorized` → `insufficientAuthentication`,
`NotSupported` → `operationNotSupported`, `InProgress` / `Failed` with a
connection → `connectionFailed`, …); anything else is `unknown`, and logged.

## 7. Testing

- `LinuxUI`: DarwinUI's tests, on Cacao (§5).
- `LinuxBluetooth`: the contract against a fake `BlueZBus` that plays
  BlueZ's objects and signals. Runs on macOS and Linux.
- End to end: AppRuntime's `ExampleUI` built as a `linux-arm64` slice,
  linked into `linux-app-host` and run headless with SDL's `offscreen`
  driver, its first frame saved with `CACAO_SCREENSHOT`.
- Real BlueZ needs hardware: manual runs on a Raspberry Pi or a laptop with
  `bluetoothd`.

## 8. Phases

1. **Host runtime and player**: `LinuxHost`, `LinuxUI`, `LinuxBluetooth`,
   `LinuxHostApp`; `ExampleUI` runs in Docker.
2. **Packager**: `linux-app` builds the host for a target triple, links the
   bundle's slice (or wasm2c output), and writes an installable directory:
   the executable, `Info.plist`, resources, a `.desktop` file and icon;
   later Flatpak and AppImage, whose manifests carry the capabilities
   (`--system-talk-name=org.bluez` for `bluetooth`).
3. **More contracts**: Location (GeoClue2), Device (UPower, sysfs),
   Networking (libcurl or AsyncHTTPClient), Formatting (ICU), Motion
   (iio-sensor-proxy), NFC (neard).
4. **Player**: what DarwinUI and Cacao add: Cacao's AT-SPI bridge, input
   replay for end-to-end tests.

## 9. Open questions

- **Permissions.** Desktop Linux has no prompts for Bluetooth; Flatpak's
  portals cover location and the camera. `Permissions.request` answers from
  the sandbox's declared capabilities until portals are used.
