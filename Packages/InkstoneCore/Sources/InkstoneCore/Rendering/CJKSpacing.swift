import Foundation

/// Where a little space belongs between Chinese or Japanese and Latin text —
/// 「用 Inkstone 写」 rather than 「用Inkstone写」 — drawn as extra kerning so
/// the file itself never gains a space (copying a paragraph gives back exactly
/// what was typed). The editor and the reading view share this.
public enum CJKSpacing {

    /// The characters (UTF-16 ranges) that should carry the extra space
    /// after them: each one directly followed by text of the other kind
    /// (ideograph or kana ↔ ASCII letter or digit), within `range`. A
    /// character outside the BMP is two units, and the kerning goes on both.
    public static func positions(in text: NSString, range: NSRange) -> [NSRange] {
        guard range.length > 1 else { return [] }
        let string = text.substring(with: range)
        var positions: [NSRange] = []
        var offset = range.location
        var previous: (scalar: Unicode.Scalar, range: NSRange)?
        for scalar in string.unicodeScalars {
            let width = UTF16.width(scalar)
            if let previous {
                let boundary = (isIdeographOrKana(previous.scalar) && isLatinOrDigit(scalar))
                    || (isLatinOrDigit(previous.scalar) && isIdeographOrKana(scalar))
                // Kerning on a character widens the gap after it.
                if boundary { positions.append(previous.range) }
            }
            previous = (scalar, NSRange(location: offset, length: width))
            offset += width
        }
        return positions
    }

    /// Han (including the common extensions and compatibility block), and
    /// Japanese kana. Hangul is left out: Korean already separates words.
    public static func isIdeographOrKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2EBEF,
             0x3040...0x309F, 0x30A0...0x30FF:
            return true
        default:
            return false
        }
    }

    public static func isLatinOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value) || (0x41...0x5A).contains(scalar.value)
            || (0x61...0x7A).contains(scalar.value)
    }
}
