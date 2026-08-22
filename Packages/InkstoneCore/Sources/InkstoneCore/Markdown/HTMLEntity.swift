import Foundation

/// Decodes the HTML entities Markdown allows: `&copy;` → `©`, `&#8212;` → `—`.
///
/// Numeric forms are decoded outright. Named ones come from a table rather than
/// the full HTML5 list of some two thousand names, and that is a deliberate
/// limit: the table holds the names that appear in prose, and an entity that is
/// not in it is left exactly as the author typed it. Leaving `&fjlig;` on screen
/// is the behaviour Inkstone had for every entity until now, so the floor does
/// not move — only the ceiling.
enum HTMLEntity {

    /// The character `source` stands for, or nil if it is not one we decode.
    ///
    /// - Parameter source: the whole entity including `&` and `;`.
    static func character(for source: String) -> String? {
        guard source.count > 2, source.hasPrefix("&"), source.hasSuffix(";") else { return nil }
        let body = source.dropFirst().dropLast()

        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            // Surrogates and out-of-range values have no character to stand for.
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }

        return named[String(body)]
    }

    /// Named entities that turn up in written prose. Anything absent is left as
    /// source, which is what every entity did before.
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…", "mdash": "—", "ndash": "–", "minus": "−",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "bull": "•", "middot": "·",
        "deg": "°", "plusmn": "±", "times": "×", "divide": "÷",
        "frac12": "½", "frac14": "¼", "frac34": "¾",
        "sup2": "²", "sup3": "³", "micro": "µ", "para": "¶", "sect": "§",
        "dagger": "†", "Dagger": "‡", "permil": "‰", "prime": "′", "Prime": "″",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "ne": "≠", "le": "≤", "ge": "≥", "asymp": "≈", "equiv": "≡",
        "infin": "∞", "sum": "∑", "prod": "∏", "radic": "√", "int": "∫",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "check": "✓", "cross": "✗", "star": "★", "hearts": "♥",
    ]
}
