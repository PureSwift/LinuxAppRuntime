// `WebView` nodes: a `LinuxWebContent`'s frames, with the view's pointer and
// key input going to its page (`WebKit.md`). Scripts/sync-darwinui.sh keeps
// this file.
#if os(Linux)
import DynamicUI
import Foundation
import LinuxHost
import LinuxWebKit
import SwiftUI

/// A page's frames, at the size the view is offered.
struct HostWebView: View {

    let identifier: Int32

    @StateObject private var model = HostWebViewModel()

    @FocusState private var focused: Bool

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            frame
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            focused = true
                            model.drag(to: value.location)
                        }
                        .onEnded { value in
                            model.endDrag(at: value.location)
                        }
                )
                .onContinuousHover { phase in
                    if case let .active(location) = phase {
                        model.hover(at: location)
                    }
                }
                .focusable()
                .focused($focused)
                .onKeyPress(phases: .all) { press in
                    model.key(press)
                }
                .onChange(of: focused) { focused in
                    model.page?.focus(focused)
                }
                .onAppear {
                    model.attach(identifier, size: proxy.size, scale: displayScale)
                }
                .onChange(of: proxy.size) { size in
                    model.resize(size, scale: displayScale)
                }
                .onDisappear {
                    model.detach()
                }
        }
    }

    @ViewBuilder
    private var frame: some View {
        if let frame = model.frame {
            Image(pixels: frame.data, width: frame.width, height: frame.height, bytesPerRow: frame.width * 4,
                  scale: CGFloat(frame.scale))
                .resizable()
        } else {
            Color.white
        }
    }
}

/// The view's page and its latest frame.
final class HostWebViewModel: ObservableObject {

    @Published private(set) var frame: WebFrame?

    private(set) var page: LinuxWebContent?

    private var isDragging = false

    func attach(_ identifier: Int32, size: CGSize, scale: CGFloat) {
        guard page == nil else { return }
        guard let page = LinuxWebContent.page(identifier: identifier) else {
            HostLog.warning("web: no page \(identifier) for a WebView")
            return
        }
        self.page = page
        page.display = { [weak self] frame in
            self?.frame = frame
        }
        page.attach(width: UInt32(max(0, size.width.rounded())), height: UInt32(max(0, size.height.rounded())), scale: Float(scale))
    }

    func resize(_ size: CGSize, scale: CGFloat) {
        page?.resize(width: UInt32(max(0, size.width.rounded())), height: UInt32(max(0, size.height.rounded())), scale: Float(scale))
    }

    func detach() {
        page?.detach()
        page?.display = nil
        page = nil
        isDragging = false
    }

    // MARK: Pointer

    func drag(to location: CGPoint) {
        guard let page else { return }
        page.pointerMoved(x: Float(location.x), y: Float(location.y))
        if !isDragging {
            isDragging = true
            page.pointerButton(x: Float(location.x), y: Float(location.y), pressed: true)
        }
    }

    func endDrag(at location: CGPoint) {
        guard isDragging, let page else { return }
        isDragging = false
        page.pointerMoved(x: Float(location.x), y: Float(location.y))
        page.pointerButton(x: Float(location.x), y: Float(location.y), pressed: false)
    }

    func hover(at location: CGPoint) {
        guard !isDragging else { return }
        page?.pointerMoved(x: Float(location.x), y: Float(location.y))
    }

    // MARK: Keys

    func key(_ press: KeyPress) -> KeyPress.Result {
        guard let page, let keysym = Keysyms.keysym(for: press.key.character) else {
            return .ignored
        }
        let modifiers = press.modifiers
        page.key(keysym: keysym, pressed: press.phase != .up, control: modifiers.contains(.control),
                 shift: modifiers.contains(.shift), alt: modifiers.contains(.option), meta: modifiers.contains(.command))
        return .handled
    }
}

/// XKB keysyms, which libwpe's key events carry, for the keys Cacao
/// reports as characters.
enum Keysyms {

    static func keysym(for character: Character) -> UInt32? {
        switch character {
        case KeyEquivalent.return.character, "\n": return 0xFF0D
        case KeyEquivalent.escape.character: return 0xFF1B
        case KeyEquivalent.delete.character, "\u{7F}": return 0xFF08    // Backspace
        case KeyEquivalent.deleteForward.character: return 0xFFFF
        case KeyEquivalent.tab.character: return 0xFF09
        case KeyEquivalent.home.character: return 0xFF50
        case KeyEquivalent.leftArrow.character: return 0xFF51
        case KeyEquivalent.upArrow.character: return 0xFF52
        case KeyEquivalent.rightArrow.character: return 0xFF53
        case KeyEquivalent.downArrow.character: return 0xFF54
        case KeyEquivalent.pageUp.character: return 0xFF55
        case KeyEquivalent.pageDown.character: return 0xFF56
        case KeyEquivalent.end.character: return 0xFF57
        default: break
        }
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return nil
        }
        let value = scalar.value
        switch value {
        case 0x20...0x7E, 0xA0...0xFF:
            // Latin-1's keysyms are its code points.
            return value
        case 0x100...0x10FFFF where !(0xE000...0xF8FF).contains(value):
            // Other characters are Unicode keysyms; the private-use area
            // is where Cacao's function keys are.
            return 0x0100_0000 | value
        default:
            return nil
        }
    }
}
#endif
