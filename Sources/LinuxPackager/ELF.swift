import Foundation

/// Reads what an ELF file needs from glibc: the versions in its
/// `.gnu.version_r` section, for `port.json`'s `min_glibc`
/// (`PortMaster.md` §1). Works for any architecture, 32- or 64-bit.
public enum ELF {

    /// The newest `GLIBC_x.y` the file needs, as `x.y`; `nil` if it needs no
    /// versioned glibc symbol or isn't ELF.
    public static func requiredGLIBC(_ url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return newest(versions(Array(data)).compactMap { $0.hasPrefix("GLIBC_") ? String($0.dropFirst(6)) : nil })
    }

    /// The newest of dotted versions: `2.35` over `2.4`.
    public static func newest(_ versions: [String]) -> String? {
        versions.max { compare($0, $1) }
    }

    static func compare(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }, right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0, r = index < right.count ? right[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// Every version name the file's `SHT_GNU_verneed` section asks for.
    static func versions(_ bytes: [UInt8]) -> [String] {
        guard bytes.count >= 52, bytes.starts(with: [0x7F, 0x45, 0x4C, 0x46]), bytes[5] == 1 else { return [] }
        let is64 = bytes[4] == 2
        func u16(_ offset: Int) -> Int {
            guard offset + 2 <= bytes.count else { return 0 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int {
            guard offset + 4 <= bytes.count else { return 0 }
            return u16(offset) | u16(offset + 2) << 16
        }
        func word(_ offset: Int) -> Int {
            is64 ? u32(offset) | u32(offset + 4) << 32 : u32(offset)
        }
        let sectionTable = word(is64 ? 0x28 : 0x20)
        let entrySize = u16(is64 ? 0x3A : 0x2E)
        let count = u16(is64 ? 0x3C : 0x30)
        struct Section { var type: Int; var offset: Int; var size: Int; var link: Int }
        var sections: [Section] = []
        for index in 0..<count {
            let base = sectionTable + index * entrySize
            guard base + entrySize <= bytes.count else { return [] }
            sections.append(Section(
                type: u32(base + 4),
                offset: word(base + (is64 ? 0x18 : 0x10)),
                size: word(base + (is64 ? 0x20 : 0x14)),
                link: u32(base + (is64 ? 0x28 : 0x18))
            ))
        }
        func string(_ table: Section, _ offset: Int) -> String {
            var end = table.offset + offset
            while end < bytes.count, end < table.offset + table.size, bytes[end] != 0 { end += 1 }
            let start = table.offset + offset
            return start < end ? String(decoding: bytes[start..<end], as: UTF8.self) : ""
        }
        var names: [String] = []
        for section in sections where section.type == 0x6FFF_FFFE && section.link < sections.count {
            let strings = sections[section.link]
            var need = section.offset
            while need + 16 <= bytes.count {
                // Elf_Verneed: version, cnt, file, aux, next.
                let auxCount = u16(need + 2)
                var aux = need + u32(need + 8)
                for _ in 0..<auxCount where aux + 16 <= bytes.count {
                    // Elf_Vernaux: hash, flags, other, name, next.
                    names.append(string(strings, u32(aux + 8)))
                    let next = u32(aux + 12)
                    if next == 0 { break }
                    aux += next
                }
                let next = u32(need + 12)
                if next == 0 { break }
                need += next
            }
        }
        return names
    }
}
