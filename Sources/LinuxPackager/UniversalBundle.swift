import Crypto
import Foundation
import LinuxHost

/// A universal bundle from AppRuntime's `guest.py bundle`: `Info.plist`,
/// `lib/<target>/libapp.so` for each Linux target, `wasm32/App.wasm`,
/// `_CodeSignature/CodeResources`, and optionally `resources/` and
/// `icon.png` (`Packager.md` §1).
public struct UniversalBundle {

    public let url: URL

    public let info: AppInfo

    /// `CFBundleExecutable`: the program's name.
    public let executable: String

    /// `CFBundleDisplayName`, `CFBundleName`, or the executable.
    public let displayName: String

    /// The name in each of `CFBundleLocalizations`, by desktop locale, from
    /// `resources/<language>.lproj/Manifest.strings` at `RTDisplayNameKey`
    /// (AppRuntime's manifest stage writes both).
    public let localizedDisplayNames: [String: String]

    /// The MIME types of `RTDocumentTypes` (AppRuntime's `documentTypes`),
    /// in order: what the desktop entry's `MimeType=` can say. Groups such
    /// as `image/*` and extensions aren't MIME types, and are left out.
    public let documentMimeTypes: [String]

    public init(url: URL) throws(PackagerError) {
        self.url = url.standardizedFileURL
        let plist = url.appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path) else {
            throw PackagerError("\(url.path) is not a universal bundle: it has no Info.plist")
        }
        guard let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw PackagerError("\(plist.path) is not a property list")
        }
        do {
            info = try AppInfo(infoDictionary: dictionary)
        } catch {
            throw PackagerError("\(plist.path): \(error)")
        }
        executable = dictionary["CFBundleExecutable"] as? String ?? ""
        var names: [String: String] = [:]
        if let key = dictionary["RTDisplayNameKey"] as? String {
            for language in dictionary["CFBundleLocalizations"] as? [String] ?? [] {
                let table = url.appendingPathComponent("resources/\(language).lproj/Manifest.strings")
                guard let data = FileManager.default.contents(atPath: table.path),
                      let strings = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String],
                      let name = strings[key] else { continue }
                names[DesktopEntry.locale(language)] = name
            }
        }
        localizedDisplayNames = names
        var mimeTypes: [String] = []
        for documentType in dictionary["RTDocumentTypes"] as? [[String: Any]] ?? [] {
            for type in documentType["Types"] as? [String] ?? [] where Self.isMimeType(type) && !mimeTypes.contains(type) {
                mimeTypes.append(type)
            }
        }
        documentMimeTypes = mimeTypes
        displayName = dictionary["CFBundleDisplayName"] as? String
            ?? dictionary["CFBundleName"] as? String
            ?? executable
    }

    /// `type/subtype`, with no wildcard and nothing a desktop entry's list
    /// would split.
    static func isMimeType(_ type: String) -> Bool {
        let parts = type.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0 != "*" }
            && !type.contains(where: { $0 == ";" || $0.isWhitespace || $0 == "\\" })
    }

    /// The target's slice, the `libapp.so` the runner loads, if the bundle
    /// has one.
    public func slice(_ target: LinuxTarget) -> URL? {
        existing(target.sharedLibrary)
    }

    public var wasm: URL? {
        existing("wasm32/App.wasm")
    }

    public var icon: URL? {
        existing("icon.png")
    }

    public var resources: URL? {
        existing("resources")
    }

    private func existing(_ path: String) -> URL? {
        let url = url.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Integrity

    /// Files whose contents don't match `_CodeSignature/CodeResources`,
    /// files it lists that are missing, and files it doesn't list. Empty
    /// for a bundle without one.
    public func codeResourceProblems() -> [String] {
        let manifest = url.appendingPathComponent("_CodeSignature/CodeResources")
        guard let data = FileManager.default.contents(atPath: manifest.path) else {
            return []
        }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let files = plist["files"] as? [String: Data] else {
            return ["_CodeSignature/CodeResources is malformed"]
        }
        var problems: [String] = []
        var listed = Set<String>()
        for (path, digest) in files.sorted(by: { $0.key < $1.key }) {
            listed.insert(path)
            guard let contents = FileManager.default.contents(atPath: url.appendingPathComponent(path).path) else {
                problems.append("\(path) is missing")
                continue
            }
            if Data(SHA256.hash(data: contents)) != digest {
                problems.append("\(path) was modified")
            }
        }
        for path in allFiles(under: url) where !listed.contains(path) && !path.hasPrefix("_CodeSignature/") {
            problems.append("\(path) was added")
        }
        return problems
    }

    /// Every regular file, as a path relative to `root`.
    func allFiles(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        var files: [String] = []
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            files.append(String(path.dropFirst(base.count + 1)))
        }
        return files.sorted()
    }
}
