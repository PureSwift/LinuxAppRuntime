import DynamicWebKit
import Foundation
import LinuxHost

/// A frame of a page: 8-bit RGBA, premultiplied, rows top to bottom, in
/// pixels, and the pixels per point it was drawn at.
public struct WebFrame: Sendable {

    public var data: Data

    public var width: Int

    public var height: Int

    public var scale: Float
}

/// The `WebContent` contract (`WebKit.md`) over a WPE `WebKitWebView`.
///
/// The page loads whether or not it's shown. The player's `WebView` view
/// attaches it with its size in points, gets its frames through `display`,
/// and forwards its input. Main thread only.
public final class LinuxWebContent: WebContent {

    public typealias Pointer = UnsafeMutableRawPointer

    public let delegate: any WebContentDelegate

    private let id: Int32

    private let wpe: WPE?

    private var exportable: Pointer?

    private var backend: Pointer?

    private var view: Pointer?

    /// The exportable's client data: this page, until it goes.
    private let slot: UnsafeMutablePointer<Pointer?>

    private var handlers: [UInt] = []

    // MARK: What the delegate was last told

    private var reportedURL: String?

    private var reportedTitle = ""

    private var reportedHistory = (canGoBack: false, canGoForward: false)

    private var isLoading = false

    /// A navigation started and hasn't committed: WebKit's `uri` is what
    /// was asked for, not where the page is yet.
    private var isProvisional = false

    /// The navigation in progress failed, so it doesn't finish.
    private var failed = false

    /// The guest asked for the next navigation itself (`load`, `loadHTML`,
    /// `loadResource`, or a new window it agreed to), so it isn't asked
    /// about it.
    private var expectsOwnNavigation = false

    // MARK: The view

    /// Called with each frame while the page is attached, for the view to
    /// show.
    public var display: ((WebFrame) -> Void)?

    /// The view's size in points and its scale, while attached.
    public private(set) var size: (width: UInt32, height: UInt32, scale: Float)?

    public var isAttached: Bool { size != nil }

    private var buttonsHeld: UInt32 = 0

    private init(delegate: any WebContentDelegate, id: Int32) {
        self.delegate = delegate
        self.id = id
        self.wpe = WPE.shared
        slot = .allocate(capacity: 1)
        slot.initialize(to: nil)
        guard let wpe else { return }
        LinuxWebKit.applyNetworkPolicy()
        // WebKit destroys the exportable when it's done with the backend.
        guard let exportable = wpe.exportableCreate(Self.client, slot, 800, 600),
              let backend = wpe.exportableGetViewBackend(exportable),
              let webBackend = wpe.webViewBackendNew(backend, unsafeBitCast(Self.onBackendDestroyed, to: Pointer.self), exportable),
              let view = wpe.webViewNew(webBackend) else {
            HostLog.warning("web: can't make a WPE web view")
            return
        }
        self.exportable = exportable
        self.backend = backend
        self.view = view
        slot.pointee = Unmanaged.passUnretained(self).toOpaque()
        wpe.viewBackendAddActivityState(backend, WPE.inWindow)
        let data = Unmanaged.passUnretained(self).toOpaque()
        func connect(_ signal: String, _ callback: UnsafeRawPointer) {
            handlers.append(wpe.signalConnectData(view, signal, callback, data, nil, 0))
        }
        connect("load-changed", unsafeBitCast(Self.onLoadChanged, to: UnsafeRawPointer.self))
        connect("load-failed", unsafeBitCast(Self.onLoadFailed, to: UnsafeRawPointer.self))
        connect("load-failed-with-tls-errors", unsafeBitCast(Self.onTLSErrors, to: UnsafeRawPointer.self))
        connect("decide-policy", unsafeBitCast(Self.onDecidePolicy, to: UnsafeRawPointer.self))
        for property in ["title", "uri", "estimated-load-progress"] {
            connect("notify::\(property)", unsafeBitCast(Self.onNotify, to: UnsafeRawPointer.self))
        }
    }

