import CRuntime
import Crypto
import Foundation
import RuntimeHost
import RuntimeNative

/// An app's Linux slice, loaded: `lib/<target>/libapp.so` from its bundle
/// (AppRuntime's `DynamicRuntime.md` §7.5, §7.6), as the runner loads it
/// (`Plan.md` §4).
///
/// The library names no other library. What it leaves undefined, the
/// runner's process supplies: `rt.h`, which `linux-app-host` exports; a few
/// libc functions; and GLES 2.0, which `preload` puts in the global scope
/// first for an app that draws. It binds every symbol as it loads, so one
/// the process lacks fails the load, by name.
///
/// Before it's loaded, its contents are checked against the bundle's
/// `_CodeSignature/CodeResources`, and the bytes checked are the ones
/// loaded: the file is opened once, hashed, and loaded through its
/// descriptor.
public struct AppLibrary {

    /// The library's path in the bundle.
    public let path: String

    public let entryPoints: AppEntryPoints

    /// Loads the slice for `target` from the bundle at `bundle`.
    ///
    /// `preload` are libraries to load into the global scope first, by
    /// soname, for the symbols the app's library leaves undefined.
    public static func load(
        bundle: String,
        target: LinuxTarget,
        preload: [String] = []
    ) throws(AppLibraryError) -> AppLibrary {
        let relative = target.sharedLibrary
        let path = bundle + "/" + relative
        let expected = try signedDigest(bundle: bundle, file: relative)

        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AppLibraryError("the app has no \(target.rawValue) slice: \(relative): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        guard let contents = read(descriptor) else {
            throw AppLibraryError("can't read \(relative): \(String(cString: strerror(errno)))")
        }
        guard Data(SHA256.hash(data: contents)) == expected else {
            throw AppLibraryError("\(relative) doesn't match the bundle's CodeResources")
        }

        for name in preload {
            guard dlopen(name, RTLD_NOW | RTLD_GLOBAL) != nil else {
                throw AppLibraryError("the app needs \(name): \(lastError())")
            }
        }

        // The descriptor's file is the one hashed, whatever happens to the
        // path meanwhile; the path when /proc isn't mounted.
        let byDescriptor = "/proc/self/fd/\(descriptor)"
        let loadPath = FileManager.default.fileExists(atPath: byDescriptor) ? byDescriptor : path
        guard let handle = dlopen(loadPath, RTLD_NOW | RTLD_LOCAL) else {
            throw AppLibraryError("can't load \(relative): \(lastError())")
        }
        // Never closed: the app runs as long as the process does.
        func symbol(_ name: String) throws(AppLibraryError) -> UnsafeMutableRawPointer {
            guard let address = dlsym(handle, name) else {
                throw AppLibraryError("\(relative) doesn't export \(name)")
            }
            return address
        }
        typealias Main = @convention(c) () -> rt_status
        let main = unsafeBitCast(try symbol("rt_main"), to: Main.self)
        let dispatch = unsafeBitCast(try symbol("rt_dispatch"), to: NativeGuest.EntryPoints.Dispatch.self)
        let finalize = unsafeBitCast(try symbol("rt_finalize"), to: NativeGuest.EntryPoints.Finalize.self)
        return AppLibrary(path: path, entryPoints: AppEntryPoints(main: { main() }, dispatch: dispatch, finalize: finalize))
    }

    /// The SHA-256 that `_CodeSignature/CodeResources` lists for `file`.
    public static func signedDigest(bundle: String, file: String) throws(AppLibraryError) -> Data {
        let manifest = bundle + "/_CodeSignature/CodeResources"
        guard let data = FileManager.default.contents(atPath: manifest) else {
            throw AppLibraryError("the app isn't signed: it has no _CodeSignature/CodeResources")
        }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let files = plist["files"] as? [String: Data] else {
            throw AppLibraryError("_CodeSignature/CodeResources is malformed")
        }
        guard let digest = files[file] else {
            throw AppLibraryError("_CodeSignature/CodeResources doesn't list \(file)")
        }
        return digest
    }

    private static func read(_ descriptor: Int32) -> Data? {
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return (try? file.readToEnd()).map { $0 ?? Data() }
    }

    private static func lastError() -> String {
        dlerror().map { String(cString: $0) } ?? "unknown error"
    }
}

/// Why an app's library can't be loaded.
public struct AppLibraryError: Error, CustomStringConvertible {

    public var description: String

    init(_ description: String) {
        self.description = description
    }
}

public extension LinuxTarget {

    /// The slice's library, as a path in the bundle.
    var sharedLibrary: String {
        "lib/\(rawValue)/libapp.so"
    }
}
