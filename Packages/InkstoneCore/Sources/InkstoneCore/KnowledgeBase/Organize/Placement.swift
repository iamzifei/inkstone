import Foundation

// MARK: - Naming (policy §2)

/// `YYYYMMDD-topic-keywords[-version].ext`, with noise words ("新建", "副本",
/// "(1)", "最终版最终", "copy" …) dropped, spaces as `-`, and none of
/// `/ \ : * ? " < > |`.
public enum FileNaming {
    /// Dropped anywhere in a name (they are never part of a word).
    static let noise = [
        "最终版最终", "最終版最終", "最终版", "最終版", "新建", "副本", "拷贝", "拷貝", "未命名",
    ]
    /// Dropped only as whole words: "copy" goes, "copyright" stays.
    static let noiseWords = ["untitled", "copy", "final"]

    public static func name(keywords raw: String, ext: String, date: Date, timeZone: TimeZone = .current) -> String {
        var k = raw
        k = k.replacingOccurrences(of: #"[（(]\s*\d+\s*[)）]"#, with: " ", options: .regularExpression)   // "(1)"
        for word in noise {
            k = k.replacingOccurrences(of: word, with: " ")
        }
        for word in noiseWords {
            k = k.replacingOccurrences(of: "(?i)\\b\(word)\\b", with: " ", options: .regularExpression)
        }
        k = k.replacingOccurrences(of: #"[/\\:*?"<>|]"#, with: "-", options: .regularExpression)
        k = k.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        k = k.replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
        k = k.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        // Leading 8-digit date already present: don't stamp it twice.
        let stamp = dateStamp(date, timeZone: timeZone)
        if k.hasPrefix(stamp) { k = String(k.dropFirst(stamp.count)).trimmingCharacters(in: CharacterSet(charactersIn: "-_ ")) }
        // Keep names a sane length (file names are limited to 255 bytes).
        while k.utf8.count > 120 { k.removeLast() }
        let base = k.isEmpty ? stamp : "\(stamp)-\(k)"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    public static func dateStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    public static func month(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }
}

// MARK: - The person's own rules (policy §3.5a)

/// Explicit rules from the rules file's own-rules section, one per line:
/// `keyword → folder/` (also `->` or `=>`); `*.ext → folder/` matches an
/// extension. They are tried before anything else.
public struct OrganizingRules: Sendable {
    public struct Rule: Sendable, Equatable {
        public var keyword: String        // lowercased; "*.pdf" style for extensions
        public var folder: String
    }
    public var rules: [Rule]

    static let sectionTitles = ["## 我的规则", "## 我的規則", "## My rules"]

    /// Only the own-rules section is read (up to the next heading): the
    /// policy below it is prose, and its arrows are not rules.
    public init(rulesFileText text: String) {
        var out: [Rule] = []
        var inSection = false
        var section: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.sectionTitles.contains(trimmed) { inSection = true; continue }
            if inSection, trimmed.hasPrefix("#") { break }
            if inSection { section.append(line) }
        }
        for line in section {
            var l = line.trimmingCharacters(in: .whitespaces)
            // Explanations and examples, not rules.
            if l.hasPrefix("（") || l.hasPrefix("(") || l.hasPrefix("<!--") || l.hasPrefix(">")
                || ["例如", "例：", "比如", "e.g.", "For example"].contains(where: l.contains) { continue }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l = String(l.dropFirst(2)) }
            for arrow in ["→", "=>", "->"] {
                let parts = l.components(separatedBy: arrow)
                guard parts.count == 2 else { continue }
                let keyword = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " `「」\"'"))
                let folder = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " `「」\"'/"))
                // A rule's keyword is short and its folder a relative path;
                // prose in the policy that happens to contain an arrow is not.
                if !keyword.isEmpty, keyword.count <= 40, !folder.isEmpty {
                    out.append(Rule(keyword: keyword.lowercased(), folder: folder))
                }
                break
            }
        }
        rules = out
    }

    public func match(_ facts: FileFacts) -> Rule? {
        let haystack = "\(facts.name) \(facts.title ?? "") \(facts.text.prefix(500))".lowercased()
        return rules.first { rule in
            if rule.keyword.hasPrefix("*.") { return facts.ext == String(rule.keyword.dropFirst(2)) }
            return haystack.contains(rule.keyword)
        }
    }
}

// MARK: - Privacy (policy rule 6)

enum PrivacyCheck {
    static let words = [
        "身份证", "身份證", "护照", "護照", "驾照", "駕照", "驾驶证", "户口", "戶口", "社保", "医保", "銀行卡", "银行卡",
        "银行流水", "銀行流水", "病历", "病歷", "体检", "體檢", "诊断", "診斷", "处方", "處方", "工资条", "薪资", "薪資",
        "税单", "稅單", "报税", "報稅", "密码", "密碼", "账号", "帳號", "信用卡", "卡号", "卡號", "社会保障", "医疗卡",
        "passport", "id card", "identity card", "driver licence", "driver license", "driving licence",
        "bank statement", "medical", "prescription", "diagnosis", "payslip", "pay slip", "salary", "tax return",
        "password", "social security", "ssn", "credit card", "card number", "tax file number", "tfn", "medicare",
        "national insurance", "bank account", "account number", "routing number", "iban",
    ]

    static func looksPrivate(_ facts: FileFacts) -> String? {
        let haystack = "\(facts.name) \(facts.title ?? "") \(facts.text.prefix(800))".lowercased()
        return words.first { haystack.contains($0) }
    }

    /// The same check over everything a prompt would carry (the whole
    /// excerpt, OCR included), before it is sent anywhere.
    static func looksPrivate(text: String) -> String? {
        let haystack = text.lowercased()
        return words.first { haystack.contains($0) }
    }
}

// MARK: - Advisor (an AI model, on device or the person's own)

/// What the organizer tells an advisor about the knowledge base.
public struct AdvisorContext: Sendable {
    public var layout: KnowledgeBaseLayout
    /// Existing folders it can file into (projects, areas, topics …), as
    /// vault-relative paths, two levels deep.
    public var folders: [String]
    /// The rules file's text (the person's rules plus the policy).
    public var rules: String
}

/// An advisor's suggestion for one file. The organizer checks it: a folder
/// outside the vault or inside its machinery is rejected, and below 0.7
/// confidence the file goes to review (policy §3.5d).
public struct PlacementAdvice: Sendable, Equatable {
    public var folder: String
    public var confidence: Double
    public var title: String?
    public var tags: [String]
    public var summary: String?
    public var isPrivate: Bool
    public var reason: String

    public init(folder: String, confidence: Double, title: String?, tags: [String], summary: String?, isPrivate: Bool, reason: String) {
        self.folder = folder; self.confidence = confidence; self.title = title; self.tags = tags
        self.summary = summary; self.isPrivate = isPrivate; self.reason = reason
    }
}

public protocol PlacementAdvisor: Sendable {
    /// nil: no opinion (model unavailable, file outside what it can read).
    func advise(_ facts: FileFacts, context: AdvisorContext) async throws -> PlacementAdvice?
}
