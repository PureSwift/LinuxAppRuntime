import Foundation

/// `linux-app portmaster`: a PortMaster port of an app (`PortMaster.md`).
///
/// A handheld has no runner installed, so the port carries one, named
/// after the app, beside the app's bundle thinned to its `libapp.so` for
/// each architecture. The runner is the same for every app; it's built
/// here because a port's runs on an older glibc than a distribution's.
public struct PortMasterPort {

    public struct Options {
        /// Where the port's directory and zip go.
        public var output: URL
        /// This package's source, which the runner is built from.
        public var source: URL = URL(fileURLWithPath: ".")
        /// The runner's build directory.
        public var scratch: URL = URL(fileURLWithPath: ".build/linux-app/runner")
        /// More `swift build` arguments: a Swift SDK's destination for
        /// another architecture.
        public var buildArguments: [String] = []
        /// The libraries the port bundles: SDL3, SDL3_ttf, and whatever the
        /// build environment says (`LINUXAPPRUNTIME_PORT_LIBS`).
        public var libraries: URL?
        /// Fonts for devices without fontconfig.
        public var fonts: URL? = URL(fileURLWithPath: "/usr/share/fonts/truetype/dejavu")
        public var porters: [String] = []
        public var description: String?
        public var screenshot: URL?

        public init(output: URL) {
            self.output = output
        }
    }

    public struct Result {
        /// The port as PortMaster's repository has it: `ports/<port>/`.
        public var directory: URL
        public var zip: URL
        public var minimumGLIBC: String?
        public var diagnostics: [Diagnostic]
    }

    /// Checks the app: a `Packager` for `linux-arm64` or `linux-armv7`.
    public var packager: Packager

    public var options: Options

    public init(packager: Packager, options: Options) {
        self.packager = packager
        self.options = options
    }

    var bundle: UniversalBundle {
        packager.bundle
    }

    /// PortMaster's `DEVICE_ARCH` for a target.
    public static func architecture(_ target: LinuxTarget) -> String? {
        switch target {
        case .arm64: "aarch64"
        case .armv7: "armhf"
        case .x86_64: "x86_64"
        }
    }

    /// The port's folder name: the executable, lowercase, letters and digits.
    public var name: String {
        let name = bundle.executable.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return name.isEmpty ? "app" : name
    }

    /// The launcher's name: the app's name, as PortMaster's menus show it.
    public var launcher: String {
        let title = bundle.displayName.filter { $0 != "/" && $0 != "\\" && $0 != "\0" }
        return (title.isEmpty ? bundle.executable : title) + ".sh"
    }

    // MARK: Packaging

