#if os(macOS)
import SwiftUI
import InkstoneCore

/// One page of the welcome guide: a screenshot of the real app and two lines.
private struct GuidePage {
    /// Name of an image set in `Assets.xcassets` (cropped from the website's
    /// demo-vault screenshots, so no personal notes are ever shown).
    let image: String
    let icon: String
    let title: LocalizedStringKey
    let body: LocalizedStringKey
}

/// First-run welcome guide.
///
/// Six pages covering what a new user needs: choosing the notes folder,
/// wikilinks and backlinks, the quick switcher, the graph, the canvas, and
/// sync / settings. Shown once per `Onboarding.currentVersion` (see
/// `OnboardingLauncher`), and reopenable from Help > Show Welcome Guide.
///
/// Text is `LocalizedStringKey`, so it follows the app's own language setting
/// (the locale injected by `InkstoneApp`) and not only the system language.
struct OnboardingView: View {
    /// Scene identifier used by `openWindow` / `dismissWindow`.
    static let windowID = "welcome-guide"

    @Environment(\.style) private var style
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var page: Int

    init(page: Int = 0) { _page = State(initialValue: page) }

    private static let pages: [GuidePage] = [
        GuidePage(
            image: "GuideFolder", icon: "folder",
            title: "Pick a folder for your notes",
            body: "A vault is just a folder of Markdown files — no database, no import. Choose one with Open Folder as Vault or create one in iCloud Drive, and switch vaults from the vault name at the top of the sidebar."),
        GuidePage(
            image: "GuideLinks", icon: "link",
            title: "Connect notes with [[wikilinks]]",
            body: "Write [[Note name]] to link to another note. The inspector on the right lists every note that links back, along with tags, the outline and a small local graph."),
        GuidePage(
            image: "GuideSwitcher", icon: "magnifyingglass",
            title: "Jump anywhere with ⌘O",
            body: "Press ⌘O and start typing to open a note by name. If nothing matches, press Return to create a note with that name."),
        GuidePage(
            image: "GuideGraph", icon: "point.3.connected.trianglepath.dotted",
            title: "See how it all connects",
            body: "Graph View (⇧⌘G) draws the notes around the one you have open and the links between them. Whole Vault Graph (⌥⌘G) shows everything at once."),
        GuidePage(
            image: "GuideCanvas", icon: "rectangle.on.rectangle",
            title: "Think on a canvas",
            body: "New Canvas (⇧⌘N) opens a free-form board: drop in notes and text cards and connect them with arrows. It is saved as a standard .canvas file."),
        GuidePage(
            image: "GuideSync", icon: "arrow.triangle.2.circlepath",
            title: "Sync, and make it yours",
            body: "Keep a vault in iCloud Drive to sync it across your devices, or turn on GitHub sync in Settings (⌘,) › Sync. This guide is always under Help › Show Welcome Guide."),
    ]

    private var content: GuidePage { Self.pages[page] }
    private var isLast: Bool { page == Self.pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                Image(content.image)
                    .resizable()
                    .aspectRatio(1.6, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(style.divider, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    // The text beside it says everything the picture does.
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Label(content.title, systemImage: content.icon)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(style.accent)
                        .labelStyle(.titleAndIcon)
                    Text(content.body)
                        .font(style.uiFont)
                        .foregroundStyle(style.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 500)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            // The page index is the identity, so each page cross-fades instead
            // of the text jumping.
            .id(page)
            .transition(.opacity)

            footer
        }
        .frame(width: 640, height: 590)
        .background(style.background)
        .animation(.easeInOut(duration: 0.18), value: page)
        .background {
            // Esc closes, like any other window that is asking for nothing.
            Button("") { dismissWindow(id: Self.windowID) }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .opacity(page == 0 ? 0 : 1)
                .disabled(page == 0)

            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<Self.pages.count, id: \.self) { index in
                    Circle()
                        .fill(index == page ? style.accent : style.faintText.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Page \(page + 1) of \(Self.pages.count)"))
            Spacer()

            if isLast {
                Button("Start Writing") { dismissWindow(id: Self.windowID) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Next") { step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
    }

    private func step(_ delta: Int) {
        page = Onboarding.page(page, step: delta)
    }
}

#if DEBUG
extension OnboardingView {
    /// Renders every page in every language to PNGs, with no window involved.
    ///
    ///     INKSTONE_GUIDE_DUMP=1 .../Inkstone.app/Contents/MacOS/Inkstone
    ///
    /// Writes into the app's own temporary directory, because the app is
    /// sandboxed and cannot write anywhere else; the path is printed.
    ///
    /// Offscreen on purpose: looking at the real window means capturing a screen
    /// other people are working on. Long Chinese text wrapping onto a fourth
    /// line is the thing this is here to catch.
    @MainActor
    static func dumpIfRequested() {
        guard ProcessInfo.processInfo.environment["INKSTONE_GUIDE_DUMP"] != nil else { return }
        let directory = NSTemporaryDirectory() + "guide-dump"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for language in ["en", "zh-Hans", "zh-Hant"] {
            for page in 0..<Onboarding.pageCount {
                let view = OnboardingView(page: page)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.style, .fallback)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else {
                    FileHandle.standardError.write(Data("render failed: \(language) \(page)\n".utf8))
                    continue
                }
                let url = URL(fileURLWithPath: directory).appending(path: "guide-\(language)-\(page + 1).png")
                do { try png.write(to: url) } catch {
                    FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
                }
            }
        }
        FileHandle.standardOutput.write(Data("guide dumped to \(directory)\n".utf8))
        exit(0)
    }
}
#endif

/// Decides, once per launch, whether the guide should open by itself.
enum OnboardingLauncher {
    /// True when this install has not yet seen the current guide version. The
    /// flag is written on the spot: closing the window early is a clear "not
    /// now", and Help > Show Welcome Guide is one click away.
    @MainActor
    static func consumeFirstShow() -> Bool {
        #if DEBUG
        // Screenshot runs use a throwaway defaults suite; a guide window on top
        // of the shot would ruin it.
        if ProcessInfo.processInfo.environment["INKSTONE_DEMO_DEFAULTS"] != nil { return false }
        #endif
        let defaults = UserDefaults.standard
        let seen = defaults.integer(forKey: Onboarding.seenVersionKey)
        guard Onboarding.shouldShow(seenVersion: seen) else { return false }
        defaults.set(Onboarding.currentVersion, forKey: Onboarding.seenVersionKey)
        return true
    }
}

/// Help > Show Welcome Guide.
struct WelcomeGuideCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Show Welcome Guide") { openWindow(id: OnboardingView.windowID) }
        }
    }
}
#endif
