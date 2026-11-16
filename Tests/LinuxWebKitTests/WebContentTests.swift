import DynamicWebKit
import Foundation
import LinuxHost
import Testing
@testable import LinuxWebKit

/// Records what a page tells its delegate, and answers `shouldNavigate`.
final class RecordingDelegate: WebContentDelegate {

    var events: [String] = []

    var allows = true

    var scripts: [Int32: (result: String?, error: String?)] = [:]

    func shouldNavigate(_ content: WebContent, url: String, kind: Int32, isMainFrame: Bool) -> Bool {
        events.append("should \(kind) \(url)")
        return allows
    }

    func didChangeURL(_ content: WebContent, url: String?) {
        events.append("url \(url ?? "nil")")
    }

    func didChangeTitle(_ content: WebContent, title: String) {
        events.append("title \(title)")
    }

    func didChangeLoading(_ content: WebContent, isLoading: Bool, progress: Double) {
        events.append(isLoading ? "loading" : "loaded \(progress)")
    }

    func didChangeHistory(_ content: WebContent, canGoBack: Bool, canGoForward: Bool) {
        events.append("history \(canGoBack) \(canGoForward)")
    }

    func didFinishNavigation(_ content: WebContent) {
        events.append("finish")
    }

    func didFailNavigation(_ content: WebContent, error: Int32, message: String) {
        events.append("fail \(error)")
    }

    func didEvaluateJavaScript(_ content: WebContent, request: Int32, result: String?, error: String?) {
        scripts[request] = (result, error)
    }

    var finished: Bool { events.contains("finish") }

    var title: String? {
        events.last { $0.hasPrefix("title ") }.map { String($0.dropFirst(6)) }
    }
}

/// WebKit's main thread is the first that calls it, so every test does its
/// WebKit work on this one thread.
final class WebThread: @unchecked Sendable {

    static let shared = WebThread()

    private let condition = NSCondition()

    private var jobs: [() -> Void] = []

    private init() {
        let thread = Thread { [unowned self] in
            while true {
                condition.lock()
                while jobs.isEmpty {
                    condition.wait()
                }
                let job = jobs.removeFirst()
                condition.unlock()
                job()
            }
        }
        thread.start()
    }

    /// Runs `body` on the thread and waits for it.
    func run<T>(_ body: @escaping () throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<T, Error>!
        condition.lock()
        jobs.append {
            outcome = Result { try body() }
            done.signal()
        }
        condition.signal()
        condition.unlock()
        done.wait()
        return try outcome.get()
    }
}

/// Runs GLib's context until `condition` holds, or fails after `seconds`.
func wait(_ seconds: Double = 20, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline {
            return false
        }
        WPE.shared?.dispatch()
        usleep(5_000)
    }
    return true
}

/// Pages share WebKit's process and its network session: one at a time.
@Suite(.serialized) struct WebContentTests {

    static var hasWPE: Bool {
        (try? WebThread.shared.run { WPE.shared != nil }) ?? false
    }

    // MARK: Without WPE

    @Test func schemes() {
        #expect(LinuxWebContent.scheme(of: "https://example.com") == "https")
        #expect(LinuxWebContent.scheme(of: "HTTP://x") == "http")
        #expect(LinuxWebContent.scheme(of: "data:text/html,hi") == "data")
        #expect(LinuxWebContent.scheme(of: "about:blank") == "about")
        #expect(LinuxWebContent.scheme(of: "example.com") == nil)
        #expect(LinuxWebContent.scheme(of: "1http://x") == nil)
        #expect(LinuxWebContent.scheme(of: "/path:with/colon") == nil)
    }