    public func package() throws(PackagerError) -> Result {
        guard let architecture = Self.architecture(packager.options.target) else {
            throw PackagerError("PortMaster has no \(packager.options.target.rawValue)")
        }
        let diagnostics = packager.validate()
        let errors = diagnostics.filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw PackagerError(errors.map(\.description).joined(separator: "\n"))
        }
        let target = packager.options.target
        let binary = try Runner.build(source: options.source,
                                      scratch: options.scratch.appendingPathComponent(target.rawValue),
                                      extraArguments: options.buildArguments, runner: packager.runner)
        let result = try assemble(binary: binary, architecture: architecture)
        return Result(directory: result.directory, zip: result.zip, minimumGLIBC: result.glibc, diagnostics: diagnostics)
    }

    /// Writes the port around a built runner, adding to a port that has the
    /// other architecture.
    func assemble(binary: URL, architecture: String) throws(PackagerError) -> (directory: URL, zip: URL, glibc: String?) {
        let files = FileManager.default
        let port = options.output.appendingPathComponent(name)
        let game = port.appendingPathComponent(name)
        do {
            try files.createDirectory(at: game, withIntermediateDirectories: true)

            // The runner, named after the app so that's what the device
            // shows running, and its libraries, for this architecture.
            let program = game.appendingPathComponent("\(bundle.executable).\(architecture)")
            try replace(program, with: binary)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
            let libs = game.appendingPathComponent("libs.\(architecture)")
            if files.fileExists(atPath: libs.path) {
                try files.removeItem(at: libs)
            }
            try files.createDirectory(at: libs, withIntermediateDirectories: true)
            var glibc = [ELF.requiredGLIBC(program)].compactMap { $0 }
            if let libraries = options.libraries {
                for name in try files.contentsOfDirectory(atPath: libraries.path).sorted() where name.contains(".so") {
                    // Copies the file a link points to under the link's name.
                    let source = libraries.appendingPathComponent(name).resolvingSymlinksInPath()
                    let destination = libs.appendingPathComponent(name)
                    try files.copyItem(at: source, to: destination)
                    if let version = ELF.requiredGLIBC(destination) {
                        glibc.append(version)
                    }
                }
            }

            // The bundle, thinned: what both architectures share, and each
            // one's libapp.so, keeping the other architecture's.
            let app = game.appendingPathComponent("App.app")
            try files.createDirectory(at: app, withIntermediateDirectories: true)
            for name in Packager.kept {
                let destination = app.appendingPathComponent(name)
                if files.fileExists(atPath: destination.path) {
                    try files.removeItem(at: destination)
                }
                let source = bundle.url.appendingPathComponent(name)
                if files.fileExists(atPath: source.path) {
                    try files.copyItem(at: source, to: destination)
                }
            }
            let target = packager.options.target
            guard let slice = bundle.slice(target) else {
                throw PackagerError("the bundle has no \(target.rawValue) slice")
            }
            let library = app.appendingPathComponent(target.sharedLibrary)
            try files.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replace(library, with: slice)
            if let fonts = options.fonts, files.fileExists(atPath: fonts.path) {
                let destination = game.appendingPathComponent("fonts")
                if files.fileExists(atPath: destination.path) {
                    try files.removeItem(at: destination)
                }
                try files.createDirectory(at: destination, withIntermediateDirectories: true)
                for name in try files.contentsOfDirectory(atPath: fonts.path) where name.lowercased().hasSuffix(".ttf") {
                    try files.copyItem(at: fonts.appendingPathComponent(name).resolvingSymlinksInPath(),
                                       to: destination.appendingPathComponent(name))
                }
            }
            try Self.gptk.write(to: game.appendingPathComponent("\(name).gptk"), atomically: true, encoding: .utf8)
            try writeLicenses(into: game.appendingPathComponent("licenses"))

            let launcherURL = port.appendingPathComponent(launcher)
            try launcherScript.write(to: launcherURL, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)

            // The catalogue entry, merged with the other architecture's.
            let jsonURL = port.appendingPathComponent("port.json")
            var architectures = [architecture]
            if let data = files.contents(atPath: jsonURL.path),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let attributes = existing["attr"] as? [String: Any] {
                architectures += attributes["arch"] as? [String] ?? []
                if let previous = attributes["min_glibc"] as? String, !previous.isEmpty {
                    glibc.append(previous)
                }
            }
            let minimum = ELF.newest(glibc)
            try portJSON(architectures: Array(Set(architectures)).sorted(), minimumGLIBC: minimum)
                .write(to: jsonURL)
            try gameInfo.write(to: port.appendingPathComponent("gameinfo.xml"), atomically: true, encoding: .utf8)
            try readme.write(to: port.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            if let screenshot = options.screenshot ?? bundle.icon {
                try replace(port.appendingPathComponent("screenshot.png"), with: screenshot)
            }

            let zip = try makeZip(port: port)
            return (port, zip, minimum)
        } catch let error as PackagerError {
            throw error
        } catch {
            throw PackagerError("can't write the port into \(port.path): \(error)")
        }
    }

    private func replace(_ destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// `<port>.zip`: the launcher and the game folder, with the metadata
    /// inside it as PortMaster installs it.
    private func makeZip(port: URL) throws -> URL {
        let files = FileManager.default
        let staging = options.output.appendingPathComponent(".\(name)-zip")
        if files.fileExists(atPath: staging.path) {
            try files.removeItem(at: staging)
        }
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        try files.copyItem(at: port.appendingPathComponent(launcher), to: staging.appendingPathComponent(launcher))
        let game = staging.appendingPathComponent(name)
        try files.copyItem(at: port.appendingPathComponent(name), to: game)
        for metadata in ["port.json", "gameinfo.xml", "README.md", "screenshot.png"] {
            let source = port.appendingPathComponent(metadata)
            if files.fileExists(atPath: source.path) {
                try files.copyItem(at: source, to: game.appendingPathComponent(metadata))
            }
        }
        let zip = options.output.appendingPathComponent("\(name).zip")
        if files.fileExists(atPath: zip.path) {
            try files.removeItem(at: zip)
        }
        // Python's zipfile keeps the files' permissions.
        try packager.runner.run(["python3", "-m", "zipfile", "-c", zip.path, launcher, name], directory: staging, environment: [:])
        try files.removeItem(at: staging)
        return zip
    }

    // MARK: Files

    /// PortMaster's launcher template (`PortMaster.md` §2).
    var launcherScript: String {
        let executable = bundle.executable
        return """
            #!/bin/bash
            # \(bundle.displayName) \(bundle.info.version): an AppRuntime app (\(bundle.info.identifier)),
            # packaged by linux-app.

            XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

            if [ -d "/opt/system/Tools/PortMaster/" ]; then
              controlfolder="/opt/system/Tools/PortMaster"
            elif [ -d "/opt/tools/PortMaster/" ]; then
              controlfolder="/opt/tools/PortMaster"
            elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
              controlfolder="$XDG_DATA_HOME/PortMaster"
            else
              controlfolder="/roms/ports/PortMaster"
            fi

            source $controlfolder/control.txt

            [ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
            get_controls

            GAMEDIR="/$directory/ports/\(name)"
            cd "$GAMEDIR"

            > "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1

            export LD_LIBRARY_PATH="$GAMEDIR/libs.${DEVICE_ARCH}:$LD_LIBRARY_PATH"
            export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
            export TEXTINPUTINTERACTIVE="Y"

            # The host on a handheld: one fullscreen window, a drawn pointer, the
            # port's fonts when fontconfig isn't there, phone-sized layouts
            # scaled to the screen, and the app's files in the port's conf/,
            # where ports keep what's theirs.
            export LINUXAPPRUNTIME_CONTAINER="$GAMEDIR/conf"
            export LINUXAPPRUNTIME_FULLSCREEN=1
            export LINUXAPPRUNTIME_CURSOR=1
            export LINUXAPPRUNTIME_FONTS="$GAMEDIR/fonts"
            if [ "${DISPLAY_HEIGHT:-480}" -ge 1000 ]; then
              export LINUXAPPRUNTIME_SCALE=2
            elif [ "${DISPLAY_HEIGHT:-480}" -ge 700 ]; then
              export LINUXAPPRUNTIME_SCALE=1.5
            else
              export LINUXAPPRUNTIME_SCALE=1
            fi

            $ESUDO chmod +x "$GAMEDIR/\(executable).${DEVICE_ARCH}"

            $GPTOKEYB "\(executable).${DEVICE_ARCH}" -c "$GAMEDIR/\(name).gptk" &
            pm_platform_helper "$GAMEDIR/\(executable).${DEVICE_ARCH}"
            ./\(executable).${DEVICE_ARCH} --bundle "$GAMEDIR/App.app"

            pm_finish

            """
    }

    /// gptokeyb's mapping (`PortMaster.md` §3).
    static let gptk = """
        back = esc
        start = enter
        guide = enter
        a = mouse_left
        b = esc
        x = mouse_right
        y = tab
        l1 = left
        l1 = add_alt
        r1 = mouse_slow
        l2 = pageup
        r2 = pagedown
        up = up
        down = down
        left = left
        right = right
        left_analog_up = mouse_movement_up
        left_analog_down = mouse_movement_down
        left_analog_left = mouse_movement_left
        left_analog_right = mouse_movement_right
        right_analog_up = up
        right_analog_down = down
        right_analog_left = left
        right_analog_right = right
        mouse_slow_scale = 50
        deadzone_mode = scaled_radial
        deadzone = 2000
        deadzone_scale = 8
        deadzone_delay = 16

        """

    func portJSON(architectures: [String], minimumGLIBC: String?) throws -> Data {
        let json: [String: Any] = [
            "version": 4,
            "name": "\(name).zip",
            "items": [launcher, name],
            "items_opt": [String](),
            "attr": [
                "title": bundle.displayName,
                "porter": options.porters,
                "desc": description,
                "desc_md": NSNull(),
                "inst": "Ready to Run",
                "inst_md": NSNull(),
                "genres": ["other"],
                "image": NSNull(),
                "rtr": true,
                "exp": false,
                "runtime": [String](),
                "store": [String](),
                "availability": "full",
                "reqs": [String](),
                "arch": architectures,
                "min_glibc": minimumGLIBC ?? "",
            ] as [String: Any],
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    var description: String {
        options.description ?? "\(bundle.displayName), an AppRuntime app."
    }

    var gameInfo: String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <gameList>
          <game>
            <path>./\(xml(launcher))</path>
            <name>\(xml(bundle.displayName))</name>
            <desc>\(xml(description))</desc>
            <genre>Other</genre>
            <image>./\(xml(name))/screenshot.png</image>
          </game>
        </gameList>

        """
    }

    var readme: String {
        """
        ## Notes

        \(description) Built with [AppRuntime](https://github.com/PureSwift/AppRuntime) and packaged by \
        [LinuxAppRuntime](https://github.com/PureSwift/LinuxAppRuntime)'s `linux-app portmaster`.

        ## Controls

        | Button | Action |
        |--|--|
        | Left Stick | Move the pointer |
        | A | Click |
        | B / Select | Back out: close a menu, sheet or alert |
        | X | Right click: a row's actions |
        | Y | Next text field |
        | L1 | Go back |
        | R1 | Slow pointer |
        | D-Pad / Right Stick | Scroll, choose in menus |
        | L2 / R2 | Page up and down |
        | Start | Enter |

        """
    }

    func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func writeLicenses(into directory: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: directory.path) {
            try files.removeItem(at: directory)
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = options.source.appendingPathComponent("LICENSE")
        if files.fileExists(atPath: host.path) {
            try files.copyItem(at: host, to: directory.appendingPathComponent("LinuxAppRuntime.txt"))
        }
        // What the build environment documents about what it bundles.
        for source in [options.libraries?.appendingPathComponent("licenses"), options.fonts.map { _ in URL(fileURLWithPath: "/usr/share/doc/fonts-dejavu-core/copyright") }] {
            guard let source, files.fileExists(atPath: source.path) else { continue }
            var isDirectory: ObjCBool = false
            _ = files.fileExists(atPath: source.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                for name in try files.contentsOfDirectory(atPath: source.path) {
                    try files.copyItem(at: source.appendingPathComponent(name), to: directory.appendingPathComponent(name))
                }
            } else {
                try files.copyItem(at: source, to: directory.appendingPathComponent("DejaVu.txt"))
            }
        }
    }
}
