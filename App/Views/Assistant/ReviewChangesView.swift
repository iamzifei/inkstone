import SwiftUI
import InkstoneCore

/// The review step: what the assistant proposes, before any of it is saved.
///
/// A sheet rather than a prompt per tool call. Confirming each write
/// interrupts the loop at its worst moment — halfway through a task, with no
/// way to see where it is going — and by the third prompt nobody reads them.
/// Accumulating and reviewing once is what Zed settled on, and for the same
/// reason.
struct ReviewChangesView: View {
    @Binding var queue: EditQueue
    let onApply: ([PendingEdit]) -> Void
    let onDiscard: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.style) private var style

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(queue.edits) { edit in
                        EditReview(edit: binding(for: edit))
                    }
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 460)
        .background(style.background)
    }

    private func binding(for edit: PendingEdit) -> Binding<PendingEdit> {
        Binding(
            get: { queue.edits.first { $0.id == edit.id } ?? edit },
            set: { queue.update($0) })
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review changes")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(style.secondaryText)
            }
            Spacer()
            Button(String(localized: "Accept all")) { queue.setAll(true) }
            Button(String(localized: "Reject all")) { queue.setAll(false) }
        }
        .padding(14)
    }

    private var summary: String {
        let files = queue.count
        let hunks = queue.edits.reduce(0) { $0 + $1.hunks.count }
        let accepted = queue.edits.reduce(0) { $0 + $1.acceptedCount }
        return String(localized: "\(files) file\(files == 1 ? "" : "s"), \(accepted) of \(hunks) changes selected")
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "Discard all"), role: .destructive) {
                onDiscard()
                dismiss()
            }
            Spacer()
            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Save selected")) {
                onApply(queue.edits.filter(\.hasAcceptedChanges))
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!queue.edits.contains(where: \.hasAcceptedChanges))
        }
        .padding(14)
    }
}

/// One file's diff, with a checkbox on each hunk.
private struct EditReview: View {
    @Binding var edit: PendingEdit
    @Environment(\.style) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: edit.isCreation ? "doc.badge.plus" : "pencil")
                    .foregroundStyle(style.secondaryText)
                Text(edit.path)
                    .font(.callout.monospaced())
                Spacer()
                Text("\(edit.acceptedCount)/\(edit.hunks.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(style.faintText)
            }

            if !edit.summary.isEmpty {
                Text(edit.summary)
                    .font(.caption)
                    .foregroundStyle(style.secondaryText)
            }

            ForEach(edit.hunks) { hunk in
                HunkView(hunk: hunk) { edit.toggle(hunk.id) }
            }
        }
        .padding(12)
        .background(style.secondaryBackground, in: .rect(cornerRadius: 10, style: .continuous))
    }
}

/// One hunk: the lines going, the lines coming, and whether to take it.
private struct HunkView: View {
    let hunk: Hunk
    let toggle: () -> Void
    @Environment(\.style) private var style

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // A checkbox on the Mac, a switch on iOS. `.checkbox` is macOS-only
            // and the default there is a switch, which reads as a setting
            // rather than as a selection.
            #if os(macOS)
            Toggle("", isOn: Binding(get: { hunk.isAccepted }, set: { _ in toggle() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            #else
            Image(systemName: hunk.isAccepted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(hunk.isAccepted ? style.accent : style.faintText)
                .onTapGesture(perform: toggle)
            #endif

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.removedLines.enumerated()), id: \.offset) { _, text in
                    diffLine(text, sign: "−", tint: .red)
                }
                ForEach(Array(hunk.added.enumerated()), id: \.offset) { _, text in
                    diffLine(text, sign: "+", tint: .green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Dimmed rather than hidden when rejected: what is being left out
            // is as much a part of the review as what is going in.
            .opacity(hunk.isAccepted ? 1 : 0.4)
        }
        .padding(8)
        .background(style.background, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
    }

    private func diffLine(_ text: String, sign: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(sign)
                .foregroundStyle(tint)
            Text(text.isEmpty ? " " : text)
                .foregroundStyle(style.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(style.codeFont)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(tint.opacity(0.08))
    }
}
