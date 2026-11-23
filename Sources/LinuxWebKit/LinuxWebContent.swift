import DynamicWebKit
import Foundation
import LinuxHost
import WPEWebKit

/// The `WebContent` contract (`WebKit.md`) over PureSwift/WebKit's
/// `WPEWebContent`, a WPE WebKit page.
///
/// The page loads whether or not it's shown. The player's `WebView` view
/// shows `content` with CacaoWebKit's `WebView(content:)`, which attaches it
/// while it's on screen and forwards its input. It runs the app's user
/// scripts, passes on its script messages and their replies, and its URL
/// schemes' requests. Main thread only.
public final class LinuxWebContent: WebContent {

    public let delegate: any WebContentDelegate

    /// The engine's page; nil where WPE WebKit isn't installed or can't make
    /// one.
    public let content: WPEWebContent?

    private let id: Int32

    /// What the engine's page reports to, passed on to `delegate`.
    private let relay: Relay

    /// Replies the page awaits, by the number the guest has for each.
    private var replies: [Int32: WPEScriptMessageReply] = [:]

    private var nextReply: Int32 = 1

    /// Requests in the app's schemes not yet answered, likewise.
    private var tasks: [Int32: WPEURLSchemeTask] = [:]

    private var nextTask: Int32 = 1

    private init(delegate: any WebContentDelegate, id: Int32) {
        self.delegate = delegate
        self.id = id
        LinuxWebKit.prepare()
        relay = Relay()
        content = WPEWebContent(delegate: relay)
        relay.page = self
        if let content {
            content.onScriptMessage = { [weak self] name, body in
                self?.received(name, body, reply: nil)
            }
            content.onScriptMessageWithReply = { [weak self] name, body, reply in
                guard let self else {
                    return reply.returnError("the page went away")
                }
                self.received(name, body, reply: reply)
            }
            content.onURLSchemeRequest = { [weak self] task in
                guard let self else {
                    return task.fail(.cancelled, message: "the page went away")
                }
                self.start(task)
            }
            // The engine watches what the new page waits for from here on.
            LinuxWebKit.pump()
        }
    }

    deinit {
        Self.pages[id] = nil
        for reply in replies.values {
            reply.returnError("the page went away")
        }
        for task in tasks.values {
            task.fail(.cancelled, message: "the page went away")
        }
    }

    // MARK: WebContent

    public static func make(_ delegate: any WebContentDelegate) -> LinuxWebContent {
        let page = LinuxWebContent(delegate: delegate, id: nextID)
        nextID &+= 1
        pages[page.id] = Weak(page)
        return page
    }

    /// What this host does beyond loading a page: what an app talks to its
    /// pages with. None of a browser's or a mail reader's features yet.
    public static func features() -> Int32 {
        guard LinuxWebKit.isAvailable else { return 0 }
        return WebFeatures([.userScripts, .scriptMessages, .messageReplies, .urlSchemes]).rawValue
    }

    /// The default store and no options, as `features()` offers no others,
    /// answering `schemes`. A scheme WebKit loads itself is left to it.
    public static func make(_ delegate: any WebContentDelegate, dataStore: Int32, options: Int32, schemes: [String]) -> LinuxWebContent {
        let page = make(delegate)
        if let content = page.content {
            for scheme in schemes where !content.registerURLScheme(scheme) {
                HostLog.warning("web: \(scheme) can't be an app's scheme")
            }
        }
        return page
    }

    public func identifier() -> Int32 {
        id
    }

    /// A URL that isn't one, or a remote one without the network, is
    /// refused before anything starts, with WPE WebKit or without.
    public func load(_ url: String) {
        guard let scheme = Self.scheme(of: url) else {
            return delegate.didFailNavigation(self, error: WebError.Code.badURL.rawValue, message: "\(url) isn't a URL")
        }
        if Self.remoteSchemes.contains(scheme), !LinuxWebKit.hasNetwork {
            return delegate.didFailNavigation(self, error: WebError.Code.notPermitted.rawValue, message: Self.noNetwork)
        }
        guard let content else {
            return unavailable()
        }
        LinuxWebKit.applyNetworkPolicy()
        content.load(url)
        LinuxWebKit.pump()
    }

    public func loadHTML(_ html: String, baseURL: String?) {
        guard let content else {
            return unavailable()
        }
        content.loadHTML(html, baseURL: baseURL)
        LinuxWebKit.pump()
    }

    public func loadResource(_ path: String) {
        guard let content else {
            return unavailable()
        }
        guard let file = Self.resourceFile(path) else {
            return delegate.didFailNavigation(self, error: WebError.Code.badURL.rawValue, message: "no resource \(path) in the app's bundle")
        }
        content.load(URL(fileURLWithPath: file).absoluteString)
        LinuxWebKit.pump()
    }

    public func reload() {
        content?.reload()
        LinuxWebKit.pump()
    }

