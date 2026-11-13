/// The app's freedesktop.org desktop entry (`Packager.md` §4).
public struct DesktopEntry: Equatable {

    public var identifier: String

    public var name: String

    /// The program: a name on `PATH`, or an absolute path.
    public var exec: String

    public var version: String

    public init(identifier: String, name: String, exec: String, version: String) {
        self.identifier = identifier
        self.name = name
        self.exec = exec
        self.version = version
    }

    public var text: String {
        """
        [Desktop Entry]
        Type=Application
        Name=\(Self.escape(name))
        Exec=\(Self.quote(exec)) %u
        Icon=\(Self.escape(identifier))
        Terminal=false
        Categories=Utility;
        StartupWMClass=\(Self.escape(identifier))
        X-AppRuntime-Identifier=\(Self.escape(identifier))
        X-AppRuntime-Version=\(Self.escape(version))

        """
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
