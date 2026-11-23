// `WebView` nodes: a `LinuxWebContent`'s page, shown by PureSwift/WebKit's
// `WebView(content:)`, with the view's input going to it (`WebKit.md`).
// Scripts/sync-darwinui.sh keeps this file.
#if os(Linux)
import CacaoWebKit
import LinuxHost
import LinuxWebKit
import SwiftUI

/// A page, at the size the view is offered. The page stays loaded when the
/// view goes.
struct HostWebView: View {

    let identifier: Int32

    var body: some View {
        if let content = LinuxWebContent.page(identifier: identifier)?.content {
            CacaoWebKit.WebView(content: content)
        } else {
            Color.white
                .onAppear {
                    if LinuxWebContent.page(identifier: identifier) == nil {
                        HostLog.warning("web: no page \(identifier) for a WebView")
                    }
                }
        }
    }
}
#endif
