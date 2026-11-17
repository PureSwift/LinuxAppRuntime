# PortMaster — Design

[PortMaster](https://portmaster.games) installs ports on Linux handhelds
(ROCKNIX, muOS, Knulli, AmberELEC, ArkOS…). A port is a native program with
the libraries it needs, a bash launcher that sources PortMaster's
`control.txt`, and metadata for PortMaster's catalogue. `linux-app
portmaster` makes one from a universal bundle, for `aarch64` and `armhf`
(32-bit armv7, hard-float).

## 1. The port

The layout of a port in PortMaster's repository (`PortsMaster/PortMaster-New`,
`ports/<port>/`), which is also what the zip unpacks to:

```
<Title>.sh                  the launcher
port.json                   catalogue entry: title, porter, description, arch, min_glibc
gameinfo.xml                EmulationStation metadata
README.md                   notes and controls
screenshot.png              the screenshot: --screenshot, or the app's icon
<port>/
  <executable>.aarch64      the host, linked with the app, per architecture
  <executable>.armhf
  libs.aarch64/             SDL3 and SDL3_ttf, built for old glibc
  libs.armhf/
  App.app/                  Info.plist and resources
  fonts/                    DejaVu, for devices without fontconfig
  <port>.gptk               gptokeyb's mapping
  licenses/
```

`<port>` is the executable's name in lowercase. Packaging one architecture
into a directory that has the other adds to it: `port.json`'s `arch` lists
both, and `min_glibc` is the newer of the two. The zip, `<port>.zip`, also
carries `port.json`, `gameinfo.xml`, `README.md` and the screenshot inside
`<port>/`, where PortMaster keeps them once installed.

## 2. The launcher

PortMaster's standard template: find the control folder, source
`control.txt` and the firmware's `mod_<CFW>.txt`, `get_controls`, put
`libs.${DEVICE_ARCH}` on `LD_LIBRARY_PATH`, start `gptokeyb` with the
port's mapping, `pm_platform_helper`, run, `pm_finish`. It also sets the
host's options for a handheld:

| Variable | |
|---|---|
| `LINUXAPPRUNTIME_FULLSCREEN=1` | One fullscreen window (KMSDRM) |
| `LINUXAPPRUNTIME_WINDOW_SIZE` | `${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}` |
| `LINUXAPPRUNTIME_SCALE` | Pixels per point: 1 below 700 pixels tall, 1.5 below 1000, 2 above, so a 640 × 480 screen is 640 × 480 points and a 720 × 720 one 480 × 480 |
| `LINUXAPPRUNTIME_CURSOR=1` | Draw a pointer: there's no mouse, and KMSDRM has no system cursor |
| `LINUXAPPRUNTIME_FONTS` | `fonts/`, used when fontconfig isn't there |
| `LINUXAPPRUNTIME_CONTAINER` | `conf/`: the app's files, settings and model stores, where ports keep what's theirs |

## 3. Controls

`gptokeyb` turns the gamepad into a mouse and keys, which the player
already understands:

| Button | Action |
|---|---|
| Left stick | Move the pointer |
| A | Click |
| B, Select | Escape: close a menu, sheet or alert |
| X | Right click: a row's swipe actions |
| Y | Tab: the next text field |
| L1 | Alt+Left: back |
| R1 | Slow pointer |
| D-pad | Arrow keys: menus, the text cursor, and scrolling the view under the pointer |
| Right stick | Scroll |
| Start | Enter |
| Start + Select | Quit |

Text fields take what `gptokeyb`'s on-screen text input sends.

## 4. Building for a handheld

Handhelds run older glibc than desktop distributions, and don't ship
SDL3. PortMaster builds ports on Ubuntu 22.04 (glibc 2.35), and so do the
two images `Scripts/portmaster.sh` uses:

| Image | Toolchain | glibc | SDL3 |
|---|---|---|---|
| `Docker/portmaster-aarch64.Dockerfile` | Swift 6.4.2 on Ubuntu 22.04 (the oldest Swift 6.4 image) | 2.35 | SDL3 and SDL3_ttf from source, with KMSDRM, and FreeType and HarfBuzz built in |
| `Docker/portmaster-armhf.Dockerfile` | Swift 6.4.0 on Ubuntu 22.04 with the community armv7 SDK for Ubuntu 22.04 ([swift-embedded-linux/armhf-debian](https://github.com/swift-embedded-linux/armhf-debian)) | 2.35 | The same, cross-compiled against the SDK's sysroot |

Swift is linked statically. The armhf build goes through SwiftPM's native
build system, since the default one ignores destination files. Ubuntu
22.04's glibc has no `arc4random_buf`, which app slices call, so the host
supplies it there (`CLinuxHost`). fontconfig is loaded at run time if it's there;
otherwise the host uses `fonts/`. The images say what they bundle
(`LINUXAPPRUNTIME_PORT_LIBS`) and how to build (`LINUXAPPRUNTIME_SWIFT_SDK`
for the armv7 SDK); `linux-app portmaster` reads both.

The guest side is unchanged: the bundle's `linux-arm64` and `linux-armv7`
slices are libc-agnostic, so they link into either host.

## 5. Testing

`Scripts/portmaster.sh test` runs a port the way PortMaster would, in an
old distribution with a stand-in `control.txt` and SDL's offscreen driver:
Ubuntu 22.04 for both, armhf under emulation.

## 6. Later

- Focus navigation with the D-pad, without the pointer.
- SDL's own gamepad events, for devices without `gptokeyb`.

## 7. On Cacao

The player is now DarwinUI on Cacao (`Plan.md` §5), and ports don't build
with it yet. What's left:

- **Cairo for old glibc.** Cacao draws with Silica over Cairo, so the
  images need Cairo, pixman, libpng, FreeType, fontconfig and Expat built
  for Ubuntu 22.04's glibc (from its packages; for armhf, into the SDK's
  sysroot), and ports bundle them with SDL3. Cacao also links
  `libwayland-client`.
- **Handheld options in Cacao.** The earlier player read
  `LINUXAPPRUNTIME_FULLSCREEN`, `LINUXAPPRUNTIME_SCALE`,
  `LINUXAPPRUNTIME_CURSOR` and `LINUXAPPRUNTIME_FONTS` (§2); Cacao's window
  needs the same: a fullscreen window, a scale for small screens, a drawn
  pointer for `gptokeyb`'s mouse, and fonts when fontconfig has none. The
  launcher still sets them.
- **Testing.** `Scripts/portmaster.sh test` saves the first frame
  (`CACAO_SCREENSHOT`); there's no input replay on Cacao yet.
