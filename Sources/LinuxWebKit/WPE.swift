#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import LinuxHost

/// WPE WebKit, WebKit's port for embedding, opened at run time
/// (`Plan.md` §8), as Perry does.
///
/// Each page is a `WebKitWebView` over a view backend from WPEBackend-fdo
/// in its shared-memory mode, which hands every frame the web process draws
/// to the host as a `wl_shm` buffer: no GL. Pages run in WPE's web and
/// network processes, and their signals and replies come through GLib's
/// main context, which the main loop runs while there are pages. Without
/// WPE installed, `WebContent` is unavailable.
final class WPE {

    typealias Pointer = UnsafeMutableRawPointer

    // MARK: libwpe and WPEBackend-fdo

    let viewBackendAddActivityState: @convention(c) (Pointer, UInt32) -> Void
    let viewBackendRemoveActivityState: @convention(c) (Pointer, UInt32) -> Void
    let viewBackendDispatchSetSize: @convention(c) (Pointer, UInt32, UInt32) -> Void
    let viewBackendDispatchSetDeviceScaleFactor: @convention(c) (Pointer, Float) -> Void
    let viewBackendDispatchPointerEvent: @convention(c) (Pointer, UnsafeMutableRawPointer) -> Void
    let viewBackendDispatchAxisEvent: @convention(c) (Pointer, UnsafeMutableRawPointer) -> Void
    let viewBackendDispatchKeyboardEvent: @convention(c) (Pointer, UnsafeMutableRawPointer) -> Void
    let exportableCreate: @convention(c) (UnsafeRawPointer, Pointer?, UInt32, UInt32) -> Pointer?
    let exportableDestroy: @convention(c) (Pointer) -> Void
    let exportableGetViewBackend: @convention(c) (Pointer) -> Pointer?
    let exportableFrameComplete: @convention(c) (Pointer) -> Void
    let exportableReleaseShmBuffer: @convention(c) (Pointer, Pointer) -> Void
    let shmExportedBufferGetShmBuffer: @convention(c) (Pointer) -> Pointer?

    // MARK: libwayland-server's shared-memory buffers

    let shmBufferGetData: @convention(c) (Pointer) -> Pointer?
    let shmBufferGetWidth: @convention(c) (Pointer) -> Int32
    let shmBufferGetHeight: @convention(c) (Pointer) -> Int32
    let shmBufferGetStride: @convention(c) (Pointer) -> Int32
    let shmBufferBeginAccess: @convention(c) (Pointer) -> Void
    let shmBufferEndAccess: @convention(c) (Pointer) -> Void

    // MARK: WPE WebKit

