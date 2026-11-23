// Node types this host draws itself, ahead of DarwinUI: `GLSurface`
// (HostGLSurface.swift), `WebView` (HostWebView.swift) and `VideoPlayer`
// (HostVideoPlayer.swift).
// Scripts/sync-darwinui.sh keeps this file and has NodeView ask
// `HostNodeViews` before it gives up on a type.
import DynamicUI
import SwiftUI

/// The views of node types DarwinUI doesn't know.
enum HostNodeViews {

    @MainActor
    static func view(for node: RenderNode, store: RenderStore) -> AnyView? {
        switch node.type {
        case "GLSurface":
            #if os(Linux)
            return AnyView(GLSurfaceView(identifier: Int32(clamping: node.props["surface"]?.int ?? 0)))
            #else
            // Apple's SwiftUI, for development: no GL here.
            return AnyView(Color.black)
            #endif
        case "WebView":
            #if os(Linux)
            return AnyView(HostWebView(identifier: Int32(clamping: node.props["page"]?.int ?? 0)))
            #else
            return AnyView(Color.white)
            #endif
        case "VideoPlayer":
            #if os(Linux)
            return AnyView(HostVideoPlayer(identifier: Int32(clamping: node.props["player"]?.int ?? 0),
                                           scaling: node.props["scaling"]?.string, controls: node.props["controls"]?.string))
            #else
            return AnyView(Color.black)
            #endif
        default:
            return nil
        }
    }
}
