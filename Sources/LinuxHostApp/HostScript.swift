import Foundation
import LinuxHost
import LinuxSDL
import LinuxUI

/// Input to replay against the app's window and screenshots to take, one
/// command a line, for end-to-end tests and documentation:
///
/// ```
/// wait 200                 # milliseconds
/// dump                     # prints the layout
/// tap Increment            # the text drawn, clicked at its center
/// click 120 340            # points
/// rightclick 120 340
/// type Grace
/// key enter                # enter, escape, tab, backspace, left, alt+left, …
/// scroll 200 400 300       # x, y, points down
/// expect Count: 1          # fails the run if the text isn't drawn
/// screenshot shot.png
/// quit
/// ```
///
/// Each command runs on its own turn of the main loop, after the window has
/// drawn what the previous one changed. A failed `expect` or `tap` is
/// logged, and the host exits with status 1 at `quit`.
final class HostScript {

    enum ScriptError: Error, CustomStringConvertible {
        case unknown(line: Int, String)

        var description: String {
            switch self {
            case .unknown(let line, let command): "line \(line): unknown command \(command)"
            }
        }
    }

    private var commands: [(line: Int, verb: String, argument: String)] = []

    private var index = 0

    private(set) var failed = false

    init(contentsOf path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            let verb = String(parts[0])
            guard Self.verbs.contains(verb) else {
                throw ScriptError.unknown(line: number + 1, verb)
            }
            commands.append((number + 1, verb, parts.count > 1 ? String(parts[1]) : ""))
        }
    }

    static let verbs: Set<String> = ["dump", "wait", "tap", "click", "rightclick", "type", "key", "scroll", "expect", "screenshot", "quit"]

    private var window: RendererWindow? {
        SDLApp.shared?.windows.first
    }

    func start() {
        MainLoop.shared.schedule(after: 100_000_000) { [self] in step() }
    }

    private func next(after milliseconds: Int64 = 30) {
        MainLoop.shared.schedule(after: milliseconds * 1_000_000) { [self] in step() }
    }

    private func fail(_ line: Int, _ message: String) {
        HostLog.error("script line \(line): \(message)")
        failed = true
    }

    private func step() {
        guard index < commands.count else {
            MainLoop.shared.stop()
            return
        }
        let (line, verb, argument) = commands[index]
        index += 1
        guard let window else {
            fail(line, "no window")
            MainLoop.shared.stop()
            return
        }
        // What the last command changed is drawn by now: lay out again so
        // lookups see it.
        let frame = window.store.layout(size: window.size)
        switch verb {
        case "wait":
            next(after: Int64(argument) ?? 0)
            return
        case "dump":
            func dump(_ box: LayoutBox, _ depth: Int) {
                let f = box.frame
                print(String(repeating: "  ", count: depth) + "\(box.type) #\(box.id) (\(Int(f.minX)), \(Int(f.minY)), \(Int(f.width)) × \(Int(f.height)))")
                box.children.forEach { dump($0, depth + 1) }
            }
            frame.root.map { dump($0, 0) }
        case "tap":
            guard let rect = frame.rect(ofText: argument) else {
                fail(line, "no \"\(argument)\" on screen; it shows \(frame.texts)")
                break
            }
            click(window, Point(x: rect.midX, y: rect.midY), .primary)
        case "click", "rightclick":
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 2 else {
                fail(line, "\(verb) needs x and y")
                break
            }
            click(window, Point(x: numbers[0], y: numbers[1]), verb == "click" ? .primary : .secondary)
        case "type":
            window.inject(.text(argument))
        case "key":
            guard let (key, modifiers) = Self.key(argument) else {
                fail(line, "unknown key \(argument)")
                break
            }
            window.inject(.key(key, modifiers))
        case "scroll":
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 3 else {
                fail(line, "scroll needs x, y and a distance")
                break
            }
            window.inject(.scroll(Point(x: numbers[0], y: numbers[1]), dx: 0, dy: numbers[2]))
        case "expect":
            if frame.rect(ofText: argument) == nil {
                fail(line, "expected \"\(argument)\"; the window shows \(frame.texts)")
            }
        case "screenshot":
            window.screenshot(argument) { [self] saved in
                if !saved { fail(line, "can't save \(argument)") }
                next()
            }
            return
        case "quit":
            MainLoop.shared.stop()
            return
        default:
            break
        }
        next()
    }

    private func click(_ window: RendererWindow, _ point: Point, _ button: PointerButton) {
        window.inject(.pointerMove(point))
        window.inject(.pointerDown(point, button: button))
        window.inject(.pointerUp(point, button: button))
    }

    static func key(_ name: String) -> (Key, KeyModifiers)? {
        var modifiers: KeyModifiers = []
        var parts = name.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.popLast() else { return nil }
        for part in parts {
            switch part {
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            case "alt": modifiers.insert(.alt)
            default: return nil
            }
        }
        let keys: [String: Key] = [
            "backspace": .backspace, "delete": .delete, "left": .left, "right": .right, "up": .up, "down": .down,
            "home": .home, "end": .end, "enter": .enter, "return": .enter, "escape": .escape, "tab": .tab,
            "pageup": .pageUp, "pagedown": .pageDown,
        ]
        if let key = keys[last] {
            return (key, modifiers)
        }
        if last.count == 1, let character = last.first {
            return (.character(character), modifiers)
        }
        return nil
    }
}