    @Test func errors() {
        #expect(LinuxWebContent.errorCode(GError(domain: "WebKitNetworkError", code: 302, message: "")) == nil)
        #expect(LinuxWebContent.errorCode(GError(domain: "WebKitPolicyError", code: 102, message: "")) == nil)
        #expect(LinuxWebContent.errorCode(GError(domain: "WebKitNetworkError", code: 300, message: "")) == .network)
        #expect(LinuxWebContent.errorCode(GError(domain: "WebKitNetworkError", code: 303, message: "")) == .badURL)
        #expect(LinuxWebContent.errorCode(GError(domain: "g-resolver-error-quark", code: 1, message: "")) == .network)
        #expect(LinuxWebContent.errorCode(GError(domain: "g-io-error-quark", code: 24, message: "")) == .timedOut)
        #expect(LinuxWebContent.errorCode(GError(domain: "g-io-error-quark", code: 39, message: "")) == .network)
        #expect(LinuxWebContent.errorCode(GError(domain: "g-tls-error-quark", code: 3, message: "")) == .security)
        #expect(LinuxWebContent.errorCode(GError(domain: "other", code: 1, message: "")) == .unknown)
    }

    @Test func navigationKinds() {
        #expect(LinuxWebContent.navigationKind(0) == .linkActivated)
        #expect(LinuxWebContent.navigationKind(1) == .formSubmitted)
        #expect(LinuxWebContent.navigationKind(4) == .formSubmitted)
        #expect(LinuxWebContent.navigationKind(2) == .backForward)
        #expect(LinuxWebContent.navigationKind(3) == .reload)
        #expect(LinuxWebContent.navigationKind(5) == .other)
    }

    @Test func pixelsTurnRGBA() {
        let bgra: [UInt8] = [10, 20, 30, 255, 1, 2, 3, 4, 99, 99, 99, 99]
        let data = bgra.withUnsafeBytes { LinuxWebContent.rgba(fromBGRA: $0.baseAddress!, width: 2, height: 1, stride: 12) }
        #expect(Array(data) == [30, 20, 10, 255, 3, 2, 1, 4])
    }

    @Test func resourcesStayInTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("web-resources-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("help"), withIntermediateDirectories: true)
        try Data("<title>Help</title>".utf8).write(to: root.appendingPathComponent("help/index.html"))
        defer { try? FileManager.default.removeItem(at: root) }
        LinuxBundle.resources = root.path
        defer { LinuxBundle.resources = nil }
        #expect(LinuxWebContent.resourceFile("help/index.html")?.hasSuffix("/help/index.html") == true)
        #expect(LinuxWebContent.resourceFile("help") == nil)
        #expect(LinuxWebContent.resourceFile("missing.html") == nil)
        #expect(LinuxWebContent.resourceFile("../etc/passwd") == nil)
    }

    @Test func remoteLoadsNeedTheNetworkCapability() throws {
        try WebThread.shared.run {
            LinuxWebKit.networkOverride = false
            defer { LinuxWebKit.networkOverride = nil }
            let delegate = RecordingDelegate()
            let page = LinuxWebContent.make(delegate)
            page.load("https://example.com/")
            // Refused before anything starts, with WPE or without.
            #expect(delegate.events == ["fail \(WebError.Code.notPermitted.rawValue)"])
            page.load("example.com")
            #expect(delegate.events.last == "fail \(WebError.Code.badURL.rawValue)")
        }
    }

    // MARK: In WPE

    @Test(.enabled(if: WebContentTests.hasWPE)) func loadsHTMLAndReports() throws {
        try WebThread.shared.run {
            let delegate = RecordingDelegate()
            let page = LinuxWebContent.make(delegate)
            page.loadHTML("<html><head><title>Hello</title></head><body>Hi</body></html>", baseURL: "https://example.com/")
            #expect(wait { delegate.finished && delegate.title == "Hello" })
            #expect(delegate.events.first == "loading")
            // The URL comes when the page commits, after loading starts.
            #expect(delegate.events.contains("url https://example.com/"))
            let loading = delegate.events.filter { $0 == "loading" || $0.hasPrefix("loaded") || $0 == "finish" }
            #expect(Array(loading.suffix(2)) == ["loaded 1.0", "finish"])
            // The guest's own load isn't asked about.
            #expect(!delegate.events.contains { $0.hasPrefix("should") })
            withExtendedLifetime(page) { }
        }
    }