    deinit {
        if let wpe, let view {
            for handler in handlers {
                wpe.signalHandlerDisconnect(view, handler)
            }
            wpe.objectUnref(view)
        }
        // The slot stays, empty, for a frame still on its way.
        slot.pointee = nil
        let id = self.id
        Self.pages[id] = nil
        LinuxWebKit.pagesChanged()
    }

    // MARK: WebContent

    public static func make(_ delegate: any WebContentDelegate) -> LinuxWebContent {
        let page = LinuxWebContent(delegate: delegate, id: nextID)
        nextID &+= 1
        pages[page.id] = Weak(page)
        LinuxWebKit.pagesChanged()
        return page
    }

    public func identifier() -> Int32 {
        id
    }

    public func load(_ url: String) {
        guard let scheme = Self.scheme(of: url) else {
            delegate.didFailNavigation(self, error: WebError.Code.badURL.rawValue, message: "\(url) isn't a URL")
            return
        }
        if Self.remoteSchemes.contains(scheme), !LinuxWebKit.hasNetwork {
            delegate.didFailNavigation(self, error: WebError.Code.notPermitted.rawValue, message: Self.noNetwork)
            return
        }
        guard let view, let wpe else {
            return unavailable()
        }
        LinuxWebKit.applyNetworkPolicy()
        startOwnNavigation()
        wpe.webViewLoadURI(view, url)
    }

    public func loadHTML(_ html: String, baseURL: String?) {
        guard let view, let wpe else {
            return unavailable()
        }
        startOwnNavigation()
        if let baseURL {
            wpe.webViewLoadHTML(view, html, baseURL)
        } else {
            wpe.webViewLoadHTML(view, html, nil)
        }
    }

    public func loadResource(_ path: String) {
        guard let view, let wpe else {
            return unavailable()
        }
        guard let file = Self.resourceFile(path) else {
            delegate.didFailNavigation(self, error: WebError.Code.badURL.rawValue, message: "no resource \(path) in the app's bundle")
            return
        }
        startOwnNavigation()
        wpe.webViewLoadURI(view, URL(fileURLWithPath: file).absoluteString)
    }

    public func reload() {
        guard let wpe, let view else { return }
        isProvisional = true
        wpe.webViewReload(view)
    }

    public func stopLoading() {
        guard let wpe, let view else { return }
        wpe.webViewStopLoading(view)
    }

    /// WebKit moves its `uri` to the history item before asking about the
    /// navigation, so it's provisional from here.
    public func goBack() {
        guard let wpe, let view, wpe.webViewCanGoBack(view) != 0 else { return }
        isProvisional = true
        wpe.webViewGoBack(view)
    }

    public func goForward() {
        guard let wpe, let view, wpe.webViewCanGoForward(view) != 0 else { return }
        isProvisional = true
        wpe.webViewGoForward(view)
    }

    public func evaluateJavaScript(_ script: String, request: Int32) {
        guard let wpe, let view else {
            delegate.didEvaluateJavaScript(self, request: request, result: nil, error: Self.notInstalled)
            return
        }
        let box = Unmanaged.passRetained(Evaluation(page: self, request: request)).toOpaque()
        wpe.webViewEvaluateJavaScript(view, script, -1, nil, nil, nil, unsafeBitCast(Self.onEvaluated, to: Pointer.self), box)
    }

    /// The guest's own load: it isn't asked about, and WebKit's `uri`,
    /// which changes at once, isn't where the page is until it commits.
    private func startOwnNavigation() {
        expectsOwnNavigation = true
        isProvisional = true
    }

    private func unavailable() {
        delegate.didFailNavigation(self, error: WebError.Code.unknown.rawValue, message: Self.notInstalled)
    }

    static let notInstalled = "WPE WebKit isn't installed"

    static let noNetwork = "the app doesn't have the network capability"

    // MARK: Pages

    private struct Weak {
        weak var page: LinuxWebContent?
        init(_ page: LinuxWebContent) { self.page = page }
    }

    nonisolated(unsafe) private static var pages: [Int32: Weak] = [:]

    nonisolated(unsafe) private static var nextID: Int32 = 1

    /// The live page whose `identifier()` a `WebView` node carries.
    public static func page(identifier: Int32) -> LinuxWebContent? {
        pages[identifier]?.page
    }

