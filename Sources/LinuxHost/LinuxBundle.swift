import DynamicRuntime
import Foundation
import RuntimeHost

/// The built-in `Bundle` contract (`AppBundle` in Swift): the app's keys
/// and its localized strings, from the universal bundle's `resources/`
/// (`<language>.lproj/<table>.strings`).
public final class LinuxBundle: AppBundle {

    /// The app's keys. Set before the guest starts.
    nonisolated(unsafe) public static var info = AppInfo(identifier: "", abiVersion: 0)

    /// The bundle's `resources/` directory, if it has one.
    nonisolated(unsafe) public static var resources: String?

    /// The environment the languages come from; replaceable for tests.
    nonisolated(unsafe) public static var environment = ProcessInfo.processInfo.environment

    nonisolated(unsafe) private static var tables: [String: [String: String]] = [:]

    public static func identifier() -> String {
        info.identifier
    }

    public static func version() -> String {
        info.version
    }

    public static func build() -> String {
        info.build
    }

    /// From `LANGUAGE` (a colon-separated list), then `LC_ALL`,
    /// `LC_MESSAGES` and `LANG`, as BCP 47 tags: `pt_BR.UTF-8` is `pt-BR`.
    public static func preferredLanguages() -> [String] {
        var languages: [String] = []
        func add(_ value: String) {
            let tag = languageTag(value)
            if !tag.isEmpty, tag != "C", tag != "POSIX", !languages.contains(tag) {
                languages.append(tag)
            }
        }
        if let list = environment["LANGUAGE"] {
            list.split(separator: ":").forEach { add(String($0)) }
        }
        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let value = environment[key], !value.isEmpty {
                add(value)
                break
            }
        }
        return languages.isEmpty ? ["en"] : languages
    }

    /// `pt_BR.UTF-8@euro` → `pt-BR`.
    static func languageTag(_ locale: String) -> String {
        let base = locale.split(separator: ".", maxSplits: 1).first.map(String.init) ?? locale
        let name = base.split(separator: "@", maxSplits: 1).first.map(String.init) ?? base
        return name.replacingOccurrences(of: "_", with: "-")
    }

    public static func localizedString(_ key: String, table: String?) -> String? {
        let table = table ?? "Localizable"
        for language in preferredLanguages() + ["en", "Base"] {
            for folder in folders(for: language) {
                if let value = strings(folder: folder, table: table)[key] {
                    return value
                }
            }
        }
        return nil
    }

    /// `pt-BR` looks in `pt-BR.lproj`, `pt_BR.lproj` and `pt.lproj`.
    private static func folders(for language: String) -> [String] {
        var folders = [language, language.replacingOccurrences(of: "-", with: "_")]
        if let base = language.split(separator: "-").first, String(base) != language {
            folders.append(String(base))
        }
        return folders
    }

    private static func strings(folder: String, table: String) -> [String: String] {
        guard let resources else { return [:] }
        let path = "\(resources)/\(folder).lproj/\(table).strings"
        if let cached = tables[path] {
            return cached
        }
        var table: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
            table = plist
        }
        tables[path] = table
        return table
    }
}