    @Test(.enabled(if: WebContentTests.hasWPE)) func evaluatesJavaScript() throws {
        try WebThread.shared.run {
            let delegate = RecordingDelegate()
            let page = LinuxWebContent.make(delegate)
            page.loadHTML("<title>Example</title>", baseURL: nil)
            #expect(wait { delegate.finished })
            page.evaluateJavaScript("1 + 1", request: 1)
            page.evaluateJavaScript("document.title", request: 2)
            page.evaluateJavaScript("[1, 'two']", request: 3)
            page.evaluateJavaScript("undefined", request: 4)
            page.evaluateJavaScript("throw new Error('nope')", request: 5)
            #expect(wait { delegate.scripts.count == 5 })
            #expect(delegate.scripts[1]?.result == "2")
            #expect(delegate.scripts[2]?.result == "\"Example\"")
            #expect(delegate.scripts[3]?.result == "[1,\"two\"]")
            #expect(delegate.scripts[4].map { $0.result == nil && $0.error == nil } == true)
            #expect(delegate.scripts[5]?.result == nil)
            #expect(delegate.scripts[5]?.error?.contains("nope") == true)
            withExtendedLifetime(page) { }
        }
    }

    @Test(.enabled(if: WebContentTests.hasWPE)) func thePagesNavigationsAskTheDelegate() throws {
        let root = try Self.bundle(["one.html": "<title>One</title>", "two.html": "<title>Two</title>"])
        defer { try? FileManager.default.removeItem(at: root) }
        try WebThread.shared.run {
            LinuxBundle.resources = root.path
            defer { LinuxBundle.resources = nil }
            let delegate = RecordingDelegate()
            let page = LinuxWebContent.make(delegate)
            page.loadResource("one.html")
            #expect(wait { delegate.finished && delegate.title == "One" })
            delegate.events.removeAll()

            delegate.allows = false
            page.evaluateJavaScript("location.href = 'two.html'", request: 1)
            #expect(wait { delegate.events.contains { $0.hasPrefix("should") } })
            let asked = try #require(delegate.events.first)
            #expect(asked.hasPrefix("should \(WebNavigationKind.other.rawValue) file://") && asked.hasSuffix("/two.html"))
            #expect(!wait(1) { delegate.title == "Two" })
            #expect(!delegate.events.contains { $0.hasPrefix("fail") })

            delegate.allows = true
            delegate.events.removeAll()
            page.evaluateJavaScript("location.href = 'two.html'", request: 2)
            #expect(wait { delegate.finished && delegate.title == "Two" })
            #expect(delegate.events.contains("history true false"))

            // Back is asked about too, and goes back.
            delegate.events.removeAll()
            page.goBack()
            #expect(wait { delegate.finished && delegate.title == "One" })
            let back = try #require(delegate.events.first, "\(delegate.events)")
            #expect(back.hasPrefix("should \(WebNavigationKind.backForward.rawValue) file://") && back.hasSuffix("/one.html"),
                    "\(delegate.events)")
            #expect(delegate.events.contains("history false true"))
            withExtendedLifetime(page) { }
        }
    }

    /// A temporary bundle's resources: file names and contents.
    static func bundle(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("web-bundle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    @Test(.enabled(if: WebContentTests.hasWPE)) func aRefusedConnectionIsANetworkError() throws {
        try WebThread.shared.run {
            LinuxWebKit.networkOverride = true
            defer { LinuxWebKit.networkOverride = nil }
            let delegate = RecordingDelegate()
            let page = LinuxWebContent.make(delegate)
            // A closed port (9, discard, is one WebKit won't use at all).
            page.load("http://127.0.0.1:54321/")
            #expect(wait { delegate.events.contains { $0.hasPrefix("fail") } && delegate.events.last == "loaded 1.0" })
            #expect(delegate.events.contains("fail \(WebError.Code.network.rawValue)"))
            #expect(!delegate.finished)
            withExtendedLifetime(page) { }
        }
    }

    @Test(.enabled(if: WebContentTests.hasWPE)) func loadsBundleResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("web-bundle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html><head><title>Bundled</title></head></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        defer { try? FileManager.default.removeItem(at: root) }
        try WebThread.shared.run {
            LinuxBundle.resources = root.path
            defer { LinuxBundle.resources = nil }
            let delegate = RecordingDelegate()
            let page = LinuxWebContent.make(delegate)
            page.loadResource("index.html")
            #expect(wait { delegate.finished })
            #expect(delegate.title == "Bundled")
            #expect(delegate.events.contains { $0.hasPrefix("url file://") && $0.hasSuffix("/index.html") })
            page.loadResource("missing.html")
            #expect(delegate.events.last == "fail \(WebError.Code.badURL.rawValue)")
            withExtendedLifetime(page) { }
        }
    }

    @Test(.enabled(if: WebContentTests.hasWPE)) func drawsFramesAndTakesInput() throws {
        try WebThread.shared.run {
            let delegate = RecordingDelegate()
            let page = LinuxWebContent.make(delegate)
            var frame: WebFrame?
            page.display = { frame = $0 }
            page.attach(width: 160, height: 120, scale: 1)
            page.loadHTML("""
                <html><head><title>Start</title></head><body style="margin:0;background:#2a6">
                <button style="position:absolute;left:0;top:0;width:80px;height:40px"
                        onclick="document.title='Clicked'">Go</button>
                <input style="position:absolute;left:0;top:60px;width:120px;height:30px"
                       onkeydown="if (event.key == 'Enter') document.title = this.value">
                </body></html>
                """, baseURL: nil)
            // The background, below the button, once drawn: #22aa66.
            let offset = (100 * 160 + 140) * 4
            func green() -> Bool {
                guard let frame, frame.data.count == 160 * 120 * 4 else { return false }
                return Array(frame.data[offset..<offset + 4]) == [0x22, 0xAA, 0x66, 0xFF]
            }
            #expect(wait { delegate.finished && green() })
            let pixels = try #require(frame)
            #expect(pixels.width == 160 && pixels.height == 120 && pixels.scale == 1)

            page.focus(true)
            page.pointerMoved(x: 20, y: 20)
            page.pointerButton(x: 20, y: 20, pressed: true)
            page.pointerButton(x: 20, y: 20, pressed: false)
            #expect(wait { delegate.title == "Clicked" })

            page.pointerButton(x: 20, y: 75, pressed: true)
            page.pointerButton(x: 20, y: 75, pressed: false)
            for keysym: UInt32 in [0x68, 0x69, 0xFF0D] {    // h, i, Return
                page.key(keysym: keysym, pressed: true, control: false, shift: false, alt: false, meta: false)
                page.key(keysym: keysym, pressed: false, control: false, shift: false, alt: false, meta: false)
            }
            #expect(wait { delegate.title == "hi" })

            // A new size: frames follow it.
            page.resize(width: 100, height: 50, scale: 1)
            #expect(wait { frame?.width == 100 && frame?.height == 50 })
            page.detach()
            #expect(!page.isAttached)
            withExtendedLifetime(page) { }
        }
    }
}

/// The event structs match libwpe's layouts.
@Test func eventLayouts() {
    #expect(MemoryLayout<PointerEvent>.size == 28)
    #expect(MemoryLayout<AxisEvent>.size == 28)
    #expect(MemoryLayout<KeyboardEvent>.stride == 20)
    #expect(MemoryLayout<KeyboardEvent>.offset(of: \.pressed) == 12)
    #expect(MemoryLayout<KeyboardEvent>.offset(of: \.modifiers) == 16)
}
