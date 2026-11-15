import DynamicUI
import Testing
@testable import LinuxUI

/// Shapes, pull to refresh and context menus.
@Suite struct VocabularyTests {

    func shape(_ props: [String: PropValue]) -> RenderNode {
        RenderNode("Shape", id: 2, props: props, modifiers: [ModifierNode("frame", ["width": 40.0, "height": 20.0])])
    }

    func ops(_ node: RenderNode) throws -> [LayoutBox.Op] {
        try #require(makeStore(node).0.screen.root).ops
    }

    @Test func shapesFillStrokeOrTakeTheForeground() throws {
        let palette = Palette(scheme: .light)
        guard case .fill(let rect, let color, let radius)? = try ops(shape(["shape": "circle", "fill": "red"])).first else {
            Issue.record("no fill")
            return
        }
        #expect(rect.size == Size(width: 20, height: 20), "a circle is as wide as it's tall")
        #expect(color == palette.named("red") && radius == 10)

        guard case .fill(_, let capsule, let capsuleRadius)? = try ops(shape(["shape": "capsule"])).first else {
            Issue.record("no fill")
            return
        }
        #expect(capsule == palette.primary, "no fill or stroke: the foreground color")
        #expect(capsuleRadius == 10)

        guard case .stroke(_, let stroke, let width, _)? = try ops(shape(["shape": "roundedRectangle", "cornerRadius": 4.0,
                                                                            "stroke": "blue", "lineWidth": 2.0])).first else {
            Issue.record("no stroke")
            return
        }
        #expect(stroke == palette.named("blue") && width == 2)
    }

    func refreshableList(refreshing: Bool) -> RenderNode {
        RenderNode("Refreshable", id: 1, props: ["refreshing": .bool(refreshing)], children: [
            RenderNode("List", id: 2, children: (0..<3).map { text(10 + RenderNode.ID($0), "Row \($0)") }),
        ])
    }

    @Test func pullingPastTheTopRefreshes() {
        let (store, guest) = makeStore(refreshableList(refreshing: false))
        #expect(store.screen.texts.contains("Row 0"), "it stands in for its list")
        let point = Point(x: 200, y: 300)
        store.handle(.scroll(point, dx: 0, dy: -40), size: window)
        #expect(guest.refreshes.isEmpty, "not far enough")
        store.handle(.scroll(point, dx: 0, dy: -40), size: window)
        #expect(guest.refreshes == [1])

        // While refreshing: a spinner, and no second refresh.
        store.apply(refreshableList(refreshing: true))
        let spinner = store.screen.root?.overlayOps.contains { if case .circle = $0 { true } else { false } }
        #expect(spinner == true)
        store.handle(.scroll(point, dx: 0, dy: -200), size: window)
        #expect(guest.refreshes == [1])
    }

    @Test func contextMenusJoinSwipeActions() {
        let row = RenderNode("SwipeActions", id: 10, children: [
            RenderNode("ContextMenu", id: 11, children: [text(12, "Row"), button(13, "Pin")]),
            button(14, "Delete", role: "destructive"),
        ])
        let (store, guest) = makeStore(RenderNode("List", id: 1, children: [row]))
        #expect(store.screen.texts.contains("Row") && !store.screen.texts.contains("Pin"))
        store.tap("Row", button: .secondary)
        let popup = store.screen.texts
        #expect(popup.filter { $0 == "Pin" }.count == 1 && popup.filter { $0 == "Delete" }.count == 1, "each item once")
        store.tap("Pin")
        #expect(guest.events == [.init(id: 13, kind: .tap)])
    }
}
