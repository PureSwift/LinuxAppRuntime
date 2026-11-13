import DynamicUI
import Testing
@testable import LinuxUI

/// Layout with the fixed-width engine: a character is 0.55 × 15 = 8.25
/// points wide, a body line 19 points tall.
@Suite struct LayoutTests {

    func frame(_ tree: RenderNode) -> RenderFrame {
        makeStore(tree).0.screen
    }

    @Test func rootIsCenteredInTheWindow() throws {
        let screen = frame(text(1, "Hi"))
        let box = try #require(screen.root)
        #expect(box.frame.size == Size(width: 17, height: 19))
        #expect(box.frame.origin == Point(x: (400 - 17) / 2, y: (600 - 19) / 2))
    }

    @Test func vStackSpacingAndAlignment() throws {
        let stack = RenderNode("VStack", id: 1, props: ["alignment": "leading", "spacing": 4.0], children: [
            text(2, "Wide text"), text(3, "a"),
        ])
        let box = try #require(frame(stack).root)
        let wide = try #require(box.box(2)), narrow = try #require(box.box(3))
        #expect(box.frame.height == 19 * 2 + 4)
        #expect(narrow.frame.minY == wide.frame.maxY + 4)
        #expect(narrow.frame.minX == wide.frame.minX, "leading")
    }

    @Test func spacersTakeWhatsLeft() throws {
        let stack = RenderNode("HStack", id: 1, props: ["spacing": 0.0], modifiers: [
            ModifierNode("frame", ["maxWidth": .double(.infinity)]),
        ], children: [
            text(2, "L"), RenderNode("Spacer", id: 3), text(4, "R"),
        ])
        let box = try #require(frame(stack).root)
        #expect(box.frame.width == 400)
        #expect(try #require(box.box(2)).frame.minX == 0)
        #expect(try #require(box.box(4)).frame.maxX == 400)
    }

    @Test func flexibleChildrenShareEqually() throws {
        let stack = RenderNode("HStack", id: 1, props: ["spacing": 0.0], children: [
            RenderNode("Color", id: 2, props: ["color": "red"]),
            RenderNode("Color", id: 3, props: ["color": "blue"]),
            text(4, "fixed"),
        ])
        let box = try #require(frame(stack).root)
        let fixed = (5 * 8.25).rounded(.up)
        #expect(try #require(box.box(2)).frame.width == (400 - fixed) / 2)
        #expect(try #require(box.box(3)).frame.width == (400 - fixed) / 2)
    }

    @Test func paddingAndFixedFrames() throws {
        let node = text(1, "x", modifiers: [
            ModifierNode("padding", ["top": 10.0, "leading": 10.0, "bottom": 10.0, "trailing": 10.0]),
            ModifierNode("frame", ["width": 100.0, "height": 50.0]),
            ModifierNode("background", ["color": "red"]),
        ])
        let box = try #require(frame(node).root)
        #expect(box.frame.size == Size(width: 100, height: 50))
        // The padded text is centered in the frame; text sizes round up to
        // whole points.
        #expect(box.contentFrame.size == Size(width: 9, height: 19))
        #expect(box.contentFrame.midX == box.frame.midX)
        guard case .background(_, let rect)? = box.decorations.first else {
            Issue.record("no background")
            return
        }
        #expect(rect == box.frame, "the background fills the frame it's outside of")
    }

    @Test func textWrapsToTheWidthOffered() throws {
        // "one two" fits in 100 points; "one two three" doesn't.
        let node = text(1, "one two three four", modifiers: [ModifierNode("frame", ["width": 100.0])])
        let box = try #require(frame(node).root)
        #expect(box.contentFrame.height == 19 * 2)
        let limited = text(1, "one two three four", modifiers: [
            ModifierNode("lineLimit", ["lines": 1]),
            ModifierNode("frame", ["width": 100.0]),
        ])
        #expect(try #require(frame(limited).root).contentFrame.height == 19)
    }

