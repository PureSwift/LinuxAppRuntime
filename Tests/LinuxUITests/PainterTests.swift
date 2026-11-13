import DynamicUI
import Testing
@testable import LinuxUI

@Suite struct PainterTests {

    func draw(_ tree: RenderNode) -> RecordingCanvas {
        let (store, _) = makeStore(tree)
        let canvas = RecordingCanvas()
        Painter.draw(store.screen, on: canvas)
        return canvas
    }

    @Test func backgroundsRoundWithTheirCornerRadius() throws {
        let canvas = draw(text(1, "Hi", modifiers: [
            ModifierNode("padding", ["top": 8.0, "leading": 8.0, "bottom": 8.0, "trailing": 8.0]),
            ModifierNode("background", ["color": "blue"]),
            ModifierNode("cornerRadius", ["radius": 6.0]),
            ModifierNode("border", ["color": "red", "width": 2.0]),
        ]))
        let blue = Palette(scheme: .light).named("blue")!
        let fills = canvas.commands.compactMap { command -> (Color, Double)? in
            if case .fill(_, let color, let radius) = command { return (color, radius) } else { return nil }
        }
        #expect(fills.contains { $0.0 == blue && $0.1 == 6 })
        #expect(canvas.commands.contains { if case .stroke = $0 { true } else { false } })
        // Background, then text, then the border on top.
        let order = canvas.commands.compactMap { command -> String? in
            switch command {
            case .fill(_, let color, _) where color == blue: "background"
            case .text: "text"
            case .stroke: "border"
            default: nil
            }
        }
        #expect(order == ["background", "text", "border"])
    }

    @Test func opacityAndClipsBalance() {
        let canvas = draw(RenderNode("ScrollView", id: 1, modifiers: [ModifierNode("opacity", ["value": 0.5])], children: [
            text(2, "inside"),
        ]))
        let pushes = canvas.commands.filter { $0 == .pushOpacity(0.5) }.count
        let pops = canvas.commands.filter { $0 == .popOpacity }.count
        #expect(pushes == 1 && pops == 1)
        let clips = canvas.commands.filter { if case .pushClip = $0 { true } else { false } }.count
        #expect(clips == canvas.commands.filter { $0 == .popClip }.count)
    }

    @Test func disabledViewsDrawFaded() {
        let canvas = draw(RenderNode("Button", id: 1, modifiers: [ModifierNode("disabled", ["value": true])], children: [text(2, "Off")]))
        #expect(canvas.commands.first { if case .pushOpacity = $0 { true } else { false } } == .pushOpacity(0.45))
    }

    @Test func darkPaletteFillsTheWindow() {
        let store = RenderStore(textEngine: FixedTextEngine(), palette: Palette(scheme: .dark))
        store.apply(text(1, "x"))
        let canvas = RecordingCanvas()
        Painter.draw(store.layout(size: window), on: canvas)
        #expect(canvas.commands.first == .fill(Rect(origin: .zero, size: window), Palette(scheme: .dark).background, radius: 0))
        #expect(canvas.color(ofText: "x") == Palette(scheme: .dark).primary)
    }
}
