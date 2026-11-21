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
- **One runner for every app.** `linux-app-host` loads an app's
  `libapp.so` (AppRuntime's §7.5, §7.6) instead of being built per app
  with its `libapp.a` linked in, so installing an app copies files and
  needs no toolchain, and the runner and the OS update on their own while
  the app's ABI stays put (§4).
- **Bluetooth** is tested against a fake bus that plays BlueZ's objects and
  signals; it hasn't run against `bluetoothd` and a device.
- **AppRuntime's `guest.py bundle`** needed one fix to run on Linux: it
  reads the contracts section with Embedded concurrency, which Linux
  toolchains ship only for their own triple. The bundle step still needs the
  wasm Swift SDK, so bundles are built on a Mac for now.

The Linux host for [AppRuntime](https://github.com/PureSwift/AppRuntime)
apps, the counterpart of DarwinAppRuntime. An AppRuntime app is guest code
only: a universal bundle with `App.wasm` and a native slice for each Linux
target (`linux-arm64`, `linux-x86_64`, `linux-armv7`), a `libapp.so`. This
repository runs one on Linux:

- the **runner**, `linux-app-host`: `main`, the event loop, the runtime core
  behind `rt.h`, and the contract implementations over Linux services, into
  which it loads an app's `libapp.so`;
- the **SwiftUI player**: DarwinAppRuntime's renderer of the SwiftUI
  frontend's render IR, on Cacao's SwiftUI for Linux;
- **Bluetooth** over BlueZ's D-Bus API;
- **GL surfaces**, OpenGL ES 2.0 over EGL, in the player's views;
- **web views**, WPE WebKit pages in the player's views;
- the **packager**, `linux-app` ([Packager.md](Packager.md)).

References like §7.6 are to `Documentation/DynamicRuntime.md` in AppRuntime;
the render IR is `Documentation/RenderIR.md` there. Perry
(MillerTechnologyPeru/Perry) runs iOS binaries on Linux and already talks to
BlueZ; this host reuses its approach (BlueZ over D-Bus), not its code, since
Perry implements Apple's ABI and this host implements AppRuntime's
contracts. D-Bus is PureSwift/DBus, in Swift, without libdbus.

## 1. Scope

| In | Later |
|---|---|
| arm64 and x86_64 Linux with glibc (Debian 13, Ubuntu 24.04+) | armv7, musl |
| Native slices, loaded by the runner | `App.wasm`, in an engine in the runner; wasm2c for a target a bundle lacks, before it's installed |
| Wayland and X11 through SDL3; a headless driver for tests | Multiple windows |
| `Renderer`, `BluetoothCentral` and friends, GL surfaces, web views, files, settings, model stores, date and number formatting, the device, location, the built-ins | Networking (libcurl), Motion (iio-sensor-proxy), NFC (neard) |

## 2. Process model

```
┌──────────────────── linux-app-host (the runner) ─────────────────┐
│ LinuxHostApp main                                                │
│   ├── runtime core: RuntimeCore + RuntimeNative (rt_* symbols)   │
│   ├── MainLoop: timers, jobs from other threads                  │
│   ├── LinuxBluetooth: BlueZ over LinuxDBus (→ MainLoop)          │
│   ├── LinuxGraphics: GL surfaces, EGL pbuffers read back         │
│   ├── LinuxWebKit: WPE WebKit pages, frames in shared memory     │
│   ├── LinuxUI: DarwinUI, render IR → SwiftUI views → events      │
│   │     └── Cacao: SwiftUI, Silica/Cairo, SDL3 windows and input │
│   └── libapp.so: the app's slice, loaded from its bundle         │
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
| `LinuxBluetooth` | `BluetoothCentral`, `BluetoothPeripheral`, `BluetoothService`, `BluetoothCharacteristic`, `BluetoothDescriptor`, `BluetoothAdvertisement` over BlueZ |
| `LinuxGraphics` | `Surface` over EGL and GLES 2.0, loaded at run time; the player's `GLSurface` view shows it (§7) |
| `LinuxWebKit` | `WebContent` over WPE WebKit, loaded at run time; the player's `WebView` view shows it (§8) |
| `LinuxCoreModel` | `LinuxModelStore`: the model store over CoreModel-SQLite, through AppRuntime's `HostModelStore` (§9) |
| `LinuxDevice` | `Device` from `/etc`, DMI, the device tree, and power and heat in sysfs (§10) |
| `LinuxDBus` | `Bus`: the system and session buses, for the modules that talk to system services: method calls, properties and signals by match rule, delivered on the main loop (§11.1) |
| `LinuxLocation` | `LocationManager`, `Location` and `Heading` over GeoClue 2 (§11) |
| `LinuxHostApp` | `main`: reads the app's keys, starts the host, and runs Cacao's SDL loop with one window showing the guest's first renderer |
| `LinuxPackager`, `linux-app` | The packager (§13, [Packager.md](Packager.md)) |

The package depends on AppRuntime without its `GuestExports` trait, like
DarwinAppRuntime, so the slice's `rt_dispatch` and `rt_finalize` are the
only ones linked (`HostRuntime.md` §8 in DarwinAppRuntime).

Some contracts need nothing of Linux's own, and AppRuntime has them for
every host written in Swift; this host registers them as they are:

- **Formatting** (`DynamicFormatting`): AppRuntime's `RuntimeFormatting`,
  `LocaleInfo`, `NumberFormat` and `DateFormat` over Swift Foundation,
  which formats with ICU, so a guest doesn't link it. Foundation on Linux
  doesn't read the POSIX environment for the user's locale, so
  `RuntimeFormatting` does: `LC_ALL`, else `LANG`, and `LANGUAGE` for the
  preferred languages. The time zone is `TZ`, else the system's.

## 4. Startup

`linux-app-host` is the one program every app runs in. No app is linked
into it: it loads the app's `libapp.so`, which names no other library and
leaves undefined only `rt.h`, a few libc functions and, for an app that
draws, GLES 2.0 (AppRuntime's §7.5).

```
linux-app-host [--bundle] App.app | IDENTIFIER [[--open] URL]
```

1. Find the app: a bundle's path, or an installed app's identifier, looked
   up as `<prefix>/lib/linux-app/<identifier>.app` in `~/.local`, the
   runner's own prefix, `/usr/local` and `/usr` (`LINUXAPPRUNTIME_PREFIXES`
   replaces the list). Without one, `LINUXAPPRUNTIME_BUNDLE`, or `App.app`
   next to the executable, as a PortMaster port has it.
2. Name the process after the app (`PR_SET_NAME`, `CFBundleExecutable`),
   so `ps` and `top` show it and not the runner.
3. Read the app's keys from its `Info.plist` and check the ABI and contract
   versions (§7.6), at every launch: the runner may have changed since the
   app was installed. A newer ABI or a contract this host lacks refuses it.
4. `NativeRuntime.shared.bindDirectly()`; set capabilities; set the clock.
   Register the built-ins (`Permissions`, `Bundle`, `Application`) and each
   module the app uses.
5. Load the library (`AppLibrary`):
   - check `lib/<target>/libapp.so` against the bundle's
     `_CodeSignature/CodeResources`, and load the bytes checked: the file is
     opened once, hashed, and loaded through its descriptor
     (`/proc/self/fd`);
   - for an app whose contracts include `Surface`, load
     `libGLESv2.so.2` into the global scope first;
   - `dlopen` it. It binds every symbol as it loads, so one the runner
     lacks refuses the app, by name;
   - look up `rt_main`, `rt_dispatch` and `rt_finalize`.
6. Call `rt_main`. When the guest calls `Renderer.make`, the player adds
   its scene; the first tree is there before `rt_main` returns.
7. Run Cacao's loop until the window closes, the window showing the first
   scene (or, for an app with no renderer, the `MainLoop` until it's
   interrupted).

What the runner's process supplies to the library:

- **`rt.h`.** RuntimeNative defines its functions in Swift (`@c`).
  `linux-app-host` is linked with a dynamic list
  (`Sources/LinuxAppHost/exports.list`) that exports `rt_*`, which keeps
  them though nothing in the runner calls them.
- **libc's part.** The library binds to the C library the runner runs on,
  glibc or musl. Where it lacks `arc4random_buf` (musl, glibc before 2.36),
  `CLinuxHost` defines it and the runner exports it; its executable is
  searched first, so that's the definition the app binds to.
- **GLES 2.0**, loaded as above.

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

One process-wide `BlueZHub` talks to BlueZ over `LinuxDBus`'s
`Bus.system` (§11.1), the process's one system-bus connection, and holds a
copy of BlueZ's objects from `GetManagedObjects` kept current by
`InterfacesAdded`, `InterfacesRemoved` and `PropertiesChanged`, and one
wrapper object per BlueZ path. D-Bus replies and signals are posted to the
`MainLoop`, so the guest is only called on the main thread. If the bus
closes, BlueZ is unavailable from then on. `BlueZBus` abstracts the
connection, so the contract logic is tested with a fake bus.

| Contract | BlueZ |
|---|---|
| `authorizationStatus`, `requestAuthorization` | `allowed`: Linux has no per-app prompt; the sandbox's `bluetooth` capability and `rt_class` gate access |
| `state` | No BlueZ or no adapter: `unsupported`; access denied on the bus: `unauthorized`; `Adapter1.Powered`: `poweredOn` / `poweredOff` |
| `scan` | `SetDiscoveryFilter({Transport: le, UUIDs, DuplicateData})`, `StartDiscovery`; a device is reported when it appears or its `RSSI`, `ManufacturerData` or `ServiceData` changes, once per scan unless duplicates are allowed; services filtered on the host too, since cached devices skip BlueZ's filter |
| `connect` | `Device1.Connect`; `didConnect` once `Connected` and `ServicesResolved`; the timeout is a main-loop timer that disconnects |
| `cancelConnection` | `Device1.Disconnect`, `didDisconnect` with `0` |
| `retrievePeripherals` | Devices by address (`BluetoothPeripheral.identifier`) |
| `retrieveConnectedPeripherals` | Connected devices with any of the services in `UUIDs` |
| `discoverServices`, `discoverCharacteristics`, `discoverDescriptors` | BlueZ resolves the database on connection: the `GattService1`, `GattCharacteristic1` and `GattDescriptor1` objects under the device |
| `readValue`, `writeValue` | `ReadValue({})`, `WriteValue(value, {type: request / command})` |
| `setNotifyValue` | `StartNotify` / `StopNotify`; values arrive as `PropertiesChanged` of `Value` |
| `readRSSI` | `Device1.RSSI` (BlueZ reports it while discovering) |
| `maximumWriteLength` | `GattCharacteristic1.MTU` − 3 without response, 512 with |
| `BluetoothAdvertisement` | `Name`, `ManufacturerData` (company ID first, little-endian), `UUIDs`, `ServiceData`, `TxPower` |

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

## 9. App data: files, settings and model stores

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

`LinuxModelStore`, in `LinuxCoreModel`, is the model store
(`Persistence.md`): the guest's CoreModel, through the `ModelStore`
contracts, to AppRuntime's `HostModelStore`, which turns them back into
CoreModel's requests for a backend. On Linux the backend is CoreModel's own
SQLite one, CoreModel-SQLite, with SQLite compiled in, so a device needs no
`libsqlite3`.

- **A store** is `<container>/Stores/<name>.sqlite` in a container, and
  `$XDG_DATA_HOME/<id>/Stores/<name>.sqlite` otherwise: beside the app's
  `Documents` and `Data`, out of reach of its `Files`.
- **The model** the store was made with is kept in it, in a table of its
  own, so the model and the objects change together. An open with the same
  model opens it. One that `canMigrate(from:to:)` allows (entities or
  properties added or removed) is migrated by copying what both models
  have into a new database, which then replaces the old one. Any other
  fails with `migrationRequired`, or starts the store again with `.reset`.
- **One `SQLiteDatabase` per store**, whichever of the app's storages use
  it, since it caches what it reads and must be its file's only writer. A
  storage still open on a model that a later open migrated from fails with
  `unavailable`: its file is gone.
- **A batch is one transaction**, in which each insert and delete is a
  savepoint of its own: all of it, or none.
- **Requests answer as CoreModel's in-memory evaluation does**, which is
  what defines them. Comparing the two found differences on both sides,
  fixed in PureSwift/CoreModel-SQLite#14 and PureSwift/CoreModel#41, which
  the package uses as branches until they're released. A predicate SQL
  can't say is evaluated in memory, over the store's objects.
- **Indexes**: the app's, and one on each to-one relationship's column,
  which its inverse to-many is read through. Those the app no longer
  declares are dropped.
- **SQLite's errors** are the contract's: a full disk is `outOfSpace`, a
  file that isn't a database `corrupted`, one that can't be opened or read
  `unavailable`.

## 10. The device

`LinuxDevice` is the `Device` contract (AppRuntime's `Device.md`). Linux
says what the machine is in files, so it's read from them, and nothing is
asked of D-Bus:

| | From |
|---|---|
| `name` | `PRETTY_HOSTNAME` in `/etc/machine-info`, else the host name |
| `model` | DMI's product family or name, else the device tree's `model` |
| `modelIdentifier` | DMI's product name, else the device tree's first `compatible` string, else `uname -m` |
| `manufacturer` | DMI's system vendor, else the vendor in `compatible` |
| `systemName`, `systemVersion` | `Linux`, and the kernel's version (`6.12`) |
| `idiom` | `CHASSIS` in `/etc/machine-info`, else DMI's chassis type: a tablet is `pad`, a handset `phone`, a desktop, laptop or server `desktop` |
| `vendorIdentifier` | A random UUID kept per vendor (the identifier without its last component) in `$XDG_DATA_HOME/linux-app/vendors`, or the container's `Vendors` |
| Memory, processors, uptime | `ProcessInfo`, and `CLOCK_BOOTTIME` |
| Battery | The machine's batteries in `/sys/class/power_supply` (not a mouse's: `scope` `Device`), their energy or charge together, and their `status` with the mains supply's `online` |
| Low power mode | `/sys/firmware/acpi/platform_profile` at `low-power`, which power-profiles-daemon's power saver sets |
| Thermal state | The hottest thermal zone against its own trip points: past `critical` or `hot`, critical; past `passive`, serious; within 10 °C of it, fair |

- **Changes** are found by reading again every 5 seconds while the app has a
  delegate, and told once each: battery level and state while battery
  monitoring is on, low power and thermal state always.
- **Firmware placeholders** in DMI ("To be filled by O.E.M.", "Default
  string") count as nothing.
- **Orientation and proximity** read as unknown and off: they come from
  iio-sensor-proxy, with the motion contracts.

## 11. Location

`LinuxLocation` is the Location contracts (AppRuntime's `Location.md`) over
GeoClue 2, on the system bus. Each `LocationManager` has a GeoClue client
of its own, made when it first needs one:

| | GeoClue |
|---|---|
| The client | `Manager.CreateClient`, deleted with the manager; `GetClient` on a GeoClue before 2.5, whose one client the process shares |
| Who's asking | The client's `DesktopId`: the app's identifier, which is its installed `<identifier>.desktop` file's name |
| `setDesiredAccuracy` | `RequestedAccuracyLevel`: `best` and `nearestTenMeters` exact, `hundredMeters` street, `kilometer` neighborhood, `reduced` city. GeoClue reads it on `Start`, so a running client starts again |
| `setDistanceFilter` | `DistanceThreshold`, in whole meters, rounded up; the manager also leaves out locations nearer than that to the last one it delivered. `TimeThreshold` is 0 (a GeoClue without it is fine) |
| `startUpdatingLocation`, `requestLocation` | `Start`; `requestLocation` stops again after one location, unless updates are on |
| `stopUpdatingLocation` | `Stop` |
| Locations | `LocationUpdated(o old, o new)`, then the new `Location` object's `Latitude`, `Longitude`, `Accuracy`, `Altitude` (`-G_MAXDOUBLE` unknown: `nan`), `Speed` and `Heading` (`-1` unknown), and `Timestamp` (`(tt)`, seconds and microseconds). Vertical, speed and course accuracy are unknown, and so is whether it's simulated (`-1`) |
| `isLocationServicesEnabled` | GeoClue answers `Manager.AvailableAccuracyLevel` within two seconds (it's started on demand), above none |
| Heading | Not available: Linux has no compass service. `startUpdatingHeading` fails with `headingFailure` |

- **Authorization** is GeoClue's agent's. When a client starts, GeoClue
  asks the agent of the user's session (gnome-shell's shows a prompt naming
  the app from its desktop file, and remembers the answer by desktop ID);
  a refusal is `AccessDenied` from `Start`. GeoClue has nothing to ask
  beforehand, so the status is `notDetermined` until a client starts in
  this process: `requestWhenInUseAuthorization()` starts the manager's
  client, and stops it again if nothing wants updates. Started, it's
  `authorizedAlways`; refused, `denied`. As on macOS, an app isn't
  suspended, so the one answer covers the background (`requestAlways…` is
  the same request, and `setBackgroundUpdatesEnabled` has nothing to do),
  and accuracy is `full`: GeoClue doesn't say what level the agent
  allowed. Every manager hears of a change once; a request is always
  answered. A later start asks again, so a mind changed in Settings is
  noticed.
- **Permissions** for `location`: `granted` and `denied` as above,
  `unavailable` without GeoClue, else `notDetermined`; `request` starts
  and stops a client of its own.
- **Without GeoClue** on the bus, or without a bus, the static calls answer
  at once (services off, `notDetermined`) and starting fails with
  `servicesDisabled`, as does GeoClue's "Geolocation disabled" refusal,
  which is the desktop's location switch, not the app's answer. A request
  then reads as `denied`, as CoreLocation's does with location off, so an
  app waiting for the answer gets one; it isn't kept as the app's refusal,
  and GeoClue starting clears it. Other errors are `unknown`, and logged.
- **The bus's policy.** GeoClue's own policy
  (`/usr/share/dbus-1/system.d/org.freedesktop.GeoClue2.conf`) lets any
  user call it. A sandbox has to let the app talk to
  `org.freedesktop.GeoClue2` on the system bus (Flatpak's
  `--system-talk-name=org.freedesktop.GeoClue2`), or use the desktop
  portal's location instead, later.
- **The agent.** Without one in the user's session GeoClue refuses every
  app ("disallowed, no agent"), which reads as `denied`. GNOME's is
  gnome-shell; elsewhere, GeoClue's demo agent
  (`/usr/libexec/geoclue-2.0/demos/agent`) allows everything. A device
  without a session, such as a kiosk, allows the app in
  `/etc/geoclue/geoclue.conf` instead: a section named for its identifier
  with `allowed=true`, `system=true` and `users=`.
- **Not done:** GeoClue leaving the bus while a client runs (restarted by
  systemd, say) isn't noticed; updates just stop.

### 11.1 D-Bus

`LinuxDBus` is what Bluetooth and Location, and later Motion
(iio-sensor-proxy), NFC (neard) and the desktop portal, share. `Bus.system`
and `Bus.session` are one connection each per process, made on first use
through PureSwift/DBus, which speaks D-Bus in Swift, without libdbus; its
values are `DBusMessageArgument`s, whose arrays and dictionaries carry
their element types.

- The connection is a `DBusConnection` on Swift's own threads: a writer
  task starts requests in the order they were made, on the connection's
  executor, and waits for the answer to one to the bus itself, such as
  `AddMatch`, before the next, so a rule is in place before what's asked
  after it; the connection's read loop hands each reply to its caller and
  each signal to the bus. Everything is posted to `MainLoop.shared`, so
  callers are only called on the main thread, and never inside their own
  call.
- `call`, `property`, `properties` (`GetAll`), `setProperty` (the value in
  a variant of its own type) and `subscribe(MatchRule)`, whose rule is
  added to the bus once however many subscriptions share it, and removed
  with the last. Signals are told apart again on this side by path,
  interface, member and `arg0`; a well-known sender is the bus's to check.
- `callAndWait` and `propertyAndWait` wait on the calling thread for a
  contract that answers at once; replies don't need the main loop, so the
  main thread can wait.
- If the connection closes, waiting calls fail with `Disconnected`, and
  subscribers to `MatchRule.disconnected` get the local
  `org.freedesktop.DBus.Local.Disconnected` signal; the next request
  connects again, and the rules are added again. Without a bus, calls fail
  with `NoServer`.

## 12. Testing

- `LinuxUI`: DarwinUI's tests, on Cacao (§5).
- `LinuxBluetooth`: the contract against a fake `BlueZBus` that plays
  BlueZ's objects and signals. Runs on macOS and Linux.
- `LinuxGraphics`: a surface's input order, focus and size, and on Linux
  frames drawn and read back with Mesa's llvmpipe, and a lost context.
- `LinuxHost`'s files: the directories from the environment, and the
  contract end to end in a container, answering on the main loop.
- `LinuxHost`'s settings: the file's path from the environment, and
  settings read again at the next launch.
- `LinuxHost`'s loader: libraries compiled by the test with the
  toolchain's clang, in signed bundles: loaded, and their exports called;
  refused unsigned, changed after signing, or not listed; a symbol the
  process lacks named in the refusal; a library to preload that isn't
  there. Where installed apps are found.
- `LinuxDevice`: a laptop's, a board's and an empty machine's files under a
  temporary root: identity, idioms, batteries (energy and capacity, a
  mouse's left out, each status), thermal states, low power, the vendor
  identifier kept per vendor, and changes reaching the delegate once each,
  by themselves on the main loop.
- `LinuxLocation`: the contract against a fake `GeoClueBus` that plays
  GeoClue's manager, clients, agent and locations. Runs on macOS and Linux:
  nothing asked until a client's needed; the client's desktop ID and
  settings before `Start`; authorization granted, refused and asked again,
  every manager told once, and `Permissions`; updates and their values,
  and what GeoClue doesn't know; one location; the distance and time
  thresholds; accuracy, which restarts a running client; stopping,
  including before GeoClue answers, and a manager deleting its client; an
  older GeoClue; no GeoClue, and the desktop's switch off; heading; the
  module's contracts.
- `LinuxDBus`: match rules and their matching, errors and values; no bus;
  and, where `dbus-daemon` is installed, a daemon of the test's own: calls
  waited for and on the main loop, properties, an error, a signal by match
  rule from another connection, and connecting again, with the rules, once
  the daemon's gone and another is in its place.
- `LinuxCoreModel`: where stores are; about 500 requests answered as
  CoreModel's in-memory store answers them; every value there and back;
  batches applied whole or not at all; a store kept between launches,
  migrated, refused or emptied; indexes made and dropped; a file that isn't
  a store; no directory. Runs on macOS and Linux.
- `LinuxWebKit`: on Linux, in WPE: loading HTML and the events' order,
  scripts' JSON, navigations asked about and refused, back, bundle
  resources, a refused connection, remote loads without `network`, frames
  and their pixels, a click, typing, and a resize. Every WebKit call is made
  on one thread, which WebKit takes for its main thread.
- End to end: AppRuntime's `ExampleUI`, `ExampleGL` and `ExampleModel`
  bundles, their `linux-arm64` `libapp.so` loaded by `linux-app-host` and
  run headless with SDL's `offscreen` driver, each first frame saved with
  `CACAO_SCREENSHOT`; `ExampleGL` with GLES loaded first. `ExampleModel`
  installed with `linux-app install` and launched by its identifier,
  shown by `ps` as `ExampleModel`, and refused once its library is
  changed; and launched twice on one container, with to-dos written into
  its SQLite database between the launches: the second shows them.
- Real BlueZ needs hardware: manual runs on a Raspberry Pi or a laptop with
  `bluetoothd`. Real GeoClue needs a session with an agent, or the app
  allowed in `geoclue.conf`.

## 13. Phases

1. **Host runtime and player**: `LinuxHost`, `LinuxUI`, `LinuxBluetooth`,
   `LinuxHostApp`; `ExampleUI` runs in Docker.
2. **Packager**: `linux-app` checks an app and installs it: its bundle
   thinned to the target's `libapp.so`, a `.desktop` file and icon, for
   the runner; later Flatpak and AppImage, whose manifests carry the
   capabilities (`--system-talk-name=org.bluez` for `bluetooth`).
3. **More contracts**: Networking (libcurl or AsyncHTTPClient), Motion
   (iio-sensor-proxy), NFC (neard). Formatting is done: AppRuntime's
   `RuntimeFormatting` (§3), and so are the device (§10) and location
   (§11), over GeoClue2.
4. **Player**: what DarwinUI and Cacao add: Cacao's AT-SPI bridge, input
   replay for end-to-end tests.

## 14. Open questions

- **Permissions.** Desktop Linux has no prompts for Bluetooth; Flatpak's
  portals cover location and the camera. `Permissions.request` answers from
  the sandbox's declared capabilities until portals are used.
