import Foundation

/// One contiguous run of changed lines.
///
/// The unit of review. A model asked to tidy a note usually touches several
/// unrelated places, and accepting or rejecting the whole thing means either
/// taking a change you did not want or losing four you did.
public struct Hunk: Sendable, Hashable, Identifiable {
    public let id: Int
    /// Lines replaced, as indices into the original. Empty for a pure insertion.
    public let removed: Range<Int>
    /// Lines put in their place. Empty for a pure deletion.
    public let added: [String]
    /// The original lines, kept so the view can show what is going away without
    /// holding the whole file.
    public let removedLines: [String]
    public var isAccepted: Bool

    public init(id: Int, removed: Range<Int>, removedLines: [String],
                added: [String], isAccepted: Bool = true) {
        self.id = id
        self.removed = removed
        self.removedLines = removedLines
        self.added = added
        self.isAccepted = isAccepted
    }

    public var isInsertion: Bool { removed.isEmpty }
    public var isDeletion: Bool { added.isEmpty }
}

/// A change the assistant proposes, not one it has made.
///
/// Writes do not reach disk when a tool runs. They accumulate here and are
/// applied only after a person has looked — which is the difference between an
/// assistant that helps with a vault and one that rewrites it while you read.
///
/// Accumulating rather than confirming each write is deliberate, and follows
/// what Zed settled on: a prompt per tool call interrupts the loop at the worst
/// moment, and after the third one nobody is reading them.
public struct PendingEdit: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Vault-relative.
    public let path: String
    /// Nil when the note is being created.
    public let before: String?
    /// What the assistant proposes the file should say.
    public let after: String
    public var hunks: [Hunk]
    /// What the assistant said it was doing, shown above the diff.
    public let summary: String

    public init(id: UUID = UUID(), path: String, before: String?, after: String,
                summary: String) {
        self.id = id
        self.path = path
        self.before = before
        self.after = after
        self.summary = summary
        self.hunks = Diff.hunks(from: before ?? "", to: after)
    }

    public var isCreation: Bool { before == nil }

    /// The text as it stands with the accepted hunks applied.
    ///
    /// Recomputed rather than stored, so toggling a hunk cannot leave the
    /// preview and the result saying different things.
    public var resolved: String {
        Diff.apply(hunks, to: before ?? "")
    }

    /// Whether anything at all would be written.
    public var hasAcceptedChanges: Bool {
        hunks.contains(where: \.isAccepted)
    }

    public var acceptedCount: Int { hunks.filter(\.isAccepted).count }

    public mutating func setAll(_ accepted: Bool) {
        for index in hunks.indices { hunks[index].isAccepted = accepted }
    }

    public mutating func toggle(_ hunkID: Int) {
        guard let index = hunks.firstIndex(where: { $0.id == hunkID }) else { return }
        hunks[index].isAccepted.toggle()
    }
}

