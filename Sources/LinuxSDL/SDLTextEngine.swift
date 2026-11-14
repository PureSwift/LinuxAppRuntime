import CSDL3
import CSDL3TTF
import Foundation
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
            HostLog.error("SDL3_ttf didn't start: \(lastSDLError())")
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
            HostLog.error("can't open \(path): \(lastSDLError())")
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

    // MARK: Finding fonts

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
        let path = Fontconfig.shared?.match(family: family, weight: spec.weight, italic: spec.italic)
            ?? FontDirectory.shared?.match(design: spec.design, weight: spec.weight, italic: spec.italic)
        if let path {
            paths[key] = path
        }
        return path
    }
}

/// fontconfig, loaded at run time: handhelds often don't have it, and then
/// the host uses `LINUXAPPRUNTIME_FONTS` (`PortMaster.md` §4).
final class Fontconfig {

    nonisolated(unsafe) static let shared = Fontconfig()

    private typealias Pattern = OpaquePointer

    private let patternCreate: @convention(c) () -> Pattern?
    private let patternDestroy: @convention(c) (Pattern?) -> Void
    private let addString: @convention(c) (Pattern?, UnsafePointer<CChar>, UnsafePointer<UInt8>) -> Int32
    private let addInteger: @convention(c) (Pattern?, UnsafePointer<CChar>, Int32) -> Int32
    private let addBool: @convention(c) (Pattern?, UnsafePointer<CChar>, Int32) -> Int32
    private let substitute: @convention(c) (OpaquePointer?, Pattern?, Int32) -> Int32
    private let defaultSubstitute: @convention(c) (Pattern?) -> Void
    private let fontMatch: @convention(c) (OpaquePointer?, Pattern?, UnsafeMutablePointer<Int32>) -> Pattern?
    private let getString: @convention(c) (Pattern?, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) -> Int32
    private let weightFromOpenType: @convention(c) (Int32) -> Int32

    private init?() {
        guard let library = dlopen("libfontconfig.so.1", RTLD_NOW) else { return nil }
        func bind<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let patternCreate = bind("FcPatternCreate", as: (@convention(c) () -> Pattern?).self),
              let patternDestroy = bind("FcPatternDestroy", as: (@convention(c) (Pattern?) -> Void).self),
              let addString = bind("FcPatternAddString", as: (@convention(c) (Pattern?, UnsafePointer<CChar>, UnsafePointer<UInt8>) -> Int32).self),
              let addInteger = bind("FcPatternAddInteger", as: (@convention(c) (Pattern?, UnsafePointer<CChar>, Int32) -> Int32).self),
              let addBool = bind("FcPatternAddBool", as: (@convention(c) (Pattern?, UnsafePointer<CChar>, Int32) -> Int32).self),
              let substitute = bind("FcConfigSubstitute", as: (@convention(c) (OpaquePointer?, Pattern?, Int32) -> Int32).self),
              let defaultSubstitute = bind("FcDefaultSubstitute", as: (@convention(c) (Pattern?) -> Void).self),
              let fontMatch = bind("FcFontMatch", as: (@convention(c) (OpaquePointer?, Pattern?, UnsafeMutablePointer<Int32>) -> Pattern?).self),
              let getString = bind("FcPatternGetString", as: (@convention(c) (Pattern?, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) -> Int32).self),
              let weightFromOpenType = bind("FcWeightFromOpenType", as: (@convention(c) (Int32) -> Int32).self) else {
            return nil
        }
        self.patternCreate = patternCreate
        self.patternDestroy = patternDestroy
        self.addString = addString
        self.addInteger = addInteger
        self.addBool = addBool
        self.substitute = substitute
        self.defaultSubstitute = defaultSubstitute
        self.fontMatch = fontMatch
        self.getString = getString
        self.weightFromOpenType = weightFromOpenType
    }

    /// fontconfig's best match, a file path; `nil` if it has no fonts.
    func match(family: String, weight: Int, italic: Bool) -> String? {
        guard let pattern = patternCreate() else { return nil }
        defer { patternDestroy(pattern) }
        _ = family.withCString { name in
            name.withMemoryRebound(to: UInt8.self, capacity: family.utf8.count + 1) { addString(pattern, "family", $0) }
        }
        _ = addInteger(pattern, "weight", weightFromOpenType(Int32(weight)))
        // FC_SLANT_ITALIC, FC_SLANT_ROMAN.
        _ = addInteger(pattern, "slant", italic ? 100 : 0)
        _ = addBool(pattern, "scalable", 1)
        // FcMatchPattern.
        guard substitute(nil, pattern, 0) != 0 else { return nil }
        defaultSubstitute(pattern)
        var result: Int32 = 0
        guard let match = fontMatch(nil, pattern, &result) else { return nil }
        defer { patternDestroy(match) }
        var file: UnsafeMutablePointer<UInt8>?
        // FcResultMatch.
        guard getString(match, "file", 0, &file) == 0, let file else { return nil }
        return String(cString: file)
    }
}

/// The fonts in `LINUXAPPRUNTIME_FONTS`, chosen by their file names:
/// `Mono`, `Serif`, or neither for sans-serif; `Bold`; `Oblique` or
/// `Italic`. DejaVu's names follow this.
final class FontDirectory {

    nonisolated(unsafe) static let shared: FontDirectory? = {
        guard let path = ProcessInfo.processInfo.environment["LINUXAPPRUNTIME_FONTS"] else { return nil }
        return FontDirectory(path: path)
    }()

    let files: [String]

    init?(path: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        files = names.filter { $0.lowercased().hasSuffix(".ttf") || $0.lowercased().hasSuffix(".otf") }.sorted()
            .map { path + "/" + $0 }
        if files.isEmpty { return nil }
    }

    func match(design: FontSpec.Design, weight: Int, italic: Bool) -> String? {
        func score(_ file: String) -> Int {
            let name = (file as NSString).lastPathComponent.lowercased()
            let mono = name.contains("mono"), serif = name.contains("serif") && !name.contains("sans")
            let bold = name.contains("bold"), slanted = name.contains("oblique") || name.contains("italic")
            let condensed = name.contains("condensed") || name.contains("extralight")
            var score = 0
            switch design {
            case .monospaced: score += mono ? 8 : 0
            case .serif: score += serif ? 8 : 0
            case .default, .rounded: score += !mono && !serif ? 8 : 0
            }
            score += bold == (weight >= 600) ? 4 : 0
            score += slanted == italic ? 2 : 0
            score += condensed ? 0 : 1
            return score
        }
        return files.max { score($0) < score($1) }
    }
}

/// SDL's last error message.
func lastSDLError() -> String {
    SDL_GetError().map { String(cString: $0) } ?? ""
}
