import DBus
import Dispatch
import DynamicDocuments
import DynamicFiles
import Foundation
import LinuxDBus
import LinuxHost
import RuntimeDocuments
import RuntimeHost

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The `Documents` contract's pickers on Linux (`Plan.md` §12): the desktop
/// portal's file chooser on the session bus, which the desktop's own
/// backend shows (GNOME's, KDE's, wlroots'), outside the app. Main loop
/// only.
///
/// - **Open** and **folder** are `OpenFile`, the folder with `directory`
///   (file chooser version 3).
/// - **Save** is `SaveFile`: the portal says where, and the host copies
///   the file there, off the main loop.
/// - **What's picked** is a path the host's process can open: the file's
///   own, or, in a Flatpak, the document portal's.
/// - **Bookmarks** are the host's own (`BookmarkStore`), since a path
///   outlives the pick.
/// - **Without a portal**, every picker fails with `unsupported`.
public final class LinuxDocumentPresenter: DocumentPresenter {

    let chooser: PortalFileChooser

    let bookmarks: BookmarkStore

    /// Runs the copy of a save; replaceable for tests.
    var copyQueue = DispatchQueue(label: "linux-documents.export")

    public init(bus: any PortalBus = SessionPortal(), bookmarks: BookmarkStore) {
        self.chooser = PortalFileChooser(bus: bus)
        self.bookmarks = bookmarks
    }

    /// The app's window, as the portal names a parent (`x11:<XID>`); empty
    /// for none, which shows the picker as a window of its own.
    public var parentWindow: String {
        get { chooser.parentWindow }
        set { chooser.parentWindow = newValue }
    }

    // MARK: Pickers

    public func pick(types: [String], multiple: Bool, access: DocumentAccess,
                     completion: @escaping (Result<[HostDocument], DocumentError>) -> Void) {
        var options: [String: DBusMessageArgument] = ["modal": .boolean(true), "multiple": .boolean(multiple)]
        if let filter = Self.filter(types) {
            options["filters"] = .list(of: filter.type, [filter])
            options["current_filter"] = filter
        }
        chooser.request("OpenFile", title: "Open", options: options) { answer in
            completion(Self.documents(answer, kind: .file, access: access))
        }
    }

    public func pickFolder(access: DocumentAccess, completion: @escaping (Result<HostDocument?, DocumentError>) -> Void) {
        chooser.fileChooserVersion { [chooser] version in
            switch version {
            case .failure(let error):
                completion(.failure(Self.error(error)))
            case .success(let version) where version < 3:
                HostLog.error("documents: the desktop portal's file chooser is version \(version); a folder needs 3")
                completion(.failure(.unsupported))
            case .success:
                let options: [String: DBusMessageArgument] = ["modal": .boolean(true), "directory": .boolean(true)]
                chooser.request("OpenFile", title: "Choose a Folder", options: options) { answer in
                    completion(Self.documents(answer, kind: .directory, access: access).map(\.first))
                }
            }
        }
    }

    public func export(file source: String, name: String, completion: @escaping (Result<HostDocumentExport, DocumentError>) -> Void) {
        let options: [String: DBusMessageArgument] = ["modal": .boolean(true), "current_name": .string(name)]
        chooser.request("SaveFile", title: "Save", options: options) { [copyQueue] answer in
            let destination: String
            switch Self.paths(answer) {
            case .failure(let error):
                completion(.failure(error))
                return
            case .success(let paths):
                guard let path = paths.first else {
                    completion(.success(.cancelled))
                    return
                }
                destination = path
            }
            // The portal asked about replacing a file already there.
            let held = MainThreadHeld(completion)
            copyQueue.async {
                let copied: Result<Void, FileError>
                do throws(FileError) {
                    try HostFiles.copy(file: source, to: destination)
                    copied = .success(())
                } catch {
                    copied = .failure(error)
                }
                MainLoop.shared.post {
                    guard let completion = held.take() else { return }
                    switch copied {
                    case .success:
                        completion(.success(.saved(HostDocument(path: destination, isWritable: true))))
                    case .failure(let error):
                        HostLog.error("documents: can't save to \(destination): \(error)")
                        completion(.failure(error == .notPermitted ? .notPermitted : .unknown))
                    }
                }
            }
        }
    }

    // MARK: Bookmarks

    public func bookmark(_ document: HostDocument, completion: @escaping (Result<String, DocumentError>) -> Void) {
        completion(bookmarks.add(document))
    }

    public func resolve(_ bookmark: String, completion: @escaping (Result<HostDocument, DocumentError>) -> Void) {
        completion(bookmarks.document(for: bookmark))
    }

    public func forget(_ bookmark: String) {
        bookmarks.remove(bookmark)
    }

    // MARK: Values

    /// The filter for `types`: MIME types and groups as they are, and an
    /// extension as a glob; `nil` for any file.
    static func filter(_ types: [String]) -> DBusMessageArgument? {
        var patterns: [DBusMessageArgument] = []
        for type in types {
            if type == "*/*" {
                return nil
            } else if type.hasPrefix("."), type.count > 1 {
                patterns.append(.structure([.uint32(Portal.Pattern.glob.rawValue), .string("*" + type)]))
            } else if type.contains("/") {
                patterns.append(.structure([.uint32(Portal.Pattern.mimeType.rawValue), .string(type)]))
            }
        }
        guard let first = patterns.first else { return nil }
        return .structure([.string("Supported files"), .list(of: first.type, patterns)])
    }

    /// The paths a response gave; none if the user cancelled.
    static func paths(_ answer: PortalFileChooser.Answer) -> Result<[String], DocumentError> {
        switch answer {
        case .failure(let error):
            return .failure(Self.error(error))
        case .success((.cancelled, _)):
            return .success([])
        case .success((.ended, _)):
            HostLog.error("documents: the file chooser ended without an answer")
            return .failure(.unknown)
        case .success((.success, let results)):
            let uris = results["uris"]?.elements?.compactMap(\.text) ?? []
            return .success(uris.compactMap(Self.path))
        }
    }

    static func documents(_ answer: PortalFileChooser.Answer, kind: FileKind, access: DocumentAccess) -> Result<[HostDocument], DocumentError> {
        paths(answer).map { paths in
            paths.map { path in
                HostDocument(path: path, kind: kind, isWritable: access == .readWrite && isWritable(path))
            }
        }
    }

    /// A `file:` URI's path; `nil` for any other.
    static func path(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else {
            HostLog.error("documents: the file chooser gave \(uri), which isn't a file")
            return nil
        }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    static func isWritable(_ path: String) -> Bool {
        access(path, W_OK) == 0
    }

    static func error(_ error: BusError) -> DocumentError {
        if error.isServiceMissing {
            HostLog.error("documents: no desktop portal: \(error)")
            return .unsupported
        }
        HostLog.error("documents: the file chooser failed: \(error)")
        return .unknown
    }
}
