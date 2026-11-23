import DynamicWebKit
import Foundation
import LinuxHost
import WPEWebKit

/// The `WebContent` contract (`WebKit.md`) over PureSwift/WebKit's
/// `WPEWebContent`, a WPE WebKit page.
///
/// The page loads whether or not it's shown. The player's `WebView` view
/// shows `content` with CacaoWebKit's `WebView(content:)`, which attaches it
/// while it's on screen and forwards its input. Main thread only.
public final class LinuxWebContent: WebContent {

    public let delegate: any WebContentDelegate

    /// The engine's page; nil where WPE WebKit isn't installed or can't make
    /// one.
    public let content: WPEWebContent?

    private let id: Int32

    /// What the engine's page reports to, passed on to `delegate`.
    private let relay: Relay

    private init(delegate: any WebContentDelegate, id: Int32) {
        self.delegate = delegate
        self.id = id
        LinuxWebKit.prepare()
        relay = Relay()
        content = WPEWebContent(delegate: relay)
        relay.page = self
        if content != nil {
            // The engine watches what the new page waits for from here on.
            LinuxWebKit.pump()
        }
    }

    deinit {
        Self.pages[id] = nil
    }

    // MARK: WebContent

    public static func make(_ delegate: any WebContentDelegate) -> LinuxWebContent {
        let page = LinuxWebContent(delegate: delegate, id: nextID)
        nextID &+= 1
        pages[page.id] = Weak(page)
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
