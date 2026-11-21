import DBus
import Dispatch
import DynamicDocuments
import DynamicFiles
import Foundation
import LinuxDBus
import LinuxHost
import RuntimeDocuments
import RuntimeHost
import Testing
@testable import LinuxDocuments

/// The pickers against a fake portal, and bookmarks in real files.
@Suite(.serialized)
struct LinuxDocumentsTests {

    let portal = FakePortal()

    let directory: String

    let presenter: LinuxDocumentPresenter

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("documents-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        presenter = LinuxDocumentPresenter(bus: portal, bookmarks: BookmarkStore(file: directory + "/Bookmarks"))
    }

    /// A file of the test's own, and its `file:` URI.
    func file(_ name: String, _ contents: String = "text") throws -> (path: String, uri: String) {
        let path = directory + "/" + name
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return (path, URL(fileURLWithPath: path).absoluteString)
    }

    /// Runs the main loop until `answer` has a value, or a few seconds pass.
    func wait<T>(_ answer: Box<T>) -> T? {
        let timedOut = Box<Bool>()
        let timer = MainLoop.shared.schedule(after: 5_000_000_000) { timedOut.value = true }
        MainLoop.shared.run { answer.value != nil || timedOut.value != nil }
        MainLoop.shared.cancel(timer)
        return answer.value
    }

    final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    /// A filter's name and its patterns.
    func filter(_ argument: DBusMessageArgument?) -> (name: String, patterns: [String])? {
        guard let fields = argument?.fields, fields.count == 2, let name = fields[0].text else { return nil }
        let patterns = fields[1].elements?.compactMap { pattern -> String? in
            guard let fields = pattern.fields, let kind = fields.first?.int64Value, let value = fields.last?.text else { return nil }
            return "\(kind):\(value)"
        }
        return patterns.map { (name, $0) }
    }

    // MARK: Opening

    @Test func opensFiles() throws {
        let a = try file("a b.txt")
        let b = try file("b.txt")
        let picked = Box<Result<[HostDocument], DocumentError>>()
        presenter.pick(types: [".txt", "text/plain", "image/*"], multiple: true, access: .readWrite) { picked.value = $0 }
        MainLoop.shared.drain()

        let call = try #require(portal.calls.last)
        #expect(call.method == "OpenFile")
        #expect(call.parentWindow == "")
        #expect(call.options["multiple"]?.flag == true)
        #expect(call.options["modal"]?.flag == true)
        #expect(call.token?.isEmpty == false)
        let filters = call.options["filters"]?.elements ?? []
        #expect(filters.count == 1)
        let first = try #require(filter(filters.first))
        #expect(first.patterns == ["0:*.txt", "1:text/plain", "1:image/*"])
        #expect(filter(call.options["current_filter"])?.patterns == first.patterns)

        portal.respond(.success, uris: [a.uri, b.uri])
        let documents = try #require(wait(picked)).get()
        #expect(documents.map(\.path) == [a.path, b.path])
        #expect(documents.map(\.displayName) == ["a b.txt", "b.txt"])
        #expect(documents.allSatisfy { $0.kind == .file && $0.isWritable })
    }

    @Test func readOnlyUnlessAskedForWriting() throws {
        let a = try file("a.txt")
        let picked = Box<Result<[HostDocument], DocumentError>>()
        presenter.pick(types: [], multiple: false, access: .read) { picked.value = $0 }
        MainLoop.shared.drain()
        #expect(portal.calls.last?.options["filters"] == nil, "no types is any file")
        #expect(portal.calls.last?.options["multiple"]?.flag == false)
        portal.respond(.success, uris: [a.uri])
        #expect(try #require(wait(picked)).get().map(\.isWritable) == [false])
    }

    @Test func anyFileHasNoFilter() {
        #expect(LinuxDocumentPresenter.filter(["*/*", ".txt"]) == nil)
        #expect(LinuxDocumentPresenter.filter(["."]) == nil)
        #expect(LinuxDocumentPresenter.filter([]) == nil)
    }

    @Test func cancelling() throws {
        let picked = Box<Result<[HostDocument], DocumentError>>()
        presenter.pick(types: [], multiple: true, access: .read) { picked.value = $0 }
        MainLoop.shared.drain()
        portal.respond(.cancelled)
        #expect(try #require(wait(picked)).get().isEmpty)
    }

    @Test func endedOtherwise() throws {
        let picked = Box<Result<[HostDocument], DocumentError>>()
        presenter.pick(types: [], multiple: true, access: .read) { picked.value = $0 }
        MainLoop.shared.drain()
        portal.respond(.ended)
        #expect(throws: DocumentError.unknown) { try #require(wait(picked)).get() }
    }

