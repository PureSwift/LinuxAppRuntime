import DynamicUI
import Testing
@testable import LinuxUI

@Suite struct InputTests {

    // MARK: Buttons and controls

    @Test func tapsSendTapOnReleaseInside() throws {
        let (store, guest) = makeStore(RenderNode("VStack", id: 1, children: [button(2, "Go"), text(3, "label")]))
        store.tap("Go")
        #expect(guest.events == [.init(id: 2, kind: .tap)])

        // Released outside: nothing.
        let rect = try #require(store.screen.rect(ofText: "Go"))
        store.handle(.pointerDown(Point(x: rect.midX, y: rect.midY), button: .primary), size: window)
        #expect(store.isPressed(2))
        store.handle(.pointerMove(Point(x: 0, y: 0)), size: window)
        #expect(!store.isPressed(2))
        store.handle(.pointerUp(Point(x: 0, y: 0), button: .primary), size: window)
        #expect(guest.events.count == 1)
    }

    @Test func disabledViewsTakeNoInput() {
        let disabled = RenderNode("Button", id: 2, modifiers: [ModifierNode("disabled", ["value": true])], children: [text(3, "No")])
        let (store, guest) = makeStore(disabled)
        store.tap("No")
        #expect(guest.events.isEmpty)
    }

    @Test func onTapGestureReportsTap() {
        let (store, guest) = makeStore(text(2, "Tap me", modifiers: [ModifierNode("onTapGesture", ["count": 1])]))
        store.tap("Tap me")
        #expect(guest.events == [.init(id: 2, kind: .tap)])
    }

