#!/bin/bash
# Copies DarwinAppRuntime's SwiftUI renderer, DarwinUI, and its tests into
# LinuxUI, which builds it against Cacao's SwiftUI on Linux
# (Documentation/Plan.md §5). The sources stay as they are but for:
#
# - `import DarwinHost`, which is `LinuxHost` here (LinuxUI's Host.swift
#   supplies the logger and bundle DarwinUI uses);
# - `#if os(macOS)` code, which is for any platform but iOS: Linux is
#   neither;
# - NodeView, which asks `HostNodeViews` (HostNodeViews.swift) for a type
#   it doesn't know before giving up on it: `GLSurface` and `WebView` are
#   this host's.
#
# Files named Host*.swift are this host's own, and stay.
#
# RenderingTests hosts views in an NSHostingView; LinuxUI's own hosts them in
# a Cacao view graph, as Cacao's Compatibility/DarwinUI does. One test is
# disabled on Linux (below).
#
# DarwinAppRuntime comes from DARWIN_APP_RUNTIME_PATH, or a checkout beside
# this one.
set -e
cd "$(dirname "$0")/.."
source=${DARWIN_APP_RUNTIME_PATH:-../DarwinAppRuntime}
revision=$(git -C "$source" rev-parse --short HEAD)
mkdir -p Sources/LinuxUI Tests/LinuxUITests
find Sources/LinuxUI -name '*.swift' ! -name 'Host*.swift' -delete
find Tests/LinuxUITests -name '*.swift' ! -name 'RenderingTests.swift' -delete
for file in "$source"/Sources/DarwinUI/*.swift; do
    sed -e 's/^import DarwinHost$/import LinuxHost/' -e 's/^#if os(macOS)$/#if !os(iOS)/' \
        -e 's/^@testable import DarwinUI$/@testable import LinuxUI/' "$file" > "Sources/LinuxUI/$(basename "$file")"
done
perl -0pi -e 's/(\n        default:\n)(            UnknownTypes\.log\(node\.type\)\n)/$1            if let view = HostNodeViews.view(for: node, store: store) {\n                return view\n            }\n$2/' \
    Sources/LinuxUI/NodeView.swift
grep -q 'HostNodeViews.view' Sources/LinuxUI/NodeView.swift || { echo "NodeView no longer has the default case to hook" >&2; exit 1; }
for file in "$source"/Tests/DarwinUITests/*.swift; do
    case $(basename "$file") in RenderingTests.swift) continue ;; esac
    # On Linux, Swift Testing's main-actor tests don't run on the thread
    # `Thread.isMainThread` knows, so a renderer released in one removes its
    # scene a turn of the main queue later, as Cacao's Compatibility/DarwinUI
    # notes. In the host the guest releases renderers on the main thread.
    sed -e 's/^@testable import DarwinUI$/@testable import LinuxUI/' -e 's/^import DarwinUI$/import LinuxUI/' \
        -e 's/^#if os(macOS)$/#if !os(iOS)/' \
        -e 's/^    @Test func releasingTheRendererRemovesItsScene() {$/    @Test(.disabled("Linux: removed a turn later off the main thread")) func releasingTheRendererRemovesItsScene() {/' \
        "$file" > "Tests/LinuxUITests/$(basename "$file")"
done
echo "$revision" > Sources/LinuxUI/DARWINUI_REVISION
echo "DarwinUI at $revision"