    @Test func notAFile() throws {
        let a = try file("a.txt")
        let picked = Box<Result<[HostDocument], DocumentError>>()
        presenter.pick(types: [], multiple: true, access: .read) { picked.value = $0 }
        MainLoop.shared.drain()
        portal.respond(.success, uris: ["https://example.com/a.txt", a.uri])
        #expect(try #require(wait(picked)).get().map(\.path) == [a.path])
    }

    @Test func withoutAPortal() throws {
        portal.error = BusError(name: "org.freedesktop.DBus.Error.ServiceUnknown")
        let picked = Box<Result<[HostDocument], DocumentError>>()
        presenter.pick(types: [], multiple: false, access: .read) { picked.value = $0 }
        #expect(throws: DocumentError.unsupported) { try #require(wait(picked)).get() }

        let folder = Box<Result<HostDocument?, DocumentError>>()
        presenter.pickFolder(access: .read) { folder.value = $0 }
        #expect(throws: DocumentError.unsupported) { try #require(wait(folder)).get() }
    }

    @Test func aPortalThatNamesItsRequests() throws {
        portal.ignoresTokens = true
        let a = try file("a.txt")
        let picked = Box<Result<[HostDocument], DocumentError>>()
        presenter.pick(types: [], multiple: false, access: .read) { picked.value = $0 }
        MainLoop.shared.drain()
        #expect(portal.requests.last?.hasSuffix("/\(portal.calls.last?.token ?? "")") == false)
        portal.respond(.success, uris: [a.uri])
        #expect(try #require(wait(picked)).get().map(\.path) == [a.path])
    }

    @Test func theBusClosing() throws {
        let picked = Box<Result<[HostDocument], DocumentError>>()
        presenter.pick(types: [], multiple: false, access: .read) { picked.value = $0 }
        MainLoop.shared.drain()
        portal.disconnect()
        #expect(throws: DocumentError.unsupported) { try #require(wait(picked)).get() }
    }

    @Test func eachRequestHasItsOwnToken() throws {
        let a = try file("a.txt")
        let first = Box<Result<[HostDocument], DocumentError>>()
        presenter.pick(types: [], multiple: false, access: .read) { first.value = $0 }
        MainLoop.shared.drain()
        portal.respond(.cancelled)
        #expect(try #require(wait(first)).get().isEmpty)
        let second = Box<Result<[HostDocument], DocumentError>>()
        presenter.pick(types: [], multiple: false, access: .read) { second.value = $0 }
        MainLoop.shared.drain()
        #expect(portal.calls.count == 2)
        #expect(portal.calls[0].token != portal.calls[1].token)
        portal.respond(.success, uris: [a.uri])
        #expect(try #require(wait(second)).get().map(\.path) == [a.path])
    }

    // MARK: Folders

    @Test func opensAFolder() throws {
        let folder = directory + "/Music"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let picked = Box<Result<HostDocument?, DocumentError>>()
        presenter.pickFolder(access: .readWrite) { picked.value = $0 }
        MainLoop.shared.drain()
        let call = try #require(portal.calls.last)
        #expect(call.method == "OpenFile")
        #expect(call.options["directory"]?.flag == true)
        portal.respond(.success, uris: [URL(fileURLWithPath: folder).absoluteString])
        let answer = try #require(wait(picked))
        let document = try #require(try answer.get())
        #expect(document.path == folder)
        #expect(document.kind == .directory)
        #expect(document.isWritable)
    }

    @Test func anOlderPortalHasNoFolders() throws {
        portal.version = 2
        let picked = Box<Result<HostDocument?, DocumentError>>()
        presenter.pickFolder(access: .read) { picked.value = $0 }
        #expect(throws: DocumentError.unsupported) { try #require(wait(picked)).get() }
        #expect(portal.calls.isEmpty)
    }

    // MARK: Saving

