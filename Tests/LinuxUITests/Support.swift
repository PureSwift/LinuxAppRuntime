import DynamicUI
@testable import LinuxUI

/// Plays the guest: records events, and answers them as a guest would,
/// with an update before the call returns.
final class FakeGuest: RendererDelegate {

    struct Event: Equatable {
        var id: RenderNode.ID
        var kind: RenderEventKind
        var payload: PropValue?
    }

    var events: [Event] = []

    /// Answers an event, usually by sending the store a new tree.
    var reply: ((Event) -> Void)?

    /// Rows of lazy containers, by container and index.
    var rows: [RenderNode.ID: [RenderNode]] = [:]

    var rowRequests: [Int] = []

    func event(_ node: [UInt8], kind: Int32, payload: [UInt8]) {
        let event = Event(
            id: try! RenderCodec.decode(id: node),
            kind: RenderEventKind(rawValue: kind)!,
            payload: payload.isEmpty ? nil : try! RenderCodec.decode(payload: payload)
        )
        events.append(event)
        reply?(event)
    }

    func rowCount(_ list: [UInt8]) -> Int32 {
        Int32(rows[try! RenderCodec.decode(id: list)]?.count ?? 0)
    }

    func row(_ list: [UInt8], index: Int32) -> [UInt8] {
        rowRequests.append(Int(index))
        guard let rows = rows[try! RenderCodec.decode(id: list)], rows.indices.contains(Int(index)) else { return [] }
        return RenderCodec.encode(rows[Int(index)])
    }
}

let window = Size(width: 400, height: 600)

func makeStore(_ tree: RenderNode, guest: FakeGuest = FakeGuest()) -> (RenderStore, FakeGuest) {
    let store = RenderStore(textEngine: FixedTextEngine())
    store.delegate = guest
    store.apply(tree)
    store.layout(size: window)
    return (store, guest)
}

func text(_ id: RenderNode.ID, _ string: String, modifiers: [ModifierNode] = []) -> RenderNode {
    RenderNode("Text", id: id, props: ["text": .string(string)], modifiers: modifiers)
}

func button(_ id: RenderNode.ID, _ label: String, role: String? = nil) -> RenderNode {
    RenderNode("Button", id: id, props: role.map { ["role": .string($0)] } ?? [:], children: [text(id + 1000, label)])
}

extension RenderStore {

    /// Clicks the center of what draws `text`, topmost first.
    func tap(_ text: String, button: PointerButton = .primary) {
        let frame = layout(size: window)
        guard let rect = frame.rect(ofText: text) else {
            Issue.record("no \(text) on screen: \(frame.texts)")
            return
        }
        click(Point(x: rect.midX, y: rect.midY), button: button)
    }

    func click(_ point: Point, button: PointerButton = .primary) {
        handle(.pointerDown(point, button: button), size: window)
        handle(.pointerUp(point, button: button), size: window)
    }

    var screen: RenderFrame {
        layout(size: window)
    }
}

import Testing