    let webViewBackendNew: @convention(c) (Pointer, Pointer?, Pointer?) -> Pointer?
    let webViewNew: @convention(c) (Pointer) -> Pointer?
    let webViewLoadHTML: @convention(c) (Pointer, UnsafePointer<CChar>, UnsafePointer<CChar>?) -> Void
    let webViewLoadURI: @convention(c) (Pointer, UnsafePointer<CChar>) -> Void
    let webViewGetTitle: @convention(c) (Pointer) -> UnsafePointer<CChar>?
    let webViewGetURI: @convention(c) (Pointer) -> UnsafePointer<CChar>?
    let webViewIsLoading: @convention(c) (Pointer) -> Int32
    let webViewGetEstimatedLoadProgress: @convention(c) (Pointer) -> Double
    let webViewCanGoBack: @convention(c) (Pointer) -> Int32
    let webViewCanGoForward: @convention(c) (Pointer) -> Int32
    let webViewGoBack: @convention(c) (Pointer) -> Void
    let webViewGoForward: @convention(c) (Pointer) -> Void
    let webViewReload: @convention(c) (Pointer) -> Void
    let webViewStopLoading: @convention(c) (Pointer) -> Void
    let webViewGetSettings: @convention(c) (Pointer) -> Pointer?
    let settingsSetAllowFileAccessFromFileURLs: @convention(c) (Pointer, Int32) -> Void
    let webViewEvaluateJavaScript: @convention(c) (Pointer, UnsafePointer<CChar>, Int, UnsafePointer<CChar>?,
                                                   UnsafePointer<CChar>?, Pointer?, Pointer?, Pointer?) -> Void
    let webViewEvaluateJavaScriptFinish: @convention(c) (Pointer, Pointer, UnsafeMutablePointer<Pointer?>) -> Pointer?
    let valueIsUndefined: @convention(c) (Pointer) -> Int32
    let valueToJSON: @convention(c) (Pointer, UInt32) -> UnsafeMutablePointer<CChar>?
    let navigationPolicyDecisionGetNavigationAction: @convention(c) (Pointer) -> Pointer?
    let navigationActionGetRequest: @convention(c) (Pointer) -> Pointer?
    let navigationActionGetNavigationType: @convention(c) (Pointer) -> Int32
    let uriRequestGetURI: @convention(c) (Pointer) -> UnsafePointer<CChar>?
    let policyDecisionUse: @convention(c) (Pointer) -> Void
    let policyDecisionIgnore: @convention(c) (Pointer) -> Void
    let networkSessionGetDefault: @convention(c) () -> Pointer?
    let networkSessionSetProxySettings: @convention(c) (Pointer, Int32, Pointer?) -> Void
    let networkProxySettingsNew: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?) -> Pointer?
    let networkProxySettingsFree: @convention(c) (Pointer) -> Void

    // MARK: GLib and GObject

    let mainContextIteration: @convention(c) (Pointer?, Int32) -> Int32
    let signalConnectData: @convention(c) (Pointer, UnsafePointer<CChar>, UnsafeRawPointer, Pointer?, Pointer?, Int32) -> UInt
    let signalHandlerDisconnect: @convention(c) (Pointer, UInt) -> Void
    let objectUnref: @convention(c) (Pointer) -> Void
    let free: @convention(c) (Pointer?) -> Void
    let errorFree: @convention(c) (Pointer) -> Void
    let quarkToString: @convention(c) (UInt32) -> UnsafePointer<CChar>?
    let paramSpecGetName: @convention(c) (Pointer) -> UnsafePointer<CChar>?

    // MARK: Constants

    // WebKitLoadEvent.
    static let loadStarted: Int32 = 0, loadRedirected: Int32 = 1, loadCommitted: Int32 = 2, loadFinished: Int32 = 3
    // WebKitPolicyDecisionType.
    static let navigationAction: Int32 = 0, newWindowAction: Int32 = 1
    /// wpe_view_activity_state.
    static let visible: UInt32 = 1, focused: UInt32 = 2, inWindow: UInt32 = 4
    /// WEBKIT_NETWORK_PROXY_MODE_CUSTOM.
    static let proxyModeCustom: Int32 = 2

    /// WPE, initialized; nil when it isn't installed.
    static let shared: WPE? = WPE()

    private init?() {
        let names = ["libwpe-1.0.so.1", "libWPEBackend-fdo-1.0.so.1", "libwayland-server.so.0", "libWPEWebKit-2.0.so.1",
                     "libglib-2.0.so.0", "libgobject-2.0.so.0"]
        // Local, so WPE's libraries never stand in for others of the same
        // names in the process.
        let libraries = names.map { dlopen($0, RTLD_NOW | RTLD_LOCAL) }
        guard let wpe = libraries[0], let fdo = libraries[1], let wayland = libraries[2], let webkit = libraries[3],
              let glib = libraries[4], let gobject = libraries[5] else {
            HostLog.debug("web: WPE WebKit isn't installed")
            return nil
        }
        var missing: [String] = []
        func bind<T>(_ library: Pointer, _ name: String, _: T.Type) -> T {
            guard let symbol = dlsym(library, name) else {
                missing.append(name)
                return unsafeBitCast(WPE.missingFunction, to: T.self)
            }
            return unsafeBitCast(symbol, to: T.self)
        }
        let loaderInit = bind(wpe, "wpe_loader_init", (@convention(c) (UnsafePointer<CChar>) -> Int32).self)
        let initializeShm = bind(fdo, "wpe_fdo_initialize_shm", (@convention(c) () -> Int32).self)
        viewBackendAddActivityState = bind(wpe, "wpe_view_backend_add_activity_state", (@convention(c) (Pointer, UInt32) -> Void).self)
        viewBackendRemoveActivityState = bind(wpe, "wpe_view_backend_remove_activity_state", (@convention(c) (Pointer, UInt32) -> Void).self)
        viewBackendDispatchSetSize = bind(wpe, "wpe_view_backend_dispatch_set_size", (@convention(c) (Pointer, UInt32, UInt32) -> Void).self)
        viewBackendDispatchSetDeviceScaleFactor = bind(wpe, "wpe_view_backend_dispatch_set_device_scale_factor",
                                                       (@convention(c) (Pointer, Float) -> Void).self)
        viewBackendDispatchPointerEvent = bind(wpe, "wpe_view_backend_dispatch_pointer_event",
                                               (@convention(c) (Pointer, UnsafeMutableRawPointer) -> Void).self)
        viewBackendDispatchAxisEvent = bind(wpe, "wpe_view_backend_dispatch_axis_event",
                                            (@convention(c) (Pointer, UnsafeMutableRawPointer) -> Void).self)
        viewBackendDispatchKeyboardEvent = bind(wpe, "wpe_view_backend_dispatch_keyboard_event",
                                                (@convention(c) (Pointer, UnsafeMutableRawPointer) -> Void).self)
        exportableCreate = bind(fdo, "wpe_view_backend_exportable_fdo_create",
                                (@convention(c) (UnsafeRawPointer, Pointer?, UInt32, UInt32) -> Pointer?).self)
        exportableDestroy = bind(fdo, "wpe_view_backend_exportable_fdo_destroy", (@convention(c) (Pointer) -> Void).self)
        exportableGetViewBackend = bind(fdo, "wpe_view_backend_exportable_fdo_get_view_backend", (@convention(c) (Pointer) -> Pointer?).self)
        exportableFrameComplete = bind(fdo, "wpe_view_backend_exportable_fdo_dispatch_frame_complete", (@convention(c) (Pointer) -> Void).self)
        exportableReleaseShmBuffer = bind(fdo, "wpe_view_backend_exportable_fdo_dispatch_release_shm_exported_buffer",
                                          (@convention(c) (Pointer, Pointer) -> Void).self)
        shmExportedBufferGetShmBuffer = bind(fdo, "wpe_fdo_shm_exported_buffer_get_shm_buffer", (@convention(c) (Pointer) -> Pointer?).self)
        shmBufferGetData = bind(wayland, "wl_shm_buffer_get_data", (@convention(c) (Pointer) -> Pointer?).self)
        shmBufferGetWidth = bind(wayland, "wl_shm_buffer_get_width", (@convention(c) (Pointer) -> Int32).self)
        shmBufferGetHeight = bind(wayland, "wl_shm_buffer_get_height", (@convention(c) (Pointer) -> Int32).self)
        shmBufferGetStride = bind(wayland, "wl_shm_buffer_get_stride", (@convention(c) (Pointer) -> Int32).self)
        shmBufferBeginAccess = bind(wayland, "wl_shm_buffer_begin_access", (@convention(c) (Pointer) -> Void).self)
        shmBufferEndAccess = bind(wayland, "wl_shm_buffer_end_access", (@convention(c) (Pointer) -> Void).self)
        webViewBackendNew = bind(webkit, "webkit_web_view_backend_new", (@convention(c) (Pointer, Pointer?, Pointer?) -> Pointer?).self)
        webViewNew = bind(webkit, "webkit_web_view_new", (@convention(c) (Pointer) -> Pointer?).self)
        webViewLoadHTML = bind(webkit, "webkit_web_view_load_html",
                               (@convention(c) (Pointer, UnsafePointer<CChar>, UnsafePointer<CChar>?) -> Void).self)
        webViewLoadURI = bind(webkit, "webkit_web_view_load_uri", (@convention(c) (Pointer, UnsafePointer<CChar>) -> Void).self)
        webViewGetTitle = bind(webkit, "webkit_web_view_get_title", (@convention(c) (Pointer) -> UnsafePointer<CChar>?).self)
        webViewGetURI = bind(webkit, "webkit_web_view_get_uri", (@convention(c) (Pointer) -> UnsafePointer<CChar>?).self)
        webViewIsLoading = bind(webkit, "webkit_web_view_is_loading", (@convention(c) (Pointer) -> Int32).self)
        webViewGetEstimatedLoadProgress = bind(webkit, "webkit_web_view_get_estimated_load_progress", (@convention(c) (Pointer) -> Double).self)
        webViewCanGoBack = bind(webkit, "webkit_web_view_can_go_back", (@convention(c) (Pointer) -> Int32).self)
        webViewCanGoForward = bind(webkit, "webkit_web_view_can_go_forward", (@convention(c) (Pointer) -> Int32).self)
        webViewGoBack = bind(webkit, "webkit_web_view_go_back", (@convention(c) (Pointer) -> Void).self)
        webViewGoForward = bind(webkit, "webkit_web_view_go_forward", (@convention(c) (Pointer) -> Void).self)
        webViewReload = bind(webkit, "webkit_web_view_reload", (@convention(c) (Pointer) -> Void).self)
        webViewStopLoading = bind(webkit, "webkit_web_view_stop_loading", (@convention(c) (Pointer) -> Void).self)
        webViewGetSettings = bind(webkit, "webkit_web_view_get_settings", (@convention(c) (Pointer) -> Pointer?).self)
        settingsSetAllowFileAccessFromFileURLs = bind(webkit, "webkit_settings_set_allow_file_access_from_file_urls",
                                                      (@convention(c) (Pointer, Int32) -> Void).self)
        webViewEvaluateJavaScript = bind(webkit, "webkit_web_view_evaluate_javascript",
                                         (@convention(c) (Pointer, UnsafePointer<CChar>, Int, UnsafePointer<CChar>?,
                                                          UnsafePointer<CChar>?, Pointer?, Pointer?, Pointer?) -> Void).self)
        webViewEvaluateJavaScriptFinish = bind(webkit, "webkit_web_view_evaluate_javascript_finish",
                                               (@convention(c) (Pointer, Pointer, UnsafeMutablePointer<Pointer?>) -> Pointer?).self)
        valueIsUndefined = bind(webkit, "jsc_value_is_undefined", (@convention(c) (Pointer) -> Int32).self)
        valueToJSON = bind(webkit, "jsc_value_to_json", (@convention(c) (Pointer, UInt32) -> UnsafeMutablePointer<CChar>?).self)
        navigationPolicyDecisionGetNavigationAction = bind(webkit, "webkit_navigation_policy_decision_get_navigation_action",
                                                           (@convention(c) (Pointer) -> Pointer?).self)
        navigationActionGetRequest = bind(webkit, "webkit_navigation_action_get_request", (@convention(c) (Pointer) -> Pointer?).self)
        navigationActionGetNavigationType = bind(webkit, "webkit_navigation_action_get_navigation_type",
                                                 (@convention(c) (Pointer) -> Int32).self)
        uriRequestGetURI = bind(webkit, "webkit_uri_request_get_uri", (@convention(c) (Pointer) -> UnsafePointer<CChar>?).self)
        policyDecisionUse = bind(webkit, "webkit_policy_decision_use", (@convention(c) (Pointer) -> Void).self)
        policyDecisionIgnore = bind(webkit, "webkit_policy_decision_ignore", (@convention(c) (Pointer) -> Void).self)
        networkSessionGetDefault = bind(webkit, "webkit_network_session_get_default", (@convention(c) () -> Pointer?).self)
        networkSessionSetProxySettings = bind(webkit, "webkit_network_session_set_proxy_settings",
                                              (@convention(c) (Pointer, Int32, Pointer?) -> Void).self)
        networkProxySettingsNew = bind(webkit, "webkit_network_proxy_settings_new",
                                       (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?) -> Pointer?).self)
        networkProxySettingsFree = bind(webkit, "webkit_network_proxy_settings_free", (@convention(c) (Pointer) -> Void).self)
        mainContextIteration = bind(glib, "g_main_context_iteration", (@convention(c) (Pointer?, Int32) -> Int32).self)
        signalConnectData = bind(gobject, "g_signal_connect_data",
                                 (@convention(c) (Pointer, UnsafePointer<CChar>, UnsafeRawPointer, Pointer?, Pointer?, Int32) -> UInt).self)
        signalHandlerDisconnect = bind(gobject, "g_signal_handler_disconnect", (@convention(c) (Pointer, UInt) -> Void).self)
        objectUnref = bind(gobject, "g_object_unref", (@convention(c) (Pointer) -> Void).self)
        free = bind(glib, "g_free", (@convention(c) (Pointer?) -> Void).self)
        errorFree = bind(glib, "g_error_free", (@convention(c) (Pointer) -> Void).self)
        quarkToString = bind(glib, "g_quark_to_string", (@convention(c) (UInt32) -> UnsafePointer<CChar>?).self)
        paramSpecGetName = bind(gobject, "g_param_spec_get_name", (@convention(c) (Pointer) -> UnsafePointer<CChar>?).self)
        guard missing.isEmpty else {
            HostLog.warning("web: WPE WebKit is incomplete (no \(missing.joined(separator: ", ")))")
            return nil
        }
        guard loaderInit("libWPEBackend-fdo-1.0.so.1") != 0, initializeShm() != 0 else {
            HostLog.warning("web: WPEBackend-fdo didn't initialize")
            return nil
        }
    }

    private static let missingFunction: @convention(c) () -> Void = {}

    /// Runs what GLib's main context has ready: WPE's signals, replies and
    /// frames.
    func dispatch() {
        var budget = 1000
        while budget > 0, mainContextIteration(nil, 0) != 0 {
            budget -= 1
        }
    }

    /// A GError's domain, code and message.
    func error(_ error: Pointer) -> GError {
        let domain = quarkToString(error.load(as: UInt32.self)).map { String(cString: $0) } ?? ""
        let code = error.load(fromByteOffset: 4, as: Int32.self)
        let message = error.load(fromByteOffset: 8, as: UnsafePointer<CChar>?.self).map { String(cString: $0) } ?? ""
        return GError(domain: domain, code: code, message: message)
    }

    /// Sends every page's remote loads to a proxy that refuses them: the
    /// app has no `network` capability (`WebKit.md`, "Without network").
    func blockNetwork() {
        guard let session = networkSessionGetDefault(),
              let settings = networkProxySettingsNew(WPE.refusingProxy, nil) else { return }
        networkSessionSetProxySettings(session, WPE.proxyModeCustom, settings)
        networkProxySettingsFree(settings)
    }

    /// A proxy on a host that never resolves (`.invalid`, RFC 2606), so
    /// nothing can answer for it.
    static let refusingProxy = "http://no-network.invalid:8080"
}

