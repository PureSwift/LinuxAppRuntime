import DynamicRuntime
import DynamicUI
import LinuxHost
import RuntimeABI

/// Shows a renderer's store: a window. `LinuxSDL` provides one; tests use
/// none, or their own.
public protocol RendererPresenter: AnyObject {

    /// The guest made a renderer: show it.
    func present(_ store: RenderStore)

    /// The guest released it.
    func dismiss(_ store: RenderStore)

    /// The text engine new stores measure with.
    var textEngine: TextEngine { get }

    /// The palette new stores start with: light or dark, as the system is.
    var palette: Palette { get }
}

/// The `Renderer` contract: decodes what the guest sends into a
/// `RenderStore`, which a presenter shows.
public final class LinuxRenderer: Renderer {

    public let store: RenderStore

    init(delegate: any RendererDelegate) {
        let presenter = LinuxUIModule.presenter
        store = RenderStore(
            textEngine: presenter?.textEngine ?? FixedTextEngine(),
            palette: presenter?.palette ?? Palette(scheme: .light)
        )
        store.delegate = delegate
    }

    deinit {
        LinuxUIModule.presenter?.dismiss(store)
        // The guest's delegate goes with the renderer.
        store.delegate = nil
    }

    public static func make(_ delegate: any RendererDelegate) -> LinuxRenderer {
        let renderer = LinuxRenderer(delegate: delegate)
        LinuxUIModule.presenter?.present(renderer.store)
        LinuxUIModule.made?(renderer)
        return renderer
    }

    public func apply(_ tree: [UInt8]) {
        do {
            store.apply(try RenderCodec.decode(tree))
        } catch {
            HostLog.error("the app sent a tree this host can't read: \(error)")
        }
    }

    public func replaceSubtree(_ id: [UInt8], tree: [UInt8]) {
        do {
            store.replace(try RenderCodec.decode(id: id), with: try RenderCodec.decode(tree))
        } catch {
            HostLog.error("the app sent a subtree this host can't read: \(error)")
        }
    }
}

/// The SwiftUI player's contracts.
public enum LinuxUIModule: HostModule {

    /// Shows renderers. Set by the app before the guest starts.
    nonisolated(unsafe) public static var presenter: (any RendererPresenter)?

    /// Called with each renderer the guest makes, for tests.
    nonisolated(unsafe) public static var made: ((LinuxRenderer) -> Void)?

    public static var contracts: [ContractDescriptor] {
        [RendererProxy.descriptor, RendererDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        RendererProxy.register(LinuxRenderer.self, in: registrar)
        RendererDelegateProxy.registerInterface(in: registrar)
    }
}
