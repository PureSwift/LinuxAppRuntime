/// SF Symbols don't exist on Linux: common `systemName`s map to glyphs
/// that DejaVu Sans and Noto have, and the rest draw a placeholder.
public enum Symbols {

    /// Drawn for a name with no glyph.
    public static let placeholder = "◇"

    static let glyphs: [String: String] = [
        "plus": "+", "minus": "−", "xmark": "✕", "checkmark": "✓", "multiply": "×",
        "star": "☆", "star.fill": "★", "heart": "♡", "heart.fill": "♥",
        "trash": "⌫", "pencil": "✎", "square.and.pencil": "✎", "gear": "⚙", "gearshape": "⚙",
        "house": "⌂", "person": "☺", "person.circle": "☺", "person.crop.circle": "☺",
        "magnifyingglass": "⌕", "info": "ℹ", "info.circle": "ℹ", "questionmark": "?",
        "questionmark.circle": "?", "exclamationmark": "!", "exclamationmark.triangle": "⚠",
        "chevron.right": "›", "chevron.left": "‹", "chevron.down": "⌄", "chevron.up": "⌃",
        "chevron.forward": "›", "chevron.backward": "‹",
        "arrow.right": "→", "arrow.left": "←", "arrow.up": "↑", "arrow.down": "↓",
        "arrow.clockwise": "↻", "arrow.counterclockwise": "↺", "arrow.triangle.2.circlepath": "⟳",
        "square.and.arrow.up": "⇪", "square.and.arrow.down": "⇩", "envelope": "✉", "phone": "☎",
        "sun.max": "☀", "moon": "☾", "cloud": "☁", "bolt": "⚡", "flag": "⚑", "bookmark": "⚑",
        "list.bullet": "☰", "line.3.horizontal": "☰", "ellipsis": "…", "ellipsis.circle": "⋯",
        "circle": "○", "circle.fill": "●", "square": "□", "square.fill": "■",
        "checkmark.circle": "✓", "checkmark.square": "☑", "xmark.circle": "⊗",
        "plus.circle": "⊕", "minus.circle": "⊖", "music.note": "♪", "location": "➤",
        "paperplane": "➤", "clock": "◷", "calendar": "▦", "folder": "▤", "doc": "▤",
        "doc.text": "▤", "photo": "▨", "camera": "◉", "mic": "♫", "speaker": "♪",
        "bell": "♫", "lock": "⚿", "key": "⚷", "wifi": "≋", "antenna.radiowaves.left.and.right": "≋",
        "dot.radiowaves.left.and.right": "≋", "battery.100": "▮", "cart": "⊞", "tag": "⌗",
        "link": "⚭", "globe": "◍", "map": "⌖", "eye": "◉", "hand.thumbsup": "☝",
        "slider.horizontal.3": "☷", "line.3.horizontal.decrease": "☷", "sparkles": "✦",
        "flame": "♨", "leaf": "❦", "drop": "◒", "snowflake": "❄", "play": "▶", "play.fill": "▶",
        "pause": "⏸", "stop": "■", "forward": "⏩", "backward": "⏪", "shuffle": "⤨", "repeat": "⟳",
        "tray": "▭", "archivebox": "▣", "externaldrive": "▭", "printer": "⎙", "keyboard": "⌨",
    ]

    /// The glyph for `name`, trying it without `.fill`, `.circle` and
    /// similar suffixes before giving up.
    public static func glyph(_ name: String?) -> String {
        guard var name else { return placeholder }
        while true {
            if let glyph = glyphs[name] {
                return glyph
            }
            guard let dot = name.lastIndex(of: ".") else { return placeholder }
            name = String(name[..<dot])
        }
    }
}
