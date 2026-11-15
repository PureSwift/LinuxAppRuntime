import DynamicUI
import Foundation
import Testing
@testable import LinuxUI

/// Shapes, pull to refresh, context menus and date pickers.
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

    // MARK: Date pickers

    /// 2025-07-08 18:40 UTC.
    static let july8 = 1_752_000_000.0

    func datePicker(_ value: Double, components: String = "date,hourAndMinute", max: Double? = nil) -> (RenderStore, FakeGuest) {
        var props: [String: PropValue] = ["title": "Picked", "value": .double(value), "components": .string(components)]
        if let max { props["max"] = .double(max) }
        let guest = FakeGuest()
        let store = RenderStore(textEngine: FixedTextEngine())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        store.calendar = calendar
        store.delegate = guest
        store.apply(RenderNode("DatePicker", id: 2, props: props))
        return (store, guest)
    }

    func click(_ store: RenderStore, _ type: String) throws {
        let box = try #require(store.screen.find(type), "no \(type)")
        store.click(Point(x: box.frame.midX, y: box.frame.midY))
    }

    @Test func datePickersShowDateAndTime() throws {
        let (store, _) = datePicker(Self.july8)
        let texts = store.screen.texts
        #expect(texts.contains("Picked"))
        #expect(texts.contains("Jul 8, 2025"))
        #expect(texts.contains { $0.contains("6:40") }, "the time, short")
        let dateOnly = datePicker(Self.july8, components: "date").0.screen
        #expect(dateOnly.find("DatePicker.time") == nil)
    }

    @Test func popoversStepAField() throws {
        let (store, guest) = datePicker(Self.july8)
        try click(store, "DatePicker.date")
        #expect(store.screen.texts.contains("Jul") && store.screen.texts.contains("2025"), "month and year rows")
        try click(store, "DatePopover.day+")
        try click(store, "DatePopover.month-")
        #expect(guest.events.map(\.payload) == [.double(Self.july8 + 86_400), .double(Self.july8 - 30 * 86_400)])

        // A click outside closes it; the time pill opens hours and minutes.
        store.click(Point(x: 1, y: 1))
        #expect(store.screen.find("DatePopover") == nil)
        try click(store, "DatePicker.time")
        #expect(store.screen.find("DatePopover.hour+") != nil && store.screen.find("DatePopover.day+") == nil)
        store.handle(.key(.escape, []), size: window)
        #expect(store.screen.find("DatePopover") == nil)
    }

    @Test func stepsStopAtTheBounds() throws {
        let (store, guest) = datePicker(Self.july8, max: Self.july8 + 3_600)
        try click(store, "DatePicker.date")
        try click(store, "DatePopover.day+")
        #expect(guest.events.map(\.payload) == [.double(Self.july8 + 3_600)], "clamped to max")
        store.apply(RenderNode("DatePicker", id: 2, props: ["title": "Picked", "value": .double(Self.july8 + 3_600),
                                                            "components": "date", "max": .double(Self.july8 + 3_600)]))
        try click(store, "DatePopover.day+")
        #expect(guest.events.count == 1, "nothing further: + is disabled")
    }
}