    @Test func togglesSteppersAndPickers() {
        let tree = RenderNode("VStack", id: 1, children: [
            RenderNode("Toggle", id: 2, props: ["isOn": false], children: [text(3, "Wi-Fi")]),
            RenderNode("Stepper", id: 4, props: ["value": 2, "min": 0, "max": 2, "step": 1], children: [text(5, "Count")]),
            RenderNode("Picker", id: 6, props: ["selection": 0, "style": "segmented"], children: [text(7, "One"), text(8, "Two")]),
        ])
        let (store, guest) = makeStore(tree)
        store.tap("Wi-Fi")
        store.tap("−")
        store.tap("+")
        store.tap("Two")
        #expect(guest.events == [
            .init(id: 2, kind: .change, payload: .bool(true)),
            .init(id: 4, kind: .change, payload: .int(1)),
            // + is disabled at the maximum.
            .init(id: 6, kind: .change, payload: .int(1)),
        ])
    }

    @Test func slidersDragInSteps() throws {
        let slider = RenderNode("Slider", id: 2, props: ["value": 0.0, "min": 0.0, "max": 10.0, "step": 1.0],
                                modifiers: [ModifierNode("frame", ["width": 210.0])])
        let (store, guest) = makeStore(slider)
        let box = try #require(store.screen.root)
        guard case .slider(_, _, _, _, _, let track)? = box.role else {
            Issue.record("not a slider")
            return
        }
        store.handle(.pointerDown(Point(x: track.minX, y: track.midY), button: .primary), size: window)
        store.handle(.pointerMove(Point(x: track.minX + track.width * 0.42, y: track.midY)), size: window)
        #expect(store.sliderValue(2, ir: 0) == 4, "shown while dragged")
        store.handle(.pointerUp(Point(x: track.maxX + 50, y: track.midY), button: .primary), size: window)
        #expect(guest.events.map(\.payload) == [.double(4), .double(10)])
        #expect(store.sliderValue(2, ir: 0) == 0, "the guest's value once released")
    }

    // MARK: Text fields

    @Test func textFieldsEditAndSyncWithTheGuest() throws {
        let field = { (text: String) in
            RenderNode("TextField", id: 2, props: ["text": .string(text), "placeholder": "Name"])
        }
        let guest = FakeGuest()
        let (store, _) = makeStore(field("Ada"), guest: guest)
        // The guest echoes each change.
        guest.reply = { event in
            if case .string(let text)? = event.payload { store.apply(field(text)) }
        }
        var focusEvents: [Bool] = []
        store.onTextInput = { active, _ in focusEvents.append(active) }

        let rect = try #require(store.screen.root).frame
        store.click(Point(x: rect.maxX - 2, y: rect.midY))
        #expect(store.focused == 2)
        store.handle(.text("!"), size: window)
        store.handle(.key(.backspace, []), size: window)
        store.handle(.key(.home, []), size: window)
        store.handle(.text("L"), size: window)
        store.handle(.key(.enter, []), size: window)
        #expect(guest.events == [
            .init(id: 2, kind: .change, payload: "Ada!"),
            .init(id: 2, kind: .change, payload: "Ada"),
            .init(id: 2, kind: .change, payload: "LAda"),
            .init(id: 2, kind: .submit),
        ])

        // The guest rewrites the text: the field takes it.
        store.apply(field("Grace"))
        #expect(store.editor(2, ir: "Grace").text == "Grace")
        // Clicking elsewhere ends editing.
        store.click(Point(x: 1, y: 1))
        #expect(store.focused == nil)
        #expect(focusEvents == [true, false])
    }

    @Test func clipboardAndTabFocus() throws {
        let tree = RenderNode("VStack", id: 1, children: [
            RenderNode("TextField", id: 2, props: ["text": "one"]),
            RenderNode("TextField", id: 3, props: ["text": "two"]),
        ])
        let (store, guest) = makeStore(tree)
        var clipboard = "pasted"
        store.clipboard = (get: { clipboard }, set: { clipboard = $0 })
        store.handle(.key(.tab, []), size: window)
        #expect(store.focused == 2)
        store.handle(.key(.character("c"), .control), size: window)
        #expect(clipboard == "one")
        store.handle(.key(.tab, []), size: window)
        #expect(store.focused == 3)
        store.handle(.key(.character("v"), .control), size: window)
        #expect(guest.events.last == .init(id: 3, kind: .change, payload: "twoone"))
    }

    // MARK: Menus and presentations

    @Test func menusOpenAPopupAndChoose() {
        let menu = RenderNode("Menu", id: 2, props: ["title": "Sort"], children: [
            button(3, "By Name"), RenderNode("Divider", id: 4), button(5, "Reversed"),
        ])
        let (store, guest) = makeStore(menu)
        store.tap("Sort")
        #expect(store.screen.overlays.count == 1)
        store.tap("Reversed")
        #expect(guest.events == [.init(id: 5, kind: .tap)])
        #expect(store.screen.overlays.isEmpty)

        // Escape closes it without choosing.
        store.tap("Sort")
        store.handle(.key(.escape, []), size: window)
        #expect(store.screen.overlays.isEmpty)
        // So does a click outside.
        store.tap("Sort")
        store.click(Point(x: 1, y: 599))
        #expect(store.screen.overlays.isEmpty)
        #expect(guest.events.count == 1)
    }

    @Test func swipeActionsAreTheRowsContextMenu() {
        let row = RenderNode("SwipeActions", id: 10, props: ["edge": "trailing"], children: [
            text(11, "Row"), button(12, "Delete", role: "destructive"),
        ])
        let (store, guest) = makeStore(RenderNode("List", id: 1, children: [row]))
        #expect(!store.screen.texts.contains("Delete"))
        store.tap("Row", button: .secondary)
        store.tap("Delete")
        #expect(guest.events == [.init(id: 12, kind: .tap)])
    }

    @Test func alertButtonsTapThenDismiss() {
        let alert = RenderNode("Alert", id: 2, props: ["title": "Reset?", "isPresented": true, "message": "Really."], children: [
            text(3, "Behind"), button(4, "Reset", role: "destructive"), button(5, "Cancel", role: "cancel"),
        ])
        let (store, guest) = makeStore(alert)
        #expect(store.screen.overlays.count == 1)
        #expect(store.screen.texts.contains("Really."))
        // The alert is modal.
        store.tap("Behind")
        #expect(guest.events.isEmpty)
        store.tap("Reset")
        #expect(guest.events == [.init(id: 4, kind: .tap), .init(id: 2, kind: .change, payload: .bool(false))])
    }

    @Test func alertsWithoutActionsGetOK() {
        let alert = RenderNode("Alert", id: 2, props: ["title": "Done", "isPresented": true], children: [text(3, "Behind")])
        let (store, guest) = makeStore(alert)
        store.tap("OK")
        #expect(guest.events == [.init(id: 2, kind: .change, payload: .bool(false))])
    }

    @Test func sheetsDismissWithEscapeOrTheBackdrop() {
        let sheet = RenderNode("Sheet", id: 2, props: ["isPresented": true, "style": "sheet"], children: [
            text(3, "Behind"), button(4, "Inside"),
        ])
        let (store, guest) = makeStore(sheet)
        store.tap("Inside")
        #expect(guest.events == [.init(id: 4, kind: .tap)])
        store.handle(.key(.escape, []), size: window)
        store.click(Point(x: 1, y: 1))
        #expect(guest.events.dropFirst() == [
            .init(id: 2, kind: .change, payload: .bool(false)),
            .init(id: 2, kind: .change, payload: .bool(false)),
        ])
    }

    // MARK: Navigation

    @Test func navigationShowsTheLastLevelAndPops() {
        let stack = RenderNode("NavStack", id: 1, children: [
            RenderNode("NavLevel", id: 2, props: ["title": "Home"], children: [text(3, "Root")]),
            RenderNode("NavLevel", id: 4, props: ["title": "Detail"], children: [
                text(5, "Leaf"),
                RenderNode("ToolbarItem", id: 6, props: ["placement": "primaryAction"], children: [button(7, "Edit")]),
            ]),
        ])
        let (store, guest) = makeStore(stack)
        let texts = store.screen.texts
        #expect(texts.contains("Leaf") && !texts.contains("Root"))
        #expect(texts.contains("Detail") && texts.contains("‹ Home"))
        store.tap("Edit")
        store.tap("‹ Home")
        store.handle(.key(.left, .alt), size: window)
        #expect(guest.events == [
            .init(id: 7, kind: .tap),
            .init(id: 1, kind: .pop, payload: .int(1)),
            .init(id: 1, kind: .pop, payload: .int(1)),
        ])
    }

    @Test func searchFieldsGoInTheNavigationBar() throws {
        let stack = RenderNode("NavStack", id: 1, children: [
            RenderNode("NavLevel", id: 2, props: ["title": "Home"], children: [
                RenderNode("Searchable", id: 3, props: ["text": "", "prompt": "Find"], children: [text(4, "Content")]),
            ]),
        ])
        let (store, guest) = makeStore(stack)
        let bar = try #require(store.screen.root?.find("NavBar"))
        #expect(bar.draws("Find"))
        store.tap("Find")
        store.handle(.text("a"), size: window)
        store.handle(.key(.enter, []), size: window)
        #expect(guest.events == [.init(id: 3, kind: .change, payload: "a"), .init(id: 3, kind: .submit)])
    }

    @Test func tabsAndDisclosureGroups() {
        let tabs = RenderNode("TabView", id: 1, props: ["selection": 0], children: [
            RenderNode("Tab", id: 2, props: ["title": "First"], children: [
                RenderNode("DisclosureGroup", id: 4, props: ["isExpanded": false], children: [text(5, "More"), text(6, "Hidden")]),
            ]),
            RenderNode("Tab", id: 3, props: ["title": "Second"], children: [text(7, "Two")]),
        ])
        let (store, guest) = makeStore(tabs)
        #expect(!store.screen.texts.contains("Hidden"))
        #expect(!store.screen.texts.contains("Two"))
        store.tap("More")
        store.tap("Second")
        #expect(guest.events == [
            .init(id: 4, kind: .change, payload: .bool(true)),
            .init(id: 1, kind: .change, payload: .int(1)),
        ])
    }

    // MARK: Lists and scrolling

    @Test func lazyListsFetchOnlyTheRowsThatShow() {
        let guest = FakeGuest()
        guest.rows[1] = (0..<1000).map { index in
            RenderNode("Button", id: 5000 + RenderNode.ID(index), children: [text(9000 + RenderNode.ID(index), "Row \(index)")])
        }
        let list = RenderNode("List", id: 1, props: ["revision": 1], count: 1000)
        let (store, _) = makeStore(list, guest: guest)
        let shown = Set(guest.rowRequests)
        #expect(shown.count < 20, "only the first screenful")
        #expect(store.screen.texts.contains("Row 0"))

        store.tap("Row 3")
        #expect(guest.events == [.init(id: 5003, kind: .tap)])

        store.handle(.scroll(Point(x: 200, y: 300), dx: 0, dy: 44 * 500), size: window)
        let texts = store.screen.texts
        #expect(texts.contains("Row 500"))
        #expect(!texts.contains("Row 0"))

        // A new revision fetches again.
        guest.rowRequests = []
        guest.rows[1]?[500] = RenderNode("Button", id: 5500, children: [text(9500, "Changed")])
        store.apply(RenderNode("List", id: 1, props: ["revision": 2], count: 1000))
        #expect(store.screen.texts.contains("Changed"))
    }

    @Test func scrollViewsClampTheirOffset() throws {
        let content = (0..<50).map { text(100 + RenderNode.ID($0), "Line \($0)") }
        let scroll = RenderNode("ScrollView", id: 1, props: ["axes": "vertical"], children: [
            RenderNode("VStack", id: 2, children: content),
        ])
        let (store, _) = makeStore(scroll)
        store.handle(.scroll(Point(x: 200, y: 300), dx: 0, dy: -100), size: window)
        #expect(store.scrollOffsets[1] == nil, "already at the top")
        store.handle(.scroll(Point(x: 200, y: 300), dx: 0, dy: 100_000), size: window)
        let box = try #require(store.screen.root)
        let last = try #require(box.box(149))
        #expect(abs(last.frame.maxY - box.frame.maxY) < 1, "scrolled to the end, no further")
    }

    @Test func replacingASubtreeKeepsTheRest() {
        let (store, _) = makeStore(RenderNode("VStack", id: 1, children: [text(2, "a"), text(3, "b")]))
        store.replace(3, with: text(3, "c"))
        #expect(store.screen.texts == ["a", "c"])
    }
}
