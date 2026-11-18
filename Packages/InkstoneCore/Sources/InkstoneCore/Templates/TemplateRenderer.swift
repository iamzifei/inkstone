import Foundation

/// Fills in a template the way Obsidian's core Templates plugin does:
/// `{{title}}`, `{{date}}`, `{{time}}`, and `{{date:FORMAT}}` / `{{time:FORMAT}}`
/// with Moment.js format tokens. Anything else in braces (a Templater
/// expression, a typo) is left exactly as written.
public enum TemplateRenderer {
    public static func render(
        _ template: String,
        title: String,
        date: Date = .now,
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> String {
        let ns = template as NSString
        var out = ""
        var cursor = 0
        for match in placeholder.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let format = match.range(at: 2).location == NSNotFound ? nil
                : ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            switch name {
            case "title":
                out += title
            case "date":
                out += formatted(date, moment: format ?? "YYYY-MM-DD", timeZone: timeZone, locale: locale)
            default: // time
                out += formatted(date, moment: format ?? "HH:mm", timeZone: timeZone, locale: locale)
            }
            cursor = NSMaxRange(match.range)
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static let placeholder = try! NSRegularExpression(
        pattern: #"\{\{\s*(title|date|time)(?:\s*:([^}]*))?\s*\}\}"#, options: [.caseInsensitive])

    /// Renders a Moment.js format token by token. Most tokens map to one
    /// Unicode date field; the rest (ordinals, quarter, Unix time, lowercase
    /// am/pm) are computed. Letters that are not tokens, and `[bracketed]`
    /// text, are copied as written.
    static func formatted(_ date: Date, moment: String, timeZone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = locale
        func field(_ pattern: String) -> String {
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
        let parts = calendar.dateComponents([.day, .month], from: date)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 0

        // Longest first, so "DDDD" is not read as "DD" + "DD".
        let tokens: [(String, () -> String)] = [
            ("YYYY", { field("yyyy") }), ("GGGG", { field("YYYY") }), ("YY", { field("yy") }),
            ("MMMM", { field("MMMM") }), ("MMM", { field("MMM") }), ("MM", { field("MM") }),
            ("Mo", { ordinal(parts.month ?? 0) }), ("M", { field("M") }),
            ("dddd", { field("EEEE") }), ("ddd", { field("EEE") }),
            ("DDDD", { String(dayOfYear) }), ("DDD", { String(dayOfYear) }),
            ("DD", { field("dd") }), ("Do", { ordinal(parts.day ?? 0) }), ("D", { field("d") }),
            ("WW", { field("ww") }), ("W", { field("w") }),
            ("Q", { String(((parts.month ?? 1) - 1) / 3 + 1) }),
            ("HH", { field("HH") }), ("H", { field("H") }), ("hh", { field("hh") }), ("h", { field("h") }),
            ("mm", { field("mm") }), ("m", { field("m") }), ("ss", { field("ss") }), ("s", { field("s") }),
            ("A", { field("a") }), ("a", { field("a").lowercased() }),
            ("X", { String(Int(date.timeIntervalSince1970)) }),
            ("x", { String(Int(date.timeIntervalSince1970 * 1000)) }),
        ]
        let chars = Array(moment)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "[" {
                var j = i + 1
                while j < chars.count, chars[j] != "]" { j += 1 }
                out += String(chars[(i + 1)..<min(j, chars.count)])
                i = min(j + 1, chars.count)
                continue
            }
            if let (token, render) = tokens.first(where: { t in
                let end = i + t.0.count
                return end <= chars.count && String(chars[i..<end]) == t.0
            }) {
                out += render()
                i += token.count
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// English ordinal, as Moment's default locale: 1st, 2nd, 3rd, 11th, 21st.
    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}