    @Test func savesWhereTheUserSays() throws {
        let source = try file("notes.txt", "my notes")
        let destination = directory + "/Saved notes.txt"
        try "old".write(toFile: destination, atomically: true, encoding: .utf8)
        let saved = Box<Result<HostDocumentExport, DocumentError>>()
        presenter.export(file: source.path, name: "notes.txt") { saved.value = $0 }
        MainLoop.shared.drain()
        let call = try #require(portal.calls.last)
        #expect(call.method == "SaveFile")
        #expect(call.options["current_name"]?.text == "notes.txt")
        portal.respond(.success, uris: [URL(fileURLWithPath: destination).absoluteString])
        guard case .success(.saved(let document)) = try #require(wait(saved)) else {
            Issue.record("not saved")
            return
        }
        #expect(document.path == destination)
        #expect(document.isWritable)
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "my notes")
    }

    @Test func savingCancelled() throws {
        let source = try file("notes.txt")
        let saved = Box<Result<HostDocumentExport, DocumentError>>()
        presenter.export(file: source.path, name: "notes.txt") { saved.value = $0 }
        MainLoop.shared.drain()
        portal.respond(.cancelled)
        guard case .success(.cancelled) = try #require(wait(saved)) else {
            Issue.record("not cancelled")
            return
        }
    }

    @Test func savingWhereItCantBeWritten() throws {
        let source = try file("notes.txt")
        let saved = Box<Result<HostDocumentExport, DocumentError>>()
        presenter.export(file: source.path, name: "notes.txt") { saved.value = $0 }
        MainLoop.shared.drain()
        portal.respond(.success, uris: ["file:///nonexistent-\(UUID().uuidString)/notes.txt"])
        guard case .failure = try #require(wait(saved)) else {
            Issue.record("saved")
            return
        }
    }

    // MARK: Bookmarks

    @Test func bookmarks() throws {
        let a = try file("a.txt")
        let document = HostDocument(path: a.path, isWritable: true)
        let bookmark = try presenter.bookmarks.add(document).get()
        #expect(try presenter.bookmarks.add(document).get() == bookmark, "the same document, the same bookmark")
        #expect(try presenter.bookmarks.add(HostDocument(path: a.path)).get() != bookmark, "read-only is another")

        let resolved = try presenter.bookmarks.document(for: bookmark).get()
        #expect(resolved.path == a.path)
        #expect(resolved.kind == .file)
        #expect(resolved.isWritable)

        // Kept between launches.
        let again = BookmarkStore(file: directory + "/Bookmarks")
        #expect(try again.document(for: bookmark).get().path == a.path)

        again.remove(bookmark)
        #expect(throws: DocumentError.notFound) { try again.document(for: bookmark).get() }
        #expect(throws: DocumentError.notFound) { try BookmarkStore(file: directory + "/Bookmarks").document(for: bookmark).get() }
    }

    @Test func aBookmarksFileGone() throws {
        let a = try file("a.txt")
        let bookmark = try presenter.bookmarks.add(HostDocument(path: a.path)).get()
        try FileManager.default.removeItem(atPath: a.path)
        #expect(throws: DocumentError.notFound) { try presenter.bookmarks.document(for: bookmark).get() }
        #expect(throws: DocumentError.notFound) { try presenter.bookmarks.document(for: "not a bookmark").get() }
    }

    @Test func aFolderReplacedByAFileIsGone() throws {
        let folder = directory + "/Music"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let bookmark = try presenter.bookmarks.add(HostDocument(path: folder, kind: .directory)).get()
        #expect(try presenter.bookmarks.document(for: bookmark).get().kind == .directory)
        try FileManager.default.removeItem(atPath: folder)
        try "x".write(toFile: folder, atomically: true, encoding: .utf8)
        #expect(throws: DocumentError.notFound) { try presenter.bookmarks.document(for: bookmark).get() }
    }

    @Test func noPlaceForBookmarks() {
        let store = BookmarkStore(file: nil)
        #expect(throws: DocumentError.unsupported) { try store.add(HostDocument(path: "/etc/hostname")).get() }
        #expect(BookmarkStore.file(identifier: "org.example.App", environment: [:]) == nil)
    }

    @Test func whereBookmarksAre() {
        #expect(BookmarkStore.file(identifier: "org.example.App", environment: ["LINUXAPPRUNTIME_CONTAINER": "/data"]) == "/data/Bookmarks")
        #expect(BookmarkStore.file(identifier: "org.example.App", environment: ["HOME": "/home/me"])
                == "/home/me/.local/share/org.example.App/Bookmarks")
        #expect(BookmarkStore.file(identifier: "org.example.App", environment: ["HOME": "/home/me", "XDG_DATA_HOME": "/xdg"])
                == "/xdg/org.example.App/Bookmarks")
    }

    // MARK: Opened with

    @Test func filesTheAppIsOpenedWith() {
        #expect(LinuxDocuments.documentPath("/home/me/a b.txt") == "/home/me/a b.txt")
        #expect(LinuxDocuments.documentPath("file:///home/me/a%20b.txt") == "/home/me/a b.txt")
        #expect(LinuxDocuments.documentPath("FILE:///home/me/a.txt") == "/home/me/a.txt")
        #expect(LinuxDocuments.documentPath("https://example.com/a.txt") == nil)
        #expect(LinuxDocuments.documentPath("example://open") == nil)
        #expect(LinuxDocuments.documentPath("a.txt") == nil)
    }

    @Test func theModulesContracts() {
        #expect(LinuxDocuments.contracts.map(\.name) == [
            "org.pureswift.documents.Documents", "org.pureswift.documents.Grant",
            "org.pureswift.documents.Callback", "org.pureswift.documents.Delegate",
        ])
        #expect(LinuxDocuments.permissionProviders().keys.map(\.rawValue) == ["userFiles"])
    }
}
