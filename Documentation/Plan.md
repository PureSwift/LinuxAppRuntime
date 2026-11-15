# Linux host — Plan

**Status:** phases 1 and 2 are implemented; the packager has its own
design, [Packager.md](Packager.md), and so do PortMaster ports,
[PortMaster.md](PortMaster.md). Phase 1 differs from the design below
in these ways:

- **Rounded corners** clip to rectangles: SDL has no rounded clip, so
  `cornerRadius` rounds the fills that cover its rectangle exactly (the
  usual `.background(…).cornerRadius(…)`) and clips the rest square.
- **Lazy containers** assume rows as tall as the first.
- **Scroll indicators** show whenever content overflows.
- **`refresh`** (5) is sent by its number: `RenderEventKind` in AppRuntime's
  released `DynamicUI` doesn't name it yet.
- **Searchable** fields in a navigation bar draw no magnifying glass.
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
- the **SwiftUI player**, which lays out and draws the SwiftUI frontend's
  render IR with SDL3 and SDL3_ttf, and sends input back;
- **Bluetooth** over BlueZ's D-Bus API;
- the **packager**, `linux-app` ([Packager.md](Packager.md)).

References like §7.6 are to `Documentation/DynamicRuntime.md` in AppRuntime;
the render IR is `Documentation/RenderIR.md` there. Perry
(MillerTechnologyPeru/Perry) runs iOS binaries on Linux and already talks to
SDL3 and BlueZ; this host reuses its approach (SDL3 for windows and input,
BlueZ through `wendylabsinc/dbus`), not its code, since Perry implements
Apple's ABI and this host implements AppRuntime's contracts.

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
│   ├── MainLoop: timers, jobs from other threads, SDL events      │
│   ├── LinuxBluetooth: BlueZ over D-Bus (NIO threads → MainLoop)  │
│   ├── LinuxUI: render IR → layout → draw, input → events         │
│   │     └── LinuxSDL: window, SDL_Renderer, SDL3_ttf             │
│   └── libapp.a: the app's sealed linux-arm64 / linux-x86_64 slice│
└──────────────────────────────────────────────────────────────────┘
```

Everything that calls the guest runs on the main thread (§6.4). Work on
other threads (D-Bus, later networking) posts its results to the
`MainLoop`. The host doesn't use the main actor or the main dispatch queue:
nothing drains them while SDL waits for events.

### 2.1 The main loop

`MainLoop` owns the main thread:

1. run timers that are due (the `Clock` built-in schedules on them);
2. run jobs posted from other threads;
3. lay out and draw if a window needs it;
4. wait until the next timer, a posted job, or an SDL event.

A `MainLoopDriver` does the waiting. The default one waits on a semaphore;
the SDL driver waits in `SDL_WaitEventTimeout` and wakes with
`SDL_PushEvent` (thread-safe), so input, timers and D-Bus replies all wake
the same loop. `MainLoopClock` is the `HostClock`: `CLOCK_MONOTONIC` for
`now`, the loop's timers for `schedule`.

## 3. Modules

| Module | Contents |
|---|---|
| `LinuxHost` | `AppHost` (checks, built-ins, modules, `rt_main`), `AppInfo` (the bundle's `Info.plist` keys), `HostModule`, `MainLoop`, `MainLoopClock`, `Permissions`, `Bundle`, `Application` |
| `LinuxUI` | The player's model, with no SDL: the render store, layout, drawing to a `Canvas`, hit testing, focus and text editing, lazy rows, navigation, presentations. Tested with a recording canvas and a fixed-width text measurer. |
| `LinuxSDL` | The `Canvas` and text measurer over `SDL_Renderer` and SDL3_ttf, the window, input translation, the SDL main-loop driver, fonts through fontconfig; SDL3 through [PureSwift/SDL](https://github.com/PureSwift/SDL) (`SDL3Swift`, `CSDL3TTF`) |
| `LinuxBluetooth` | `Central`, `Peripheral`, `Service`, `Characteristic`, `Descriptor`, `Advertisement` over BlueZ |
| `LinuxHostApp` | `main`: reads the app's keys, starts the host, opens the window when the guest makes a renderer, runs the loop |
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
5. Call `rt_main`. When the guest calls `Renderer.make`, the player makes
   the window; the first tree is there before `rt_main` returns.
6. Run the main loop until the window closes (or, for an app with no
   renderer, until it's interrupted).

## 5. The SwiftUI player

### 5.1 Model

`RenderStore` keeps the tree the guest sent (`apply` replaces it,
`replaceSubtree` patches it by ID) and per-ID view state that outlives
updates: scroll offsets, the focused text field and its editing buffer,
the last value rendered for each control (for control sync), lazy rows by
list revision, open menus. A frame is: environment → layout → draw. Every
update marks the window dirty; the next turn of the loop draws once.

### 5.2 Layout

SwiftUI's two-pass protocol, in plain Swift: a parent proposes a size
(either dimension may be unspecified), the child answers its size, the
parent places it.

- **Modifiers wrap the node** in order: `padding` shrinks the proposal and
  insets the result; `frame` fixes, clamps or fills (∞) and aligns;
  `offset` moves only when drawing. Inherited modifiers (`font`,
  `foregroundColor`, `tint`, `disabled`, `lineLimit`,
  `multilineTextAlignment`) set the environment; the innermost wins.
- **Stacks** divide space by flexibility, as SwiftUI does: each child's
  minimum and maximum along the axis, least flexible first, each offered
  an equal share of what's left. `Spacer` is fully flexible. Alignment is
  per child on the cross axis.
- **Text** wraps to the width offered, up to `lineLimit`, measured by the
  text measurer (SDL3_ttf).
- **Greedy views** take what they're offered: `Color`, `ScrollView`,
  `List`, `Form`, `TextField`, `Slider`, `Toggle`, `Stepper` widths.
- **Grids**: `Grid` sizes columns to their widest cell; `LazyVGrid` and
  `LazyHGrid` resolve fixed, flexible and adaptive items.
- **Lazy containers** measure row 0 and lay out `count` rows of that
  height; drawing fetches only the rows inside the clip, through
  `rowCount` / `row`, cached until `revision` changes.

### 5.3 Drawing

`Canvas` is the drawing interface: filled and stroked rounded rectangles,
lines, circles, text runs, clip and opacity stacks. `LinuxSDL` implements
it with `SDL_RenderFillRect`, `SDL_RenderGeometry` (rounded corners,
circles) and SDL3_ttf's renderer text engine (`TTF_Text`, cached per frame
by string, font and wrap width). Coordinates are points; the canvas scales
by the window's pixel density and opens fonts at the scaled size, so text
stays sharp on HiDPI displays.

Look: GNOME/libadwaita-like. Light and dark follow `SDL_GetSystemTheme`;
the named colors are the IR's palette, with GNOME's blue as the accent.
Fonts come from fontconfig (`sans-serif`, `monospace`, `serif` for the
`design`s); text styles map to sizes (`body` 15 pt, `largeTitle` 30 pt, …).
SF Symbols don't exist on Linux: common `systemName`s map to Unicode
glyphs in the font, and the rest draw a placeholder.

### 5.4 Controls and events

| Node | Desktop control | Events |
|---|---|---|
| `Button`, `onTapGesture`, `NavigationLink` | Rounded button; a list row with a chevron | `tap` on release inside |
| `Toggle` | Switch at the trailing edge | `change(bool)` |
| `TextField`, `Searchable` | Single-line field; SDL text input (IME), caret, Backspace, Delete, arrows, Home/End, Ctrl+A/C/V/X, Enter | `change(string)` per edit, `submit` |
| `Slider` | Track and knob; drag, arrow keys | `change(double)`, stepped |
| `Stepper` | − and + buttons | `change(int)`, clamped |
| `Picker` | Segmented row, or a button with a popup menu (`menu`, `wheel`), or checkmark rows (`inline`) | `change(int)` |
| `TabView` | Tab bar along the bottom | `change(int)` |
| `DisclosureGroup` | Row with a disclosure triangle | `change(bool)` |
| `NavStack` | Header bar: back button, title, toolbar items | `pop(levels left)` on back, Alt+Left |
| `Sheet`, `Alert` | Modal card over a dimmed window | `change(false)` on Escape, outside click, or an alert button (after its `tap`) |
| `Menu`, `SwipeActions`, `ContextMenu` | Popup menu; a view's context menu and its row's swipe actions appear together on a right click | the item's `tap` |
| `DatePicker` | A date pill and a time pill, in the local time zone and locale; each opens a card of −/+ rows (year, month, day; hour, minute) that steps within `min` and `max` | `change(double)` per step |
| `Refreshable` | Scrolling up past the top of its list (wheel, touchpad, D-pad) pulls it; a spinner shows while `refreshing` | `refresh` |
| `Shape` | Filled or stroked rectangle, rounded rectangle, circle or capsule; ellipses draw as capsules | — |
| `Link` | Accent text; opens with `xdg-open` | — |
| `ScrollView`, `List`, `Form` | Wheel and touchpad scrolling, clipped | — |

Tab moves focus between text fields. `disabled` draws at half opacity and
takes no input. Control sync follows the IR rules: a control takes the
guest's value only when it differs from the value last rendered, so typing
isn't overwritten.

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

- `LinuxUI`: layout, drawing commands, hit testing, events and control sync
  against fixed trees, with a recording canvas and a fixed-width measurer.
  Runs on macOS and Linux.
- `LinuxBluetooth`: the contract against a fake `BlueZBus` that plays
  BlueZ's objects and signals. Runs on macOS and Linux.
- `LinuxSDL`: smoke tests with SDL's `offscreen` video driver in Docker:
  the window opens, draws, and saves a screenshot.
- End to end: AppRuntime's `ExampleUI` built as a `linux-arm64` slice
  (`guest.py slice --product ExampleUI --target linux-arm64`), linked into
  `LinuxHostApp`, run headless; a screenshot of each screen, and input
  replayed through SDL events.
- Real BlueZ needs hardware: manual runs on a Raspberry Pi or a laptop with
  `bluetoothd`.

## 8. Phases

1. **Host runtime and player** (this change): `LinuxHost`, `LinuxUI`,
   `LinuxSDL`, `LinuxBluetooth`, `LinuxHostApp`; `ExampleUI` runs in
   Docker.
2. **Packager**: `linux-app` builds the host for a target triple, links the
   bundle's slice (or wasm2c output), and writes an installable directory:
   the executable, `Info.plist`, resources, a `.desktop` file and icon;
   later Flatpak and AppImage, whose manifests carry the capabilities
   (`--system-talk-name=org.bluez` for `bluetooth`).
3. **More contracts**: Location (GeoClue2), Device (UPower, sysfs),
   Networking (libcurl or AsyncHTTPClient), Formatting (ICU), Motion
   (iio-sensor-proxy), NFC (neard).
4. **Player**: images from the bundle (SDL3_image), animations, keyboard
   navigation for every control, accessibility (AT-SPI).

## 9. Open questions

- **Sharing with DarwinAppRuntime.** `AppInfo`, `AppHost`'s checks and
  `HostModule` are the same on both hosts. They could move into AppRuntime
  (`RuntimeHost`) once a third host needs them.
- **Fonts.** Text measured by SDL3_ttf differs from Apple's, so layouts
  differ slightly; the IR only promises close layout.
- **Permissions.** Desktop Linux has no prompts for Bluetooth; Flatpak's
  portals cover location and the camera. `Permissions.request` answers from
  the sandbox's declared capabilities until portals are used.