/// A GError's fields.
struct GError: Equatable {
    var domain: String
    var code: Int32
    var message: String
}

// MARK: - libwpe's input events

/// `struct wpe_input_pointer_event`. The event structs are laid out as
/// libwpe's, and passed to it by address.
struct PointerEvent {
    /// `wpe_input_pointer_event_type`: 1 motion, 2 button.
    var type: UInt32
    var time: UInt32
    var x: Int32
    var y: Int32
    var button: UInt32
    var state: UInt32
    var modifiers: UInt32
}

/// `struct wpe_input_axis_event`.
struct AxisEvent {
    /// `wpe_input_axis_event_type`: 1 motion.
    var type: UInt32
    var time: UInt32
    var x: Int32
    var y: Int32
    /// 0 vertical, 1 horizontal.
    var axis: UInt32
    var value: Int32
    var modifiers: UInt32
}

/// `struct wpe_input_keyboard_event`.
struct KeyboardEvent {
    var time: UInt32
    /// An XKB keysym.
    var keyCode: UInt32
    var hardwareKeyCode: UInt32
    var pressed: Bool
    var modifiers: UInt32
}

/// `wpe_input_modifier`.
enum WPEModifier {
    static let control: UInt32 = 1 << 0
    static let shift: UInt32 = 1 << 1
    static let alt: UInt32 = 1 << 2
    static let meta: UInt32 = 1 << 3
    static let button1: UInt32 = 1 << 20
}
