/// The app's freedesktop.org desktop entry (`Packager.md` §4).
public struct DesktopEntry: Equatable {

    public var identifier: String

    public var name: String

    /// The program: a name on `PATH`, or an absolute path.
    public var exec: String

    /// What the program is given before the URL to open: the runner, the
    /// app's identifier.
    public var arguments: [String]

    public var version: String

    /// `Name[locale]`, by POSIX locale (`pt_BR`).
    public var localizedNames: [String: String] = [:]

    /// `MimeType=`: the files the app opens, which a file manager then
    /// offers it for, passing the file as `%u`.
    public var mimeTypes: [String] = []

    public init(identifier: String, name: String, exec: String, arguments: [String] = [], version: String) {
        self.identifier = identifier
        self.name = name
        self.exec = exec
        self.arguments = arguments
        self.version = version
    }

    public var text: String {
        var lines = [
            "[Desktop Entry]",
            "Type=Application",
            "Name=\(Self.escape(name))",
        ]
        lines += localizedNames.sorted { $0.key < $1.key }.map { "Name[\($0.key)]=\(Self.escape($0.value))" }
        lines += [
            "Exec=\(([exec] + arguments).map(Self.quote).joined(separator: " ")) %u",
            "Icon=\(Self.escape(identifier))",
            "Terminal=false",
            "Categories=Utility;",
            "StartupWMClass=\(Self.escape(identifier))",
        ]
        if !mimeTypes.isEmpty {
            lines.append("MimeType=" + mimeTypes.map { Self.escape($0) + ";" }.joined())
        }
        lines += [
            "X-AppRuntime-Identifier=\(Self.escape(identifier))",
            "X-AppRuntime-Version=\(Self.escape(version))",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// A BCP 47 tag as a desktop entry locale: `pt-BR` is `pt_BR`, and
    /// Chinese scripts become their usual regions.
    public static func locale(_ tag: String) -> String {
        switch tag {
        case "zh-Hans": return "zh_CN"
        case "zh-Hant": return "zh_TW"
        default: return tag.replacingOccurrences(of: "-", with: "_")
        }
    }

    /// A string value: backslashes, line breaks and tabs escaped.
    static func escape(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        if escaped.hasPrefix(" ") {
            escaped = "\\s" + escaped.dropFirst()
        }
        return escaped
    }

    /// An `Exec` argument: quoted if it has reserved characters, with `"`,
    /// `` ` ``, `$` and `\` escaped inside the quotes, then escaped as a
    /// string value; `%` doubled.
    static func quote(_ argument: String) -> String {
        let reserved: Set<Character> = [" ", "\t", "\n", "\"", "'", "\\", ">", "<", "~", "|", "&", ";", "$", "*", "?", "#", "(", ")", "`"]
        var value = argument.replacingOccurrences(of: "%", with: "%%")
        if value.contains(where: reserved.contains) {
            var quoted = "\""
            for character in value {
                if "\"`$\\".contains(character) {
                    quoted.append("\\")
                }
                quoted.append(character)
            }
            value = quoted + "\""
        }
        return escape(value)
    }
}
