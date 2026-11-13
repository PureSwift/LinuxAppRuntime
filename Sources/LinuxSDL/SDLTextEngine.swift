import CSDL3
import LinuxHost
import LinuxUI

/// Text measured and drawn with SDL3_ttf, in fonts fontconfig picks
/// (`Plan.md` §5.3): `sans-serif`, `serif` and `monospace`, at the weight
/// and slant asked for.
///
/// Fonts open at `size × scale` pixels, so text is sharp on HiDPI displays;
/// sizes are reported in points.
public final class SDLTextEngine: TextEngine {

    public static let shared = SDLTextEngine()

    /// Pixels per point: the window's pixel density.
    public private(set) var scale: Double = 1

    private var paths: [PathKey: String] = [:]

    private var fonts: [FontKey: OpaquePointer] = [:]

    private struct PathKey: Hashable {
        let design: FontSpec.Design
        let weight: Int
        let italic: Bool
    }

    private struct FontKey: Hashable {
        let path: String
        let pixels: Int
    }

    private init() { }

    /// Starts SDL3_ttf. False if it can't, or there's no font.
    public func start() -> Bool {
        guard TTF_Init() else {
            HostLog.error("SDL3_ttf didn't start: \(SDL.error)")
            return false
        }
        guard font(.body) != nil else {
            HostLog.error("no font: install fonts-dejavu-core or another sans-serif font")
            return false
        }
        return true
    }

    /// Sets the pixel density, closing fonts opened at another.
    public func setScale(_ scale: Double) {
        guard scale > 0, scale != self.scale else { return }
        self.scale = scale
        for font in fonts.values {
            TTF_CloseFont(font)
        }
        fonts = [:]
    }

    /// The font for `spec` at the current scale.
    func font(_ spec: FontSpec) -> OpaquePointer? {
        guard let path = path(for: spec) else { return nil }
        let pixels = max(Int((spec.size * scale).rounded()), 1)
        let key = FontKey(path: path, pixels: pixels)
        if let font = fonts[key] {
            return font
        }
        guard let font = TTF_OpenFont(path, Float(pixels)) else {
            HostLog.error("can't open \(path): \(SDL.error)")
            return nil
        }
        TTF_SetFontHinting(font, TTF_HINTING_LIGHT)
        fonts[key] = font
        return font
    }

    // MARK: TextEngine

    public func lineHeight(_ font: FontSpec) -> Double {
        guard let ttf = self.font(font) else { return font.size * 1.25 }
        return Double(TTF_GetFontLineSkip(ttf)) / scale
    }

    public func width(_ text: String, font: FontSpec) -> Double {
        guard !text.isEmpty, let ttf = self.font(font) else { return 0 }
        var width: Int32 = 0, height: Int32 = 0
        _ = TTF_GetStringSize(ttf, text, 0, &width, &height)
        return Double(width) / scale
    }

    public func measure(_ text: String, font: FontSpec, maxWidth: Double?, lineLimit: Int?) -> Size {
        let line = lineHeight(font)
        guard !text.isEmpty, let ttf = self.font(font) else {
            return Size(width: 0, height: line)
        }
        var width: Int32 = 0, height: Int32 = 0
        // Centered or trailing wrapping measures as the whole wrap width.
        TTF_SetFontWrapAlignment(ttf, TTF_HORIZONTAL_ALIGN_LEFT)
        let wrap = maxWidth.map { max(Int32(($0 * scale).rounded(.down)), 1) } ?? 0
        _ = TTF_GetStringSizeWrapped(ttf, text, 0, wrap, &width, &height)
        var result = Size(width: Double(width) / scale, height: max(Double(height) / scale, line))
        if let lineLimit, lineLimit > 0 {
            result.height = min(result.height, Double(lineLimit) * line)
        }
        return result
    }

    // MARK: Fontconfig

    private func path(for spec: FontSpec) -> String? {
        let key = PathKey(design: spec.design, weight: spec.weight, italic: spec.italic)
        if let path = paths[key] {
            return path
        }
        let family: String
        switch spec.design {
        case .serif: family = "serif"
        case .monospaced: family = "monospace"
        case .default, .rounded: family = "sans-serif"
        }
        let path = Self.match(family: family, weight: spec.weight, italic: spec.italic)
        if let path {
            paths[key] = path
        }
        return path
    }

    /// Fontconfig's best match: a file path.
    static func match(family: String, weight: Int, italic: Bool) -> String? {
        guard let pattern = FcPatternCreate() else { return nil }
        defer { FcPatternDestroy(pattern) }
        _ = FcPatternAddString(pattern, FC_FAMILY, family)
        _ = FcPatternAddInteger(pattern, FC_WEIGHT, FcWeightFromOpenType(Int32(weight)))
        _ = FcPatternAddInteger(pattern, FC_SLANT, italic ? FC_SLANT_ITALIC : FC_SLANT_ROMAN)
        _ = FcPatternAddBool(pattern, FC_SCALABLE, 1)
        guard FcConfigSubstitute(nil, pattern, FcMatchPattern) != 0 else { return nil }
        FcDefaultSubstitute(pattern)
        var result = FcResultNoMatch
        guard let match = FcFontMatch(nil, pattern, &result) else { return nil }
        defer { FcPatternDestroy(match) }
        var file: UnsafeMutablePointer<FcChar8>?
        guard FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch, let file else { return nil }
        return String(cString: UnsafeRawPointer(file).assumingMemoryBound(to: CChar.self))
    }
}

/// SDL's error message.
enum SDL {
    static var error: String {
        SDL_GetError().map { String(cString: $0) } ?? ""
    }
}