    @Test func inheritedModifiersReachDescendants() throws {
        let stack = RenderNode("VStack", id: 1, modifiers: [
            ModifierNode("font", ["style": "title"]),
            ModifierNode("foregroundColor", ["color": "red"]),
        ], children: [text(2, "Title"), text(3, "Body", modifiers: [ModifierNode("font", ["style": "body"])])])
        let screen = frame(stack)
        let title = try #require(screen.root?.box(2)), body = try #require(screen.root?.box(3))
        guard case .text(_, let titleFont, let color, _, _, _)? = title.ops.first,
              case .text(_, let bodyFont, _, _, _, _)? = body.ops.first else {
            Issue.record("no text")
            return
        }
        #expect(titleFont.size == FontSpec.TextStyles.size("title"))
        #expect(bodyFont.size == FontSpec.TextStyles.size("body"), "the innermost wins")
        #expect(color == Palette(scheme: .light).named("red"))
    }

    @Test func unknownNodesAreEmpty() throws {
        let stack = RenderNode("VStack", id: 1, props: ["spacing": 0.0], children: [
            RenderNode("FutureView", id: 2, props: ["x": 1]), text(3, "after"),
        ])
        let box = try #require(frame(stack).root)
        #expect(try #require(box.box(2)).frame.height == 0)
    }

    @Test func gridColumnsFitTheirWidestCell() throws {
        let grid = RenderNode("Grid", id: 1, props: ["horizontalSpacing": 10.0, "verticalSpacing": 0.0], children: [
            RenderNode("GridRow", id: 2, children: [text(3, "a"), text(4, "b")]),
            RenderNode("GridRow", id: 5, children: [text(6, "long"), text(7, "c")]),
        ])
        let box = try #require(frame(grid).root)
        let b = try #require(box.box(4)), c = try #require(box.box(7))
        #expect(b.frame.minX == c.frame.minX, "one column")
        #expect(c.frame.minX - box.frame.minX == (4 * 8.25).rounded(.up) + 10)
    }

    @Test func adaptiveGridFitsColumnsOfItsMinimum() throws {
        let item: PropValue = .array(["adaptive", 60.0, .double(.infinity), 8.0, "center", "center"])
        let grid = RenderNode("LazyVGrid", id: 1, props: ["columns": .array([item]), "spacing": 8.0],
                              modifiers: [ModifierNode("frame", ["width": 300.0])],
                              children: (0..<7).map { RenderNode("Color", id: 10 + RenderNode.ID($0), props: ["color": "red"],
                                                                 modifiers: [ModifierNode("frame", ["height": 60.0])]) })
        let box = try #require(frame(grid).root)
        // (300 + 8) / (60 + 8) = 4 columns, so 7 items take 2 rows.
        let first = try #require(box.box(10)), fourth = try #require(box.box(13)), fifth = try #require(box.box(14))
        #expect(fifth.frame.minY > fourth.frame.minY)
        #expect(fourth.frame.minY == first.frame.minY)
        #expect(box.contentFrame.height == 60 * 2 + 8)
    }

    @Test func symbolsFallBackThroughTheirSuffixes() {
        #expect(Symbols.glyph("star.fill") == "★")
        #expect(Symbols.glyph("arrow.up.arrow.down") == "↑")
        #expect(Symbols.glyph("no.such.symbol") == Symbols.placeholder)
        #expect(Symbols.glyph(nil) == Symbols.placeholder)
    }

    @Test func paletteColors() {
        let palette = Palette(scheme: .dark)
        #expect(palette.color("red") == Color(hex: 0xF66151))
        #expect(palette.color(.array(["blue", 0.5])) == Color(hex: 0x62A0EA, alpha: 0.5))
        #expect(palette.color(.int(0x80FF0000)) == Color(red: 1, green: 0, blue: 0, alpha: 128.0 / 255))
        #expect(palette.color("chartreuse") == nil)
    }
}
