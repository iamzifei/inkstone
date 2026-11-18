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

    static func formatted(_ date: Date, moment: String, timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.dateFormat = unicodePattern(fromMoment: moment)
        return formatter.string(from: date)
    }

    /// Moment.js tokens → Unicode date-format pattern, longest token first.
    /// Letters that are not tokens, and `[bracketed]` text, become quoted
    /// literals so the formatter never reads them as fields.
    static func unicodePattern(fromMoment moment: String) -> String {
        let tokens: [(String, String)] = [
            ("YYYY", "yyyy"), ("YY", "yy"),
            ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
            ("dddd", "EEEE"), ("ddd", "EEE"),
            ("DDDD", "DDD"), ("DD", "dd"), ("Do", "d"), ("D", "d"),
            ("WW", "ww"), ("W", "w"),
            ("HH", "HH"), ("H", "H"), ("hh", "hh"), ("h", "h"),
            ("mm", "mm"), ("m", "m"), ("ss", "ss"), ("s", "s"),
            ("A", "a"), ("a", "a"),
        ]
        let chars = Array(moment)
        var out = ""
        var literal = ""
        func flushLiteral() {
            guard !literal.isEmpty else { return }
            out += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
            literal = ""
        }
        var i = 0
        while i < chars.count {
            if chars[i] == "[" {
                var j = i + 1
                while j < chars.count, chars[j] != "]" { j += 1 }
                literal += String(chars[(i + 1)..<min(j, chars.count)])
                i = min(j + 1, chars.count)
                continue
            }
            if let (token, unicode) = tokens.first(where: { t in
                let end = i + t.0.count
                return end <= chars.count && String(chars[i..<end]) == t.0
            }) {
                flushLiteral()
                out += unicode
                i += token.count
                continue
            }
            if chars[i].isLetter { literal.append(chars[i]) } else {
                flushLiteral()
                out.append(chars[i] == "'" ? "''" : String(chars[i]))
            }
            i += 1
        }
        flushLiteral()
        return out
    }
}
