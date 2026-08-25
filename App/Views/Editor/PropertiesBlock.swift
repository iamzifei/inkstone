import Foundation
import InkstoneCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The properties table drawn where a note's YAML frontmatter is.
///
/// Obsidian shows frontmatter as a properties table at the top of the note, in
/// both Live Preview and Reading view. Inkstone concealed it outright and put
/// the properties in the inspector instead — so a note's tags, aliases and
/// status were invisible unless a side panel happened to be open, and the
/// `showFrontmatterAsProperties` setting (on by default) was wired to nothing at
/// all.
///
/// Drawn by hand rather than with `NSTextAttachment`, for the same reason as the
/// inline images: TextKit 1 only makes an attachment glyph for U+FFFC, and the
/// text storage here *is* the file — it must not gain characters the author did
/// not type. So the frontmatter source is collapsed, its height reserved on the
/// first line, and this paints into the gap. It is the same idea as a CodeMirror
/// 6 *widget decoration* replacing a range, which is how Obsidian's own live
/// preview does it; only the mechanics differ.
@MainActor
final class PropertiesBlock: NSObject {
    struct Row {
        let key: String
        let value: String
        /// Tags and aliases are drawn as chips; everything else as plain text.
        let asChips: [String]
    }

    let rows: [Row]
    /// Total height to reserve, including padding above and below.
    let height: CGFloat

    // MARK: - Metrics
    //
    // Shared between measuring and drawing so the two can never disagree — the
    // failure mode there is a table that overlaps the first paragraph, which is
    // both ugly and hard to trace back.

    static let verticalPadding: CGFloat = 10
    static let rowSpacing: CGFloat = 4
    static let keyColumnWidth: CGFloat = 132
    static let chipPaddingX: CGFloat = 7
    static let chipPaddingY: CGFloat = 2
    static let chipSpacing: CGFloat = 5

    let font: PlatformFont
    let rowHeight: CGFloat

    init?(frontmatter: Frontmatter, source: String, style: Style) {
        let ordered = NotePropertyOrder.keys(of: frontmatter, in: source)
        guard !ordered.isEmpty else { return nil }

        let size = style.typography.interfaceFontSize
        font = style.typography.interfaceFont.platformFont(size: size)
        // `NSFont` has no `lineHeight`; ascender + |descender| + leading is what
        // the layout manager itself uses, and UIKit's `lineHeight` is that sum.
        rowHeight = ceil(font.ascender - font.descender + font.leading) + 5

        rows = ordered.map { key in
            let value = frontmatter.properties[key]
            let list = value?.stringList ?? []
            // A list reads as chips; a single value reads as text. Obsidian
            // draws tags as pills whatever the key is called, but a one-item
            // list of a long path is far more legible as plain text.
            let asChips = list.count > 1 || (list.count == 1 && Self.chipKeys.contains(key.lowercased()))
                ? list
                : []
            return Row(key: key, value: Self.describe(value), asChips: asChips)
        }

        height = Self.verticalPadding * 2
            + CGFloat(rows.count) * rowHeight
            + CGFloat(max(0, rows.count - 1)) * Self.rowSpacing
    }

    /// Keys whose single values still read better as a chip.
    private static let chipKeys: Set<String> = ["tags", "tag", "aliases", "alias", "cssclasses"]

    private static func describe(_ value: PropertyValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .list(let items): return items.compactMap(\.stringValue).joined(separator: ", ")
        default: return value.stringValue ?? ""
        }
    }
}
