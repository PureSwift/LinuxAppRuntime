import DynamicDocuments
import DynamicFiles
import Foundation
import LinuxHost
import RuntimeDocuments
import RuntimeHost

/// The documents an app remembers: a property list of bookmarks, each a
/// random UUID naming a path, beside the app's `Documents` and `Data` and
/// out of reach of its `Files`.
///
/// | In a container | Otherwise, XDG's |
/// |---|---|
/// | `<container>/Bookmarks` | `$XDG_DATA_HOME/<id>/Bookmarks` |
///
/// A path is all a bookmark needs on Linux: the host's process can open
/// any path the user can, and a Flatpak's document portal keeps the paths
/// it gave. A document asked for again is given the same bookmark. Main
/// loop only.
public final class BookmarkStore {

    struct Entry: Codable, Equatable {
        var path: String
        var isDirectory: Bool
        var isWritable: Bool
    }

    /// The property list; `nil` when the app's directories couldn't be
    /// decided, and nothing can be remembered.
    public let file: String?

    private var loaded: [String: Entry]?

    public init(file: String?) {
        self.file = file
    }

    /// The store of the app `identifier`.
    public convenience init(identifier: String, environment: [String: String]) {
        self.init(file: Self.file(identifier: identifier, environment: environment))
    }

    /// Where the app `identifier`'s bookmarks are kept: beside its
    /// documents.
    public static func file(identifier: String, environment: [String: String]) -> String? {
        do throws(LinuxFilesError) {
            let directories = try LinuxFiles.directories(identifier: identifier, resources: nil, environment: environment)
            // `documents` is always there; it's `<base>/Documents`.
            let documents = directories[.documents]!
            return String(documents.dropLast("/Documents".count)) + "/Bookmarks"
        } catch {
            HostLog.error("documents: can't keep bookmarks: \(error)")
            return nil
        }
    }

    // MARK: Bookmarks

    /// Remembers `document`, and answers with its bookmark.
    func add(_ document: HostDocument) -> Result<String, DocumentError> {
        guard file != nil else { return .failure(.unsupported) }
        var entries = self.entries
        let entry = Entry(path: document.path, isDirectory: document.kind == .directory, isWritable: document.isWritable)
        if let existing = entries.first(where: { $0.value == entry })?.key {
            return .success(existing)
        }
        let bookmark = UUID().uuidString
        entries[bookmark] = entry
        guard save(entries) else { return .failure(.unknown) }
        return .success(bookmark)
    }

    /// The document `bookmark` names: `notFound` once its file is gone or
    /// it's forgotten.
    func document(for bookmark: String) -> Result<HostDocument, DocumentError> {
        guard let entry = entries[bookmark] else { return .failure(.notFound) }
        let kind: FileKind = entry.isDirectory ? .directory : .file
        guard HostFiles.kind(ofItemAt: entry.path) == kind else { return .failure(.notFound) }
        // Written to only while the user still may.
        let writable = entry.isWritable && LinuxDocumentPresenter.isWritable(entry.path)
        return .success(HostDocument(path: entry.path, kind: kind, isWritable: writable))
    }

    func remove(_ bookmark: String) {
        var entries = self.entries
        guard entries.removeValue(forKey: bookmark) != nil else { return }
        _ = save(entries)
    }

    // MARK: The file

    private var entries: [String: Entry] {
        if let loaded {
            return loaded
        }
        var entries: [String: Entry] = [:]
        if let file, let data = FileManager.default.contents(atPath: file) {
            do {
                entries = try PropertyListDecoder().decode([String: Entry].self, from: data)
            } catch {
                HostLog.error("documents: can't read the bookmarks in \(file): \(error)")
            }
        }
        loaded = entries
        return entries
    }

    private func save(_ entries: [String: Entry]) -> Bool {
        guard let file else { return false }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let data = try encoder.encode(entries)
            try HostFiles.replace(file: file, with: [UInt8](data))
        } catch {
            HostLog.error("documents: can't keep the bookmarks in \(file): \(error)")
            return false
        }
        loaded = entries
        return true
    }
}