    static var count: Int {
        pages.values.filter { $0.page != nil }.count
    }

    // MARK: URLs

    /// Schemes that reach the network.
    static let remoteSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp"]

    /// A URL's scheme, lowercased: letters, digits, `+`, `-` and `.`
    /// before the first colon, starting with a letter.
    static func scheme(of url: String) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let scheme = url[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else {
            return nil
        }
        return scheme.lowercased()
    }

    /// A resource's file in the bundle's `resources/`, if it's there and
    /// inside it.
    static func resourceFile(_ path: String) -> String? {
        guard let resources = LinuxBundle.resources else { return nil }
        let root = URL(fileURLWithPath: resources).standardizedFileURL.path
        let file = URL(fileURLWithPath: root).appendingPathComponent(path).standardizedFileURL.path
        guard file.hasPrefix(root + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return file
    }

    // MARK: Reporting

    /// Where the page is: not while a navigation is provisional, nor an
    /// empty URI WebKit has after a failed first load.
    private func reportURL() {
        guard let wpe, let view, !isProvisional else { return }
        let uri = wpe.webViewGetURI(view).map { String(cString: $0) }
        let url = uri?.isEmpty == false ? uri : nil
        guard url != reportedURL else { return }
        reportedURL = url
        delegate.didChangeURL(self, url: url)
        reportHistory()
    }

    private func reportTitle() {
        guard let wpe, let view else { return }
        let title = wpe.webViewGetTitle(view).map { String(cString: $0) } ?? ""
        guard title != reportedTitle else { return }
        reportedTitle = title
        delegate.didChangeTitle(self, title: title)
    }

    private func reportProgress() {
        guard let wpe, let view, isLoading else { return }
        delegate.didChangeLoading(self, isLoading: true, progress: wpe.webViewGetEstimatedLoadProgress(view))
    }

    private func reportHistory() {
        guard let wpe, let view else { return }
        let history = (canGoBack: wpe.webViewCanGoBack(view) != 0, canGoForward: wpe.webViewCanGoForward(view) != 0)
        guard history != reportedHistory else { return }
        reportedHistory = history
        delegate.didChangeHistory(self, canGoBack: history.canGoBack, canGoForward: history.canGoForward)
    }

    fileprivate func loadChanged(_ event: Int32) {
        switch event {
        case WPE.loadStarted:
            failed = false
            isLoading = true
            isProvisional = true
            reportProgress()
        case WPE.loadRedirected:
            // The redirect is followed: the page is going there.
            isProvisional = false
            reportURL()
            isProvisional = true
        case WPE.loadCommitted:
            isProvisional = false
            reportURL()
            reportHistory()
        case WPE.loadFinished:
            isLoading = false
            isProvisional = false
            reportURL()
            reportHistory()
            delegate.didChangeLoading(self, isLoading: false, progress: 1)
            if !failed {
                delegate.didFinishNavigation(self)
            }
            failed = false
        default:
            break
        }
    }

    fileprivate func loadFailed(_ error: GError) {
        HostLog.debug("web: page \(id) failed: \(error.domain) \(error.code) \(error.message)")
        guard let code = Self.errorCode(error) else {
            // Stopped, or replaced by another navigation: not a failure.
            return
        }
        fail(code, error.message)
    }

    fileprivate func fail(_ code: WebError.Code, _ message: String) {
        failed = true
        delegate.didFailNavigation(self, error: code.rawValue, message: message)
    }

    /// `WebError.Code` for a load's GError; nil when it isn't a failure.
    static func errorCode(_ error: GError) -> WebError.Code? {
        switch error.domain {
        case "WebKitNetworkError":
            switch error.code {
            case 302: return nil                // cancelled
            case 300: return .network           // transport
            case 301, 303: return .badURL       // unknown protocol, no such file
            default: return .unknown
            }
        case "WebKitPolicyError":
            switch error.code {
            case 102: return nil                // interrupted by a policy change
            case 101: return .badURL            // can't show the URI
            default: return .unknown
            }
        case "g-resolver-error-quark", "soup-session-error-quark":
            return .network
        case "g-io-error-quark":
            return error.code == 24 ? .timedOut : .network
        case "g-tls-error-quark":
            return .security
        default:
            return .unknown
        }
    }

    /// Asks the delegate about a navigation the page or the user started,
    /// and answers WebKit.
    fileprivate func decide(_ decision: Pointer, type: Int32) -> Bool {
        guard let wpe, type == WPE.navigationAction || type == WPE.newWindowAction,
              let action = wpe.navigationPolicyDecisionGetNavigationAction(decision) else {
            return false
        }
        let url = wpe.navigationActionGetRequest(action).flatMap(wpe.uriRequestGetURI).map { String(cString: $0) } ?? ""
        let kind = Self.navigationKind(wpe.navigationActionGetNavigationType(action))
        if type == WPE.navigationAction, expectsOwnNavigation {
            expectsOwnNavigation = false
            wpe.policyDecisionUse(decision)
            return true
        }
        if let scheme = Self.scheme(of: url), Self.remoteSchemes.contains(scheme), !LinuxWebKit.hasNetwork {
            wpe.policyDecisionIgnore(decision)
            delegate.didFailNavigation(self, error: WebError.Code.notPermitted.rawValue, message: Self.noNetwork)
            return true
        }
        let allowed = delegate.shouldNavigate(self, url: url, kind: kind.rawValue, isMainFrame: true)
        if type == WPE.newWindowAction {
            // New windows load in this page.
            wpe.policyDecisionIgnore(decision)
            if allowed, let view {
                startOwnNavigation()
                wpe.webViewLoadURI(view, url)
            }
        } else if allowed {
            isProvisional = true
            wpe.policyDecisionUse(decision)
        } else {
            wpe.policyDecisionIgnore(decision)
        }
        return true
    }

    /// `WebKitNavigationType` as `WebNavigationKind`.
    static func navigationKind(_ type: Int32) -> WebNavigationKind {
        switch type {
        case 0: .linkActivated
        case 1, 4: .formSubmitted   // submitted, resubmitted
        case 2: .backForward
        case 3: .reload
        default: .other
        }
    }

    // MARK: The view

    /// Puts the page on screen at a size in points: it's visible, draws at
    /// that size, and sends its frames to `display`.
    public func attach(width: UInt32, height: UInt32, scale: Float) {
        guard let wpe, let backend else { return }
        size = (max(width, 1), max(height, 1), scale)
        wpe.viewBackendDispatchSetDeviceScaleFactor(backend, scale)
        wpe.viewBackendDispatchSetSize(backend, max(width, 1), max(height, 1))
        wpe.viewBackendAddActivityState(backend, WPE.visible)
    }

    public func resize(width: UInt32, height: UInt32, scale: Float) {
        guard let wpe, let backend, let size else { return }
        let width = max(width, 1), height = max(height, 1)
        if scale != size.scale {
            wpe.viewBackendDispatchSetDeviceScaleFactor(backend, scale)
        }
        if width != size.width || height != size.height {
            wpe.viewBackendDispatchSetSize(backend, width, height)
        }
        self.size = (width, height, scale)
    }

    /// The view is gone: the page stays loaded, hidden and unfocused.
    public func detach() {
        guard let wpe, let backend, isAttached else { return }
        focus(false)
        buttonsHeld = 0
        wpe.viewBackendRemoveActivityState(backend, WPE.visible)
        size = nil
    }

    fileprivate func receive(_ buffer: Pointer) {
        guard let wpe, let exportable else { return }
        defer {
            wpe.exportableReleaseShmBuffer(exportable, buffer)
            wpe.exportableFrameComplete(exportable)
        }
        guard let size, let display, let shm = wpe.shmExportedBufferGetShmBuffer(buffer) else { return }
        wpe.shmBufferBeginAccess(shm)
        defer { wpe.shmBufferEndAccess(shm) }
        let width = Int(wpe.shmBufferGetWidth(shm)), height = Int(wpe.shmBufferGetHeight(shm))
        let stride = Int(wpe.shmBufferGetStride(shm))
        guard width > 0, height > 0, stride >= width * 4, let pixels = wpe.shmBufferGetData(shm) else { return }
        let data = Self.rgba(fromBGRA: UnsafeRawPointer(pixels), width: width, height: height, stride: stride)
        display(WebFrame(data: data, width: width, height: height, scale: size.scale))
    }

    /// Wayland's ARGB8888, premultiplied, blue first in memory, as RGBA.
    static func rgba(fromBGRA pixels: UnsafeRawPointer, width: Int, height: Int, stride: Int) -> Data {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            let output = output.bindMemory(to: UInt8.self)
            let input = pixels.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let source = row * stride, destination = row * width * 4
                for column in 0..<width {
                    let s = source + column * 4, d = destination + column * 4
                    output[d] = input[s + 2]
                    output[d + 1] = input[s + 1]
                    output[d + 2] = input[s]
                    output[d + 3] = input[s + 3]
                }
            }
        }
        return data
    }

    // MARK: Input

    /// The pointer moved, in points from the page's top left.
    public func pointerMoved(x: Float, y: Float) {
        dispatchPointer(type: 1, x: x, y: y, button: 0, state: 0)
    }

    /// The primary button went down or up, in points.
    public func pointerButton(x: Float, y: Float, pressed: Bool) {
        buttonsHeld = pressed ? WPEModifier.button1 : 0
        dispatchPointer(type: 2, x: x, y: y, button: 1, state: pressed ? 1 : 0)
    }

    private func dispatchPointer(type: UInt32, x: Float, y: Float, button: UInt32, state: UInt32) {
        guard let wpe, let backend, isAttached else { return }
        var event = PointerEvent(type: type, time: Self.time(), x: Int32(x.rounded()), y: Int32(y.rounded()),
                                 button: button, state: state, modifiers: buttonsHeld)
        withUnsafeMutableBytes(of: &event) { wpe.viewBackendDispatchPointerEvent(backend, $0.baseAddress!) }
    }

    /// A wheel scroll at a point: how far the content should move, in
    /// points, positive down and right.
    public func scroll(x: Float, y: Float, dx: Float, dy: Float) {
        guard let wpe, let backend, isAttached else { return }
        for (axis, delta) in [(UInt32(0), dy), (UInt32(1), dx)] where delta != 0 {
            // libwpe's axis values run opposite to the content's movement.
            var event = AxisEvent(type: 1, time: Self.time(), x: Int32(x.rounded()), y: Int32(y.rounded()),
                                  axis: axis, value: Int32((-delta).rounded()), modifiers: buttonsHeld)
            withUnsafeMutableBytes(of: &event) { wpe.viewBackendDispatchAxisEvent(backend, $0.baseAddress!) }
        }
    }

    /// A key, as an XKB keysym, with `WPEModifier`s held. Pages turn keys
    /// into text themselves.
    public func key(keysym: UInt32, pressed: Bool, control: Bool, shift: Bool, alt: Bool, meta: Bool) {
        guard let wpe, let backend, isAttached else { return }
        var modifiers: UInt32 = 0
        if control { modifiers |= WPEModifier.control }
        if shift { modifiers |= WPEModifier.shift }
        if alt { modifiers |= WPEModifier.alt }
        if meta { modifiers |= WPEModifier.meta }
        var event = KeyboardEvent(time: Self.time(), keyCode: keysym, hardwareKeyCode: 0, pressed: pressed, modifiers: modifiers)
        withUnsafeMutableBytes(of: &event) { wpe.viewBackendDispatchKeyboardEvent(backend, $0.baseAddress!) }
    }

    /// Keyboard focus came to the page or left it.
    public func focus(_ focused: Bool) {
        guard let wpe, let backend else { return }
        if focused {
            wpe.viewBackendAddActivityState(backend, WPE.focused)
        } else {
            wpe.viewBackendRemoveActivityState(backend, WPE.focused)
        }
    }

    /// Milliseconds, as libwpe's events carry them.
    private static func time() -> UInt32 {
        UInt32(truncatingIfNeeded: MainLoop.now() / 1_000_000)
    }

    // MARK: Callbacks from C

    /// `wpe_view_backend_exportable_fdo_client`: frames in shared memory.
    nonisolated(unsafe) private static let client: UnsafeRawPointer = {
        let client = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 5)
        client.initialize(repeating: nil, count: 5)
        client[2] = unsafeBitCast(LinuxWebContent.onShmBuffer, to: UnsafeRawPointer.self)
        return UnsafeRawPointer(client)
    }()

    private static func page(_ data: Pointer?) -> LinuxWebContent? {
        data.map { Unmanaged<LinuxWebContent>.fromOpaque($0).takeUnretainedValue() }
    }

    private static let onShmBuffer: @convention(c) (Pointer?, Pointer?) -> Void = { data, buffer in
        guard let buffer else { return }
        guard let pointer = data?.assumingMemoryBound(to: Pointer?.self).pointee else {
            return
        }
        page(pointer)?.receive(buffer)
    }

    private static let onBackendDestroyed: @convention(c) (Pointer?) -> Void = { exportable in
        if let exportable {
            WPE.shared?.exportableDestroy(exportable)
        }
    }

    private static let onLoadChanged: @convention(c) (Pointer?, Int32, Pointer?) -> Void = { _, event, data in
        page(data)?.loadChanged(event)
    }

    /// load-failed: the view, the load event, the URI and the GError;
    /// true, as handled.
    private static let onLoadFailed: @convention(c) (Pointer?, Int32, UnsafePointer<CChar>?, Pointer?, Pointer?) -> Int32 = {
        _, _, _, error, data in
        guard let page = page(data), let wpe = page.wpe else { return 1 }
        page.loadFailed(error.map(wpe.error) ?? GError(domain: "", code: 0, message: ""))
        return 1
    }

    /// load-failed-with-tls-errors: the view, the URI, the certificate and
    /// its errors; true, as handled, so load-failed doesn't follow.
    private static let onTLSErrors: @convention(c) (Pointer?, UnsafePointer<CChar>?, Pointer?, UInt32, Pointer?) -> Int32 = {
        _, uri, _, _, data in
        let url = uri.map { String(cString: $0) } ?? ""
        page(data)?.fail(.security, "the certificate for \(url) isn't trusted")
        return 1
    }

    private static let onDecidePolicy: @convention(c) (Pointer?, Pointer?, Int32, Pointer?) -> Int32 = { _, decision, type, data in
        guard let page = page(data), let decision else { return 0 }
        return page.decide(decision, type: type) ? 1 : 0
    }

    private static let onNotify: @convention(c) (Pointer?, Pointer?, Pointer?) -> Void = { _, spec, data in
        guard let page = page(data), let spec, let name = page.wpe?.paramSpecGetName(spec) else { return }
        switch String(cString: name) {
        case "title": page.reportTitle()
        case "uri": page.reportURL()
        case "estimated-load-progress": page.reportProgress()
        default: break
        }
    }

    private final class Evaluation {
        let page: LinuxWebContent
        let request: Int32
        init(page: LinuxWebContent, request: Int32) {
            self.page = page
            self.request = request
        }
    }

    /// A script's value as JSON (nil for undefined and what JSON can't
    /// hold), or the exception's message.
    private static let onEvaluated: @convention(c) (Pointer?, Pointer?, Pointer?) -> Void = { source, result, data in
        guard let data else { return }
        let evaluation = Unmanaged<Evaluation>.fromOpaque(data).takeRetainedValue()
        let page = evaluation.page
        guard let wpe = page.wpe else { return }
        var error: Pointer?
        guard let source, let result, let value = wpe.webViewEvaluateJavaScriptFinish(source, result, &error) else {
            let message = error.map(wpe.error)?.message ?? "the script failed"
            if let error {
                wpe.errorFree(error)
            }
            page.delegate.didEvaluateJavaScript(page, request: evaluation.request, result: nil, error: message)
            return
        }
        defer { wpe.objectUnref(value) }
        var json: String?
        if wpe.valueIsUndefined(value) == 0, let text = wpe.valueToJSON(value, 0) {
            json = String(cString: text)
            wpe.free(text)
        }
        page.delegate.didEvaluateJavaScript(page, request: evaluation.request, result: json, error: nil)
    }
}
