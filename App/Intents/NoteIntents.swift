import AppIntents
import Foundation
import InkstoneCore

// Shortcuts / Siri / Spotlight actions. They run inside the app without
// bringing it to the front, so a note can be captured from anywhere — a
// Shortcut, the Action button, a home-screen tap — and the vault is just
// files: the result is an ordinary Markdown note.

/// The app's workspace, for actions that run in the app's process. Set at
/// launch (before any window — Shortcuts can start the app in the background),
/// the same way the background-sync handlers get it.
@MainActor
enum IntentHost {
    static weak var current: Workspace?
    static func workspace() throws -> Workspace {
        guard let current else { throw Workspace.CaptureError.noVault }
        return current
    }
}

/// "New Note": a note with the given text, in the folder for new notes.
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Creates a note in your Inkstone vault.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "Title", description: "Taken from the first line of the text if left empty.")
    var noteTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("New note with \(\.$text)") { \.$noteTitle }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let url = try IntentHost.workspace().captureNewNote(title: noteTitle, text: text)
        let name = url.deletingPathExtension().lastPathComponent
        return .result(value: name, dialog: "Saved “\(name)”.")
    }
}

/// "Add to Today's Note": text appended to today's daily note.
struct AppendToDailyNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Today's Note"
    static let description = IntentDescription("Adds text to the end of today's daily note, creating the note if needed.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to today's note")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let url = try IntentHost.workspace().captureToDailyNote(text)
        return .result(dialog: "Added to “\(url.deletingPathExtension().lastPathComponent)”.")
    }
}

/// Ready-made shortcuts: they appear in the Shortcuts app and Spotlight
/// without the user building anything.
struct InkstoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AppendToDailyNoteIntent(),
            phrases: ["Add to today's note in \(.applicationName)",
                      "Add to my daily note in \(.applicationName)"],
            shortTitle: "Add to Today's Note",
            systemImageName: "calendar.badge.plus"
        )
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: ["New note in \(.applicationName)",
                      "Create a note in \(.applicationName)"],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil"
        )
    }
}
