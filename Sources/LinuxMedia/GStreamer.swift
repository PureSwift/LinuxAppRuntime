#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import LinuxHost

/// GStreamer, opened at run time (`Plan.md` §15), as WPE WebKit is.
///
/// Each player is a `playbin`, whose pictures go to an `appsink` as RGBA
/// and whose sound goes to the desktop's sound server. GStreamer decodes
/// and keeps time on its own threads; the host only polls: the pipeline's
/// bus for what happened, and the `appsink` for the latest picture. No
/// GStreamer thread calls into the host. Without GStreamer installed,
/// every load fails with `unavailable`.
final class GStreamer {

    typealias Pointer = UnsafeMutableRawPointer

    typealias CString = UnsafePointer<CChar>

    // MARK: GStreamer

    let elementFactoryMake: @convention(c) (CString, CString?) -> Pointer?
    let elementFactoryFind: @convention(c) (CString) -> Pointer?
    let parseBinFromDescription: @convention(c) (CString, Int32, UnsafeMutablePointer<Pointer?>?) -> Pointer?
    let parseLaunch: @convention(c) (CString, UnsafeMutablePointer<Pointer?>?) -> Pointer?
    let binGetByName: @convention(c) (Pointer, CString) -> Pointer?
    let objectRefSink: @convention(c) (Pointer) -> Pointer?
    let objectUnref: @convention(c) (Pointer) -> Void
    let elementSetState: @convention(c) (Pointer, Int32) -> Int32
    let elementGetBus: @convention(c) (Pointer) -> Pointer?
    let busPop: @convention(c) (Pointer) -> Pointer?
    let miniObjectUnref: @convention(c) (Pointer) -> Void
    let messageParseError: @convention(c) (Pointer, UnsafeMutablePointer<Pointer?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    let messageParseStateChanged: @convention(c) (Pointer, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                                  UnsafeMutablePointer<Int32>?) -> Void
    let messageParseBuffering: @convention(c) (Pointer, UnsafeMutablePointer<Int32>?) -> Void
    let elementSeek: @convention(c) (Pointer, Double, Int32, Int32, Int32, Int64, Int32, Int64) -> Int32
    let elementQueryPosition: @convention(c) (Pointer, Int32, UnsafeMutablePointer<Int64>?) -> Int32
    let elementQueryDuration: @convention(c) (Pointer, Int32, UnsafeMutablePointer<Int64>?) -> Int32
    let elementQuery: @convention(c) (Pointer, Pointer) -> Int32
    let queryNewBuffering: @convention(c) (Int32) -> Pointer?
    let queryParseBufferingRange: @convention(c) (Pointer, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int64>?,
                                                  UnsafeMutablePointer<Int64>?, UnsafeMutablePointer<Int64>?) -> Void
    let filenameToURI: @convention(c) (CString, UnsafeMutablePointer<Pointer?>?) -> UnsafeMutablePointer<CChar>?
    let sampleGetBuffer: @convention(c) (Pointer) -> Pointer?
    let sampleGetCaps: @convention(c) (Pointer) -> Pointer?
    let capsGetStructure: @convention(c) (Pointer, UInt32) -> Pointer?
    let capsFromString: @convention(c) (CString) -> Pointer?
    let structureGetInt: @convention(c) (Pointer, CString, UnsafeMutablePointer<Int32>) -> Int32
    let bufferMap: @convention(c) (Pointer, Pointer, Int32) -> Int32
    let bufferUnmap: @convention(c) (Pointer, Pointer) -> Void
    let factoryListGetElements: @convention(c) (UInt64, Int32) -> Pointer?
    let factoryListFilter: @convention(c) (Pointer?, Pointer, Int32, Int32) -> Pointer?
    let pluginFeatureListFree: @convention(c) (Pointer?) -> Void

    // MARK: The app sink

    let appSinkTryPullSample: @convention(c) (Pointer, UInt64) -> Pointer?
    let appSinkTryPullPreroll: @convention(c) (Pointer, UInt64) -> Pointer?

    // MARK: GLib and GObject

    let valueInit: @convention(c) (Pointer, UInt) -> Pointer?
    let valueUnset: @convention(c) (Pointer) -> Void
    let valueSetDouble: @convention(c) (Pointer, Double) -> Void
    let valueSetBoolean: @convention(c) (Pointer, Int32) -> Void
    let valueSetString: @convention(c) (Pointer, CString?) -> Void
    let valueSetObject: @convention(c) (Pointer, Pointer?) -> Void
    let valueGetInt: @convention(c) (Pointer) -> Int32
    let objectSetProperty: @convention(c) (Pointer, CString, Pointer) -> Void
    let objectGetProperty: @convention(c) (Pointer, CString, Pointer) -> Void
    let free: @convention(c) (Pointer?) -> Void
    let errorFree: @convention(c) (Pointer) -> Void
    let quarkToString: @convention(c) (UInt32) -> CString?

    // MARK: Constants

    /// GstState, and GstStateChangeReturn.
    static let null: Int32 = 1, paused: Int32 = 3, playing: Int32 = 4
    static let changeFailure: Int32 = 0, changeSuccess: Int32 = 1, changeAsync: Int32 = 2, changeNoPreroll: Int32 = 3

    /// GstMessageType.
    static let messageEOS: Int32 = 1, messageError: Int32 = 2, messageBuffering: Int32 = 32,
               messageStateChanged: Int32 = 64, messageAsyncDone: Int32 = 1 << 21

    /// GST_FORMAT_TIME and GST_FORMAT_PERCENT, and GST_FORMAT_PERCENT_MAX.
    static let formatTime: Int32 = 3, formatPercent: Int32 = 4, percentMax: Int64 = 1_000_000

    /// GstSeekFlags: FLUSH and ACCURATE; GstSeekType: NONE and SET.
    static let seekFlushAccurate: Int32 = 1 | 2, seekNone: Int32 = 0, seekSet: Int32 = 1

    /// GstElementFactoryListType: decoders, and what reads a container
    /// (demuxers and parsers); GST_RANK_MARGINAL; GST_PAD_SINK.
    static let decoders: UInt64 = 1, readers: UInt64 = 32 | 64, rankMarginal: Int32 = 64, padSink: Int32 = 2

    /// GST_MAP_READ.
    static let mapRead: Int32 = 1

    /// GLib's fundamental types.
    static let typeBoolean: UInt = 20, typeInt: UInt = 24, typeDouble: UInt = 60, typeString: UInt = 64, typeObject: UInt = 80

    /// `GstMessage`'s `type` and `src`, after its `GstMiniObject`; a
    /// `GstMapInfo`'s `data` and `size`, and its size; `GError`'s
    /// `message`; a `GValue`'s size. Checked against GStreamer 1.26's
    /// headers.
    static let messageTypeOffset = 64, messageSourceOffset = 80
    static let mapInfoSize = 104, mapDataOffset = 16, mapSizeOffset = 24
    static let errorMessageOffset = 8, valueSize = 24

    /// GStreamer, initialized; nil when it isn't installed.
    static let shared: GStreamer? = GStreamer()

    private init?() {
        let names = ["libgstreamer-1.0.so.0", "libgstapp-1.0.so.0", "libgobject-2.0.so.0", "libglib-2.0.so.0"]
        // Local, so GStreamer's libraries never stand in for others of the
        // same names in the process.
        let libraries = names.map { dlopen($0, RTLD_NOW | RTLD_LOCAL) }
        guard let gst = libraries[0], let app = libraries[1], let gobject = libraries[2], let glib = libraries[3] else {
            HostLog.debug("media: GStreamer isn't installed")
            return nil
        }
        var missing: [String] = []
        func bind<T>(_ library: Pointer, _ name: String, _: T.Type) -> T {
            guard let symbol = dlsym(library, name) else {
                missing.append(name)
                return unsafeBitCast(GStreamer.missingFunction, to: T.self)
            }
            return unsafeBitCast(symbol, to: T.self)
        }
        let initCheck = bind(gst, "gst_init_check", (@convention(c) (Pointer?, Pointer?, UnsafeMutablePointer<Pointer?>?) -> Int32).self)
        elementFactoryMake = bind(gst, "gst_element_factory_make", (@convention(c) (CString, CString?) -> Pointer?).self)
        elementFactoryFind = bind(gst, "gst_element_factory_find", (@convention(c) (CString) -> Pointer?).self)
        parseBinFromDescription = bind(gst, "gst_parse_bin_from_description",
                                       (@convention(c) (CString, Int32, UnsafeMutablePointer<Pointer?>?) -> Pointer?).self)
        parseLaunch = bind(gst, "gst_parse_launch", (@convention(c) (CString, UnsafeMutablePointer<Pointer?>?) -> Pointer?).self)
        binGetByName = bind(gst, "gst_bin_get_by_name", (@convention(c) (Pointer, CString) -> Pointer?).self)
        objectRefSink = bind(gst, "gst_object_ref_sink", (@convention(c) (Pointer) -> Pointer?).self)
        objectUnref = bind(gst, "gst_object_unref", (@convention(c) (Pointer) -> Void).self)
        elementSetState = bind(gst, "gst_element_set_state", (@convention(c) (Pointer, Int32) -> Int32).self)
        elementGetBus = bind(gst, "gst_element_get_bus", (@convention(c) (Pointer) -> Pointer?).self)
        busPop = bind(gst, "gst_bus_pop", (@convention(c) (Pointer) -> Pointer?).self)
        miniObjectUnref = bind(gst, "gst_mini_object_unref", (@convention(c) (Pointer) -> Void).self)
        messageParseError = bind(gst, "gst_message_parse_error",
                                 (@convention(c) (Pointer, UnsafeMutablePointer<Pointer?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void).self)
        messageParseStateChanged = bind(gst, "gst_message_parse_state_changed",
                                        (@convention(c) (Pointer, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                                         UnsafeMutablePointer<Int32>?) -> Void).self)
        messageParseBuffering = bind(gst, "gst_message_parse_buffering", (@convention(c) (Pointer, UnsafeMutablePointer<Int32>?) -> Void).self)
        elementSeek = bind(gst, "gst_element_seek", (@convention(c) (Pointer, Double, Int32, Int32, Int32, Int64, Int32, Int64) -> Int32).self)
        elementQueryPosition = bind(gst, "gst_element_query_position", (@convention(c) (Pointer, Int32, UnsafeMutablePointer<Int64>?) -> Int32).self)
        elementQueryDuration = bind(gst, "gst_element_query_duration", (@convention(c) (Pointer, Int32, UnsafeMutablePointer<Int64>?) -> Int32).self)
        elementQuery = bind(gst, "gst_element_query", (@convention(c) (Pointer, Pointer) -> Int32).self)
        queryNewBuffering = bind(gst, "gst_query_new_buffering", (@convention(c) (Int32) -> Pointer?).self)
        queryParseBufferingRange = bind(gst, "gst_query_parse_buffering_range",
                                        (@convention(c) (Pointer, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int64>?,
                                                         UnsafeMutablePointer<Int64>?, UnsafeMutablePointer<Int64>?) -> Void).self)
        filenameToURI = bind(gst, "gst_filename_to_uri", (@convention(c) (CString, UnsafeMutablePointer<Pointer?>?) -> UnsafeMutablePointer<CChar>?).self)
        sampleGetBuffer = bind(gst, "gst_sample_get_buffer", (@convention(c) (Pointer) -> Pointer?).self)
        sampleGetCaps = bind(gst, "gst_sample_get_caps", (@convention(c) (Pointer) -> Pointer?).self)
        capsGetStructure = bind(gst, "gst_caps_get_structure", (@convention(c) (Pointer, UInt32) -> Pointer?).self)
        capsFromString = bind(gst, "gst_caps_from_string", (@convention(c) (CString) -> Pointer?).self)
        structureGetInt = bind(gst, "gst_structure_get_int", (@convention(c) (Pointer, CString, UnsafeMutablePointer<Int32>) -> Int32).self)
        bufferMap = bind(gst, "gst_buffer_map", (@convention(c) (Pointer, Pointer, Int32) -> Int32).self)
        bufferUnmap = bind(gst, "gst_buffer_unmap", (@convention(c) (Pointer, Pointer) -> Void).self)
        factoryListGetElements = bind(gst, "gst_element_factory_list_get_elements", (@convention(c) (UInt64, Int32) -> Pointer?).self)
        factoryListFilter = bind(gst, "gst_element_factory_list_filter", (@convention(c) (Pointer?, Pointer, Int32, Int32) -> Pointer?).self)
        pluginFeatureListFree = bind(gst, "gst_plugin_feature_list_free", (@convention(c) (Pointer?) -> Void).self)
        appSinkTryPullSample = bind(app, "gst_app_sink_try_pull_sample", (@convention(c) (Pointer, UInt64) -> Pointer?).self)
        appSinkTryPullPreroll = bind(app, "gst_app_sink_try_pull_preroll", (@convention(c) (Pointer, UInt64) -> Pointer?).self)
        valueInit = bind(gobject, "g_value_init", (@convention(c) (Pointer, UInt) -> Pointer?).self)
        valueUnset = bind(gobject, "g_value_unset", (@convention(c) (Pointer) -> Void).self)
        valueSetDouble = bind(gobject, "g_value_set_double", (@convention(c) (Pointer, Double) -> Void).self)
        valueSetBoolean = bind(gobject, "g_value_set_boolean", (@convention(c) (Pointer, Int32) -> Void).self)
        valueSetString = bind(gobject, "g_value_set_string", (@convention(c) (Pointer, CString?) -> Void).self)
        valueSetObject = bind(gobject, "g_value_set_object", (@convention(c) (Pointer, Pointer?) -> Void).self)
        valueGetInt = bind(gobject, "g_value_get_int", (@convention(c) (Pointer) -> Int32).self)
        objectSetProperty = bind(gobject, "g_object_set_property", (@convention(c) (Pointer, CString, Pointer) -> Void).self)
        objectGetProperty = bind(gobject, "g_object_get_property", (@convention(c) (Pointer, CString, Pointer) -> Void).self)
        free = bind(glib, "g_free", (@convention(c) (Pointer?) -> Void).self)
        errorFree = bind(glib, "g_error_free", (@convention(c) (Pointer) -> Void).self)
        quarkToString = bind(glib, "g_quark_to_string", (@convention(c) (UInt32) -> CString?).self)
        guard missing.isEmpty else {
            HostLog.error("media: GStreamer lacks \(missing.joined(separator: ", "))")
            return nil
        }
        var error: Pointer?
        guard initCheck(nil, nil, &error) != 0 else {
            HostLog.error("media: GStreamer didn't start: \(error.map { Self.message(of: $0) } ?? "no reason")")
            return nil
        }
    }

    private static let missingFunction: @convention(c) () -> Void = { }

    /// A `GError`'s message.
    static func message(of error: Pointer) -> String {
        error.load(fromByteOffset: errorMessageOffset, as: UnsafePointer<CChar>?.self).map { String(cString: $0) } ?? ""
    }

    // MARK: Properties

    func set(_ object: Pointer, _ name: String, double value: Double) {
        withValue(Self.typeDouble, { valueSetDouble($0, value) }) { objectSetProperty(object, name, $0) }
    }

    func set(_ object: Pointer, _ name: String, bool value: Bool) {
        withValue(Self.typeBoolean, { valueSetBoolean($0, value ? 1 : 0) }) { objectSetProperty(object, name, $0) }
    }

    func set(_ object: Pointer, _ name: String, string value: String?) {
        withValue(Self.typeString, { pointer in
            if let value {
                value.withCString { valueSetString(pointer, $0) }
            } else {
                valueSetString(pointer, nil)
            }
        }) { objectSetProperty(object, name, $0) }
    }

    func set(_ object: Pointer, _ name: String, object value: Pointer?) {
        withValue(Self.typeObject, { valueSetObject($0, value) }) { objectSetProperty(object, name, $0) }
    }

    func int(_ object: Pointer, _ name: String) -> Int32 {
        var result: Int32 = 0
        withValue(Self.typeInt, { objectGetProperty(object, name, $0) }) { result = valueGetInt($0) }
        return result
    }

    /// A `GValue` of `type`, zeroed as `G_VALUE_INIT`, filled and used,
    /// then unset.
    private func withValue(_ type: UInt, _ fill: (Pointer) -> Void, _ use: (Pointer) -> Void) {
        let value = Pointer.allocate(byteCount: Self.valueSize, alignment: 8)
        value.initializeMemory(as: UInt8.self, repeating: 0, count: Self.valueSize)
        defer { value.deallocate() }
        _ = valueInit(value, type)
        fill(value)
        use(value)
        valueUnset(value)
    }

    // MARK: Messages

    /// A message's `GstMessageType`, and the object that posted it.
    func type(of message: Pointer) -> Int32 {
        message.load(fromByteOffset: Self.messageTypeOffset, as: Int32.self)
    }

    func source(of message: Pointer) -> Pointer? {
        message.load(fromByteOffset: Self.messageSourceOffset, as: Pointer?.self)
    }

    /// An error message's `GError`: its domain's name, its code and its
    /// text.
    func error(in message: Pointer) -> (domain: String, code: Int32, message: String) {
        var error: Pointer?
        var debug: UnsafeMutablePointer<CChar>?
        messageParseError(message, &error, &debug)
        free(debug)
        guard let error else { return ("", 0, "") }
        let domain = quarkToString(error.load(as: UInt32.self)).map { String(cString: $0) } ?? ""
        let code = error.load(fromByteOffset: 4, as: Int32.self)
        let text = Self.message(of: error)
        errorFree(error)
        return (domain, code, text)
    }

    // MARK: The registry

    /// Whether an element of `kinds` takes `caps` on its sink pad.
    func hasElement(_ kinds: UInt64, accepting caps: String) -> Bool {
        guard let parsed = capsFromString(caps) else { return false }
        defer { miniObjectUnref(parsed) }
        let all = factoryListGetElements(kinds, Self.rankMarginal)
        defer { pluginFeatureListFree(all) }
        let matching = factoryListFilter(all, parsed, Self.padSink, 0)
        defer { pluginFeatureListFree(matching) }
        return matching != nil
    }

    /// Whether GStreamer has an element called `name`.
    func hasFactory(_ name: String) -> Bool {
        guard let factory = elementFactoryFind(name) else { return false }
        objectUnref(factory)
        return true
    }
}
