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
- **GL surfaces**, OpenGL ES 2.0 over EGL, in the player's views;
- **web views**, WPE WebKit pages in the player's views;
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
| `Renderer`, Bluetooth `Central` and friends, GL surfaces, web views, files, settings, the built-ins | Location (GeoClue), Device (UPower, sysfs), Networking (libcurl), Formatting (ICU), Motion (iio-sensor-proxy), NFC (neard) |

## 2. Process model

```
┌────────────────────── app (one executable) ──────────────────────┐
│ LinuxHostApp main                                                │
│   ├── runtime core: RuntimeCore + RuntimeNative (rt_* symbols)   │
│   ├── MainLoop: timers, jobs from other threads                  │
│   ├── LinuxBluetooth: BlueZ over D-Bus (NIO threads → MainLoop)  │
│   ├── LinuxGraphics: GL surfaces, EGL pbuffers read back         │
│   ├── LinuxWebKit: WPE WebKit pages, frames in shared memory     │
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
| `LinuxHost` | `AppHost` (built-ins, modules, `rt_main`), `MainLoop`, `MainLoopClock`, the `Bundle` built-in, and `LinuxFiles` and `LinuxDefaults` (§9); over AppRuntime's `RuntimeHost`, which every host shares: `AppInfo` (the bundle's `Info.plist` keys), the compatibility checks, `HostModule`, the `Permissions` and `Application` built-ins, `HostFiles` and `HostDefaults` |
| `LinuxUI` | The SwiftUI player: DarwinAppRuntime's `DarwinUI`, copied by `Scripts/sync-darwinui.sh`, over Cacao's `SwiftUI` and `Combine` modules; `Host.swift` gives it the logger and bundle it takes from its host |
| `LinuxBluetooth` | `Central`, `Peripheral`, `Service`, `Characteristic`, `Descriptor`, `Advertisement` over BlueZ |
| `LinuxGraphics` | `Surface` over EGL and GLES 2.0, loaded at run time; the player's `GLSurface` view shows it (§7) |
| `LinuxWebKit` | `WebContent` over WPE WebKit, loaded at run time; the player's `WebView` view shows it (§8) |
| `LinuxHostApp` | `main`: reads the app's keys, starts the host, and runs Cacao's SDL loop with one window showing the guest's first renderer |
| `LinuxPackager`, `linux-app` | The packager (§11, [Packager.md](Packager.md)) |

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
   module the app uses (`LinuxUI` for `Renderer`, `LinuxBluetooth`,
   `LinuxGraphics`, `LinuxWebKit`).
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

## 7. GL surfaces

`LinuxGraphics` implements `Surface` (AppRuntime's `Graphics.md`), and the
player draws `GLSurface` nodes. Cacao composites the window itself, from
Cairo drawings and images, so a surface is drawn offscreen and shown as an
image:

- **No GL at build time.** The host opens `libEGL.so.1` and
  `libGLESv2.so.2` when it starts; without them `graphics` is
  unavailable. An app that declares `graphics` has `libGLESv2` linked in by
  the packager, for its own `gl*` calls, which are the same library's.
- **One context for the app**, GLES 2.0, on Mesa's surfaceless platform
  where there is one, otherwise the driver's default display. Each surface
  on screen has a pbuffer of its size in pixels, the default framebuffer
  the guest draws in. Sharing the context keeps the wasm2c shim's buffer
  bindings right from one surface to the next; `rt_gl_context_generation`
  changes when the context is replaced.
- **Frames**: a timer on the main loop, about 60 times a second while a
  surface is on screen, makes the context current on its pbuffer, calls
  `frame`, and reads the pixels back, rows flipped and alpha
  premultiplied, into Cacao's `Image(pixels:)`. Moves since the last frame
  go first, one per pointer. If the context is lost, every surface hears
  `contextLost`, then `contextRestored` with a new one.
- **The view** (`Sources/LinuxUI/HostGLSurface.swift`, which
  `sync-darwinui.sh` keeps, hooked into NodeView's unknown types) attaches
  the surface when it appears, with its size in pixels and `resize` before
  the first frame, and detaches it when it goes, which cancels pointers in
  contact and takes focus. A drag is the mouse, pointer 0, with the primary
  button, and hovering moves it; a click focuses the surface, and keys go
  to it as USB HID usage IDs from Cacao's key characters, a US layout's
  positions.
- **Not yet**: pointer capture (`setPointerCaptured` returns `false`),
  scrolling, touches as touches, other mouse buttons, and pausing while the
  window is in the background. Reading back each frame costs a copy; a GL
  backend for Cacao's compositor could show the pbuffer as a texture.

## 8. Web views

`LinuxWebKit` implements `WebContent` (AppRuntime's `WebKit.md`) with WPE
WebKit, and the player draws `WebView` nodes. It follows Perry's
(`Sources/PerryUIKit/WPE.swift` there):

- **No WebKit at build time.** The host opens libwpe, WPEBackend-fdo,
  libwayland-server, `libWPEWebKit-2.0.so.1`, GLib and GObject when a page
  is first made, locally, so their symbols stand in for no others. Without
  them a page loads nothing, and fails each load saying so. Debian 13
  packages WPE 2.48 (`libwpewebkit-2.0-1`, `libwpebackend-fdo-1.0-1`);
  Ubuntu 26.04 doesn't, so the development image and CI moved to Debian 13.
- **Frames in shared memory.** WPEBackend-fdo runs in its SHM mode
  (`wpe_fdo_initialize_shm`), and each page's exportable view backend hands
  over every frame the web process draws as a `wl_shm` buffer: premultiplied
  BGRA, turned into RGBA for Cacao's `Image(pixels:)`. WebKit draws on the
  CPU; there's no GL.
- **GLib's context** runs on the main loop every 8 ms while there are pages:
  their signals, script results and frames all come through it.
- **The contract** maps onto `WebKitWebView`:
  - `load-changed`, `load-failed` and `load-failed-with-tls-errors` give
    loading, finishing and failing;
  - `notify::` on `uri`, `title` and `estimated-load-progress`, and the
    history after each commit, give the rest;
  - `uri` changes as soon as a load is asked for, and before a history
    navigation is decided, so it's reported only once the navigation
    commits or follows a redirect, as the contract wants;
  - cancelled and replaced navigations aren't failures.
- **Errors** come as GErrors and map to `WebError.Code`: WebKit's network
  and policy errors, GIO's (a timeout is `timedOut`, the rest `network`),
  the resolver's, and TLS (`security`).
- **`decide-policy`** asks `shouldNavigate` for each navigation and new
  window, except the guest's own `load`, `loadHTML` and `loadResource`. A
  new window loads in the same page. WPE doesn't say which frame a
  navigation is in, so `isMainFrame` is always true.
- **Without `network`**:
  - a remote `load`, or a navigation to a remote URL, fails with
    `notPermitted` before it starts;
  - every other request goes through a proxy on a `.invalid` host (RFC
    2606), which never resolves, so remote subresources don't load.
- **`loadResource`** loads a `file://` URL in the bundle's `resources/`,
  refusing paths that leave it.