/// Line-level diff.
///
/// Built on `CollectionDifference`, which is in the standard library and
/// implements Myers' algorithm — there is no reason to write another one, and a
/// hand-rolled diff is a rich source of quiet wrongness.
public enum Diff {
    /// Splits text into lines, keeping the distinction between "ends with a
    /// newline" and "does not".
    ///
    /// `split` would lose a trailing blank line, and a diff that quietly drops
    /// one rewrites the end of every file it touches.
    public static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    public static func join(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    /// Groups a line difference into hunks.
    public static func hunks(from before: String, to after: String) -> [Hunk] {
        let old = lines(before)
        let new = lines(after)
        let difference = new.difference(from: old)
        guard !difference.isEmpty else { return [] }

        // Removals and insertions arrive in separate lists, each ordered by
        // offset. Walking them together is what turns "line 4 removed, line 4
        // inserted" into one replacement rather than two hunks that a reader
        // has to mentally pair up.
        var removalsByOffset: [Int: String] = [:]
        for case let .remove(offset, element, _) in difference {
            removalsByOffset[offset] = element
        }
        var insertionsByOffset: [Int: String] = [:]
        for case let .insert(offset, element, _) in difference {
            insertionsByOffset[offset] = element
        }

        // Walk both files in step, emitting a hunk for each run of difference.
        var hunks: [Hunk] = []
        var oldIndex = 0
        var newIndex = 0
        var nextID = 0

        while oldIndex < old.count || newIndex < new.count {
            let removedHere = removalsByOffset[oldIndex] != nil
            let insertedHere = insertionsByOffset[newIndex] != nil

            if !removedHere && !insertedHere {
                // A line both files share.
                oldIndex += 1
                newIndex += 1
                continue
            }

            let startOld = oldIndex
            var removedLines: [String] = []
            var addedLines: [String] = []

            while oldIndex < old.count, removalsByOffset[oldIndex] != nil {
                removedLines.append(old[oldIndex])
                oldIndex += 1
            }
            while newIndex < new.count, insertionsByOffset[newIndex] != nil {
                addedLines.append(new[newIndex])
                newIndex += 1
            }

            // Neither side moved: the offsets disagree with the walk, which
            // would spin. Stepping both keeps the loop finite and costs at most
            // a hunk boundary in an unusual file.
            if removedLines.isEmpty && addedLines.isEmpty {
                oldIndex += 1
                newIndex += 1
                continue
            }

            hunks.append(Hunk(
                id: nextID,
                removed: startOld..<(startOld + removedLines.count),
                removedLines: removedLines,
                added: addedLines))
            nextID += 1
        }
        return hunks
    }

    /// Rebuilds the text with only the accepted hunks applied.
    public static func apply(_ hunks: [Hunk], to before: String) -> String {
        let old = lines(before)
        var result: [String] = []
        var index = 0

        // Hunks are in file order, so one pass suffices.
        for hunk in hunks.sorted(by: { $0.removed.lowerBound < $1.removed.lowerBound }) {
            // Everything between the last hunk and this one is unchanged.
            while index < hunk.removed.lowerBound, index < old.count {
                result.append(old[index])
                index += 1
            }
            if hunk.isAccepted {
                result += hunk.added
                index = hunk.removed.upperBound
            } else {
                // Rejected: keep what was there.
                while index < hunk.removed.upperBound, index < old.count {
                    result.append(old[index])
                    index += 1
                }
            }
        }
        while index < old.count {
            result.append(old[index])
            index += 1
        }
        return join(result)
    }
}

/// Every change waiting to be looked at.
public struct EditQueue: Sendable {
    public private(set) var edits: [PendingEdit] = []

    public init() {}

    public var isEmpty: Bool { edits.isEmpty }
    public var count: Int { edits.count }
    /// Notes touched, which is the number worth showing — five changes to one
    /// note is one file to review.
    public var affectedPaths: [String] {
        var seen: Set<String> = []
        return edits.compactMap { seen.insert($0.path).inserted ? $0.path : nil }
    }

    /// Adds a change, folding it into an earlier one for the same file.
    ///
    /// An agent asked to restructure a note commonly edits it several times in
    /// one turn. Kept separate, the reviewer would be shown a diff against a
    /// version that never existed on disk, twice.
    public mutating func add(_ edit: PendingEdit) {
        if let index = edits.firstIndex(where: { $0.path == edit.path }) {
            let original = edits[index].before
            edits[index] = PendingEdit(
                id: edits[index].id,
                path: edit.path,
                before: original,
                after: edit.after,
                summary: edits[index].summary == edit.summary
                    ? edit.summary
                    : edits[index].summary + "; " + edit.summary)
        } else {
            edits.append(edit)
        }
    }

    /// What the file should look like now, including changes not yet saved.
    ///
    /// This is what `read_note` must return once an edit is queued. Reading the
    /// file from disk would show the assistant its own change had not happened,
    /// and it would make it again.
    public func currentText(of path: String) -> String? {
        edits.first { $0.path == path }?.after
    }

    public mutating func remove(_ id: UUID) {
        edits.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        edits.removeAll()
    }

    public mutating func update(_ edit: PendingEdit) {
        guard let index = edits.firstIndex(where: { $0.id == edit.id }) else { return }
        edits[index] = edit
    }

    public mutating func setAll(_ accepted: Bool) {
        for index in edits.indices { edits[index].setAll(accepted) }
    }
}
