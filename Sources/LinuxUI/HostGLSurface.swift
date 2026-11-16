// Node types this host draws itself, ahead of DarwinUI: `GLSurface`, a
// `LinuxSurface`'s frames and input (`Graphics.md`). Scripts/sync-darwinui.sh
// keeps this file and has NodeView ask `HostNodeViews` before it gives up
// on a type.
import DynamicGraphics
import DynamicUI
import Foundation
import LinuxGraphics
import LinuxHost
import SwiftUI

/// The views of node types DarwinUI doesn't know.
enum HostNodeViews {

    @MainActor
    static func view(for node: RenderNode, store: RenderStore) -> AnyView? {
        switch node.type {
        case "GLSurface":
            #if os(Linux)
            let identifier = Int32(clamping: node.props["surface"]?.int ?? 0)
            return AnyView(GLSurfaceView(identifier: identifier))
            #else
            // Apple's SwiftUI, for development: no GL here.
            return AnyView(Color.black)
            #endif
        default:
            return nil
        }
    }
}

#if os(Linux)

/// A surface's frames, with its pointer and key input going to it.
struct GLSurfaceView: View {

    let identifier: Int32

    @StateObject private var model = GLSurfaceModel()

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
                    model.surface?.focus(focused)
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
        if let pixels = model.pixels {
            Image(pixels: pixels.data, width: pixels.width, height: pixels.height, bytesPerRow: pixels.width * 4, scale: model.scale)
                .resizable()
        } else {
            Color.black
        }
    }
}

/// The view's surface and its latest frame.
final class GLSurfaceModel: ObservableObject {

    @Published private(set) var pixels: SurfacePixels?

    private(set) var surface: LinuxSurface?

    /// Pixels per point.
    private(set) var scale: CGFloat = 1

    private var isDragging = false

    func attach(_ identifier: Int32, size: CGSize, scale: CGFloat) {
        guard surface == nil else { return }
        guard let surface = LinuxSurface.surface(identifier: identifier) else {
            HostLog.warning("graphics: no surface \(identifier) for a GLSurface")
            return
        }
        self.surface = surface
        self.scale = scale
        surface.display = { [weak self] pixels in
            self?.pixels = pixels
        }
        let (width, height) = Self.pixelSize(size, scale: scale)
        surface.attach(width: width, height: height, scale: Float(scale))
    }

    func resize(_ size: CGSize, scale: CGFloat) {
        guard let surface else { return }
        self.scale = scale
        let (width, height) = Self.pixelSize(size, scale: scale)
        surface.resize(width: width, height: height, scale: Float(scale))
    }

    func detach() {
        surface?.detach()
        surface?.display = nil
        surface = nil
        isDragging = false
    }

    static func pixelSize(_ size: CGSize, scale: CGFloat) -> (Int32, Int32) {
        (Int32(clamping: Int((size.width * scale).rounded())), Int32(clamping: Int((size.height * scale).rounded())))
    }

    // MARK: Pointer

    func drag(to location: CGPoint) {
        let phase: PointerPhase = isDragging ? .move : .down
        isDragging = true
        pointer(phase, at: location, buttons: .primary)
    }

    func endDrag(at location: CGPoint) {
        guard isDragging else { return }
        isDragging = false
        pointer(.up, at: location, buttons: [])
    }

    func hover(at location: CGPoint) {
        guard !isDragging else { return }
        pointer(.move, at: location, buttons: [])
    }

    /// The mouse, pointer 0, at a point in the view: pixels of the drawable.
    private func pointer(_ phase: PointerPhase, at location: CGPoint, buttons: PointerButtons) {
        surface?.pointer(id: 0, kind: .mouse, phase: phase, x: Float(location.x * scale), y: Float(location.y * scale),
                         buttons: buttons, timestamp: MainLoop.now())
    }

    // MARK: Keys

    func key(_ press: KeyPress) -> KeyPress.Result {
        guard let surface, let code = HIDKeys.code(for: press.key.character) else {
            return .ignored
        }
        surface.key(code: code, pressed: press.phase != .up, modifiers: HIDKeys.modifiers(press.modifiers),
                    isRepeat: press.phase == .repeat, timestamp: MainLoop.now())
        return .handled
    }
}

/// USB HID usage IDs (Keyboard/Keypad page) for the keys Cacao reports,
/// which come as characters: positions on a US layout.
enum HIDKeys {

    static func code(for character: Character) -> Int32? {
        switch character {
        case KeyEquivalent.return.character, "\n": return 0x28
        case KeyEquivalent.escape.character: return 0x29
        case KeyEquivalent.delete.character, "\u{7F}": return 0x2A
        case KeyEquivalent.tab.character: return 0x2B
        case KeyEquivalent.space.character: return 0x2C
        case KeyEquivalent.rightArrow.character: return 0x4F
        case KeyEquivalent.leftArrow.character: return 0x50
        case KeyEquivalent.downArrow.character: return 0x51
        case KeyEquivalent.upArrow.character: return 0x52
        case KeyEquivalent.home.character: return 0x4A
        case KeyEquivalent.pageUp.character: return 0x4B
        case KeyEquivalent.deleteForward.character: return 0x4C
        case KeyEquivalent.end.character: return 0x4D
        case KeyEquivalent.pageDown.character: return 0x4E
        default: break
        }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.isASCII else {
            return nil
        }
        let value = scalar.value
        switch value {
        case 0x61...0x7A: return Int32(value - 0x61 + 0x04) // a–z
        case 0x41...0x5A: return Int32(value - 0x41 + 0x04) // A–Z, shifted
        case 0x31...0x39: return Int32(value - 0x31 + 0x1E) // 1–9
        case 0x30: return 0x27 // 0
        default: break
        }
        return punctuation[character]
    }

    /// Punctuation, and what Shift makes of it on a US layout.
    private static let punctuation: [Character: Int32] = [
        "-": 0x2D, "_": 0x2D, "=": 0x2E, "+": 0x2E, "[": 0x2F, "{": 0x2F, "]": 0x30, "}": 0x30,
        "\\": 0x31, "|": 0x31, ";": 0x33, ":": 0x33, "'": 0x34, "\"": 0x34, "`": 0x35, "~": 0x35,
        ",": 0x36, "<": 0x36, ".": 0x37, ">": 0x37, "/": 0x38, "?": 0x38,
        "!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24, "*": 0x25, "(": 0x26, ")": 0x27,
    ]

    static func modifiers(_ modifiers: EventModifiers) -> KeyModifiers {
        var result: KeyModifiers = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.alt) }
        if modifiers.contains(.command) { result.insert(.meta) }
        return result
    }
}

#endif