- **The view** (`Sources/LinuxUI/HostWebView.swift`):
  - It gives the page its size in points and the display's scale, and
    makes it visible while it's on screen. The page stays loaded when the
    view goes.
  - A drag is the primary button, and hovering moves the pointer.
  - A click focuses the page. Keys go to it as XKB keysyms, which WPE turns
    into text.
- **The sandbox.** WebKit starts its web and network processes under
  bubblewrap, which can't make namespaces in a container, so the
  development image and CI set `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`
  for their test pages. The host leaves the sandbox on. Inside a launcher's
  own sandbox (AppRuntime's §7.8) it's still the open question `WebKit.md`
  names.
- **Not yet**:
  - The wheel: Cacao sends it only to its scroll views. Pages scroll with
    the arrow keys, Page Up and Page Down, and Space.
  - `alert`, `confirm` and `prompt`: WebKit's defaults apply, which show
    nothing.
  - Permission requests: WebKit denies them by default.
  - Touches, and buttons other than the primary.
  - Reading files beside a bundled page only: WebKit's file-URL rules
    apply.

## 9. Files and settings

`LinuxFiles` is the `Files` contract (AppRuntime's `Files.md`): AppRuntime's
`HostFiles`, which does it all over POSIX calls, with the app's directories
where Linux keeps them, and answers posted to the main loop from its queue.

| Directory | In a container | Otherwise, XDG's |
|---|---|---|
| `documents` | `<container>/Documents` | `$XDG_DATA_HOME/<id>/Documents` |
| `data` | `<container>/Data` | `$XDG_DATA_HOME/<id>/Data` |
| `caches` | `<container>/Caches` | `$XDG_CACHE_HOME/<id>` |
| `temporary` | `<container>/tmp` | `$XDG_RUNTIME_DIR/<id>`, or `/tmp/<id>-<uid>` |
| `bundle` | the bundle's `resources/` | the same |

- **`<id>`** is the bundle identifier, which must name a directory.
  `XDG_DATA_HOME` is `~/.local/share` and `XDG_CACHE_HOME` `~/.cache` when
  they're unset or relative, as the XDG specification says.
- **A container** is `LINUXAPPRUNTIME_CONTAINER`, an absolute path:
  - a PortMaster port's is its `conf/` folder, where ports keep what's
    theirs;
  - a launcher's sandbox would pass `/data` (AppRuntime's §7.8).
- **`temporary` is the app's own**, never `/tmp` itself, since `HostFiles`
  empties it at every start.
- **If the directories can't be decided**, for example with no `HOME`, the
  host logs why and every operation fails through its callback.

`LinuxDefaults` is the `Defaults` contract (`Defaults.md`): AppRuntime's
`HostDefaults` over a `FileDefaultsStorage`, one file with every setting in
it, rewritten atomically at each change.

- **The file** is `<container>/Defaults` in a container. Otherwise it's
  `$XDG_CONFIG_HOME/<id>/Defaults`, which is `~/.config/<id>/Defaults` by
  default: XDG's place for settings.
- **If it can't be opened**, the host logs why. Reads then find nothing,
  and writes are refused.

## 10. Testing

- `LinuxUI`: DarwinUI's tests, on Cacao (§5).
- `LinuxBluetooth`: the contract against a fake `BlueZBus` that plays
  BlueZ's objects and signals. Runs on macOS and Linux.
- `LinuxGraphics`: a surface's input order, focus and size, and on Linux
  frames drawn and read back with Mesa's llvmpipe, and a lost context.
- `LinuxHost`'s files: the directories from the environment, and the
  contract end to end in a container, answering on the main loop.
- `LinuxHost`'s settings: the file's path from the environment, and
  settings read again at the next launch.
- `LinuxWebKit`: on Linux, in WPE: loading HTML and the events' order,
  scripts' JSON, navigations asked about and refused, back, bundle
  resources, a refused connection, remote loads without `network`, frames
  and their pixels, a click, typing, and a resize. Every WebKit call is made
  on one thread, which WebKit takes for its main thread.
- End to end: AppRuntime's `ExampleUI` built as a `linux-arm64` slice,
  linked into `linux-app-host` and run headless with SDL's `offscreen`
  driver, its first frame saved with `CACAO_SCREENSHOT`.
- Real BlueZ needs hardware: manual runs on a Raspberry Pi or a laptop with
  `bluetoothd`.

## 11. Phases

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

## 12. Open questions

- **Permissions.** Desktop Linux has no prompts for Bluetooth; Flatpak's
  portals cover location and the camera. `Permissions.request` answers from
  the sandbox's declared capabilities until portals are used.