    public func stopLoading() {
        content?.stopLoading()
        LinuxWebKit.pump()
    }

    public func goBack() {
        content?.goBack()
        LinuxWebKit.pump()
    }

    public func goForward() {
        content?.goForward()
        LinuxWebKit.pump()
    }

    public func evaluateJavaScript(_ script: String, request: Int32) {
        guard let content else {
            return delegate.didEvaluateJavaScript(self, request: request, result: nil, error: Self.notInstalled)
        }
        content.evaluateJavaScript(script, request: request)
        LinuxWebKit.pump()
    }

    // MARK: Scripts and schemes

    public func addUserScript(_ source: String, atDocumentStart: Bool, mainFrameOnly: Bool) {
        content?.addUserScript(source, atDocumentStart: atDocumentStart, mainFrameOnly: mainFrameOnly)
    }

    public func removeAllUserScripts() {
        content?.removeAllUserScripts()
    }

    public func addMessageHandler(_ name: String, replies: Bool) {
        content?.addScriptMessageHandler(name, replies: replies)
    }

    public func removeMessageHandler(_ name: String) {
        content?.removeScriptMessageHandler(name)
    }

    public func replyToMessage(_ reply: Int32, result: String?, error: String?) {
        guard let pending = replies.removeValue(forKey: reply) else { return }
        if let error {
            pending.returnError(error)
        } else {
            pending.returnValue(json: result)
        }
        LinuxWebKit.pump()
    }

    public func finishURLSchemeTask(_ task: Int32, status: Int32, contentType: String?, headers: [String], body: [UInt8]) {
        guard let pending = tasks.removeValue(forKey: task) else { return }
        let pairs = stride(from: 0, to: headers.count - 1, by: 2).map { (name: headers[$0], value: headers[$0 + 1]) }
        pending.finish(status: Int(status), contentType: contentType, headers: pairs, body: body)
        LinuxWebKit.pump()
    }

    public func failURLSchemeTask(_ task: Int32, error: Int32, message: String) {
        guard let pending = tasks.removeValue(forKey: task) else { return }
        pending.fail(WPEWebContent.ErrorCode(rawValue: error) ?? .unknown, message: message)
        LinuxWebKit.pump()
    }

    private func received(_ name: String, _ body: String?, reply: WPEScriptMessageReply?) {
        var number: Int32 = 0
        if let reply {
            number = nextReply
            nextReply = nextReply == .max ? 1 : nextReply + 1
            replies[number] = reply
        }
        delegate.didReceiveMessage(self, name: name, body: body, reply: number)
    }

    private func start(_ task: WPEURLSchemeTask) {
        let number = nextTask
        nextTask = nextTask == .max ? 1 : nextTask + 1
        tasks[number] = task
        delegate.startURLSchemeTask(self, task: number, url: task.url, method: task.method,
                                    headers: task.headers.flatMap { [$0.name, $0.value] }, body: task.body)
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
}

/// The engine page's delegate: passes what it hears to the guest's, with
/// the contract's page in place of the engine's. Its numbers are already
/// the contract's (`WebNavigationKind`, `WebError.Code`). It doesn't keep
/// the page alive: the page owns the engine's page, which owns this.
private final class Relay: WPEWebContentDelegate {

    weak var page: LinuxWebContent?

    func shouldNavigate(_ content: WPEWebContent, url: String, kind: Int32, isMainFrame: Bool) -> Bool {
        guard let page else { return false }
        return page.delegate.shouldNavigate(page, url: url, kind: kind, isMainFrame: isMainFrame)
    }

    func didChangeURL(_ content: WPEWebContent, url: String?) {
        guard let page else { return }
        page.delegate.didChangeURL(page, url: url)
    }

    func didChangeTitle(_ content: WPEWebContent, title: String) {
        guard let page else { return }
        page.delegate.didChangeTitle(page, title: title)
    }

    func didChangeLoading(_ content: WPEWebContent, isLoading: Bool, progress: Double) {
        guard let page else { return }
        page.delegate.didChangeLoading(page, isLoading: isLoading, progress: progress)
    }

    func didChangeHistory(_ content: WPEWebContent, canGoBack: Bool, canGoForward: Bool) {
        guard let page else { return }
        page.delegate.didChangeHistory(page, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    func didFinishNavigation(_ content: WPEWebContent) {
        guard let page else { return }
        page.delegate.didFinishNavigation(page)
    }

    func didFailNavigation(_ content: WPEWebContent, error: Int32, message: String) {
        guard let page else { return }
        page.delegate.didFailNavigation(page, error: error, message: message)
    }

    func didEvaluateJavaScript(_ content: WPEWebContent, request: Int32, result: String?, error: String?) {
        guard let page else { return }
        page.delegate.didEvaluateJavaScript(page, request: request, result: result, error: error)
    }
}
