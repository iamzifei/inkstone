#if os(macOS)
import SwiftUI
import InkstoneCore

/// One page of the welcome guide: a screenshot of the real app and two lines.
private struct GuidePage {
    /// Base name of the screenshot. The image sets are `<base>-en`,
    /// `<base>-zh-Hans` and `<base>-zh-Hant`, rendered from the app's real views
    /// in each language (`scripts/make-guide-shots.sh`) against a demo vault, so
    /// no personal notes are ever shown.
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
    static let size = CGSize(width: 640, height: 590)

    /// Scene identifier used by `openWindow` / `dismissWindow`.
    static let windowID = "welcome-guide"

    @Environment(\.style) private var style
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(Workspace.self) private var workspace
    @State private var page: Int

    init(page: Int = 0) { _page = State(initialValue: page) }

    private static let pages: [GuidePage] = [
        GuidePage(
            image: Onboarding.screenshots[0], icon: "folder",
            title: "Pick a folder for your notes",
            body: "A vault is just a folder of Markdown files — no database, no import. Choose one with Open Folder as Vault or create one in iCloud Drive, and switch vaults from the vault name at the top of the sidebar."),
        GuidePage(
            image: Onboarding.screenshots[1], icon: "link",
            title: "Connect notes with [[wikilinks]]",
            body: "Write [[Note name]] to link to another note. The inspector on the right lists every note that links back, along with tags, the outline and a small local graph."),
        GuidePage(
            image: Onboarding.screenshots[2], icon: "magnifyingglass",
            title: "Jump anywhere with ⌘O",
            body: "Press ⌘O and start typing to open a note by name. If nothing matches, press Return to create a note with that name."),
        GuidePage(
            image: Onboarding.screenshots[3], icon: "point.3.connected.trianglepath.dotted",
            title: "See how it all connects",
            body: "Graph View (⇧⌘G) draws the notes around the one you have open and the links between them. Whole Vault Graph (⌥⌘G) shows everything at once."),
        GuidePage(
            image: Onboarding.screenshots[4], icon: "rectangle.on.rectangle",
            title: "Think on a canvas",
            body: "New Canvas (⇧⌘N) opens a free-form board: drop in notes and text cards and connect them with arrows. It is saved as a standard .canvas file."),
        GuidePage(
            image: Onboarding.screenshots[5], icon: "arrow.triangle.2.circlepath",
            title: "Sync, and make it yours",
            body: "Keep a vault in iCloud Drive to sync it across your devices, or turn on GitHub sync in Settings (⌘,) › Sync. This guide is always under Help › Show Welcome Guide."),
    ]

    private var content: GuidePage { Self.pages[page] }
    private var isLast: Bool { page == Self.pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                if page == 0 { languagePicker }
                Image("\(content.image)-\(effectiveLanguage.rawValue)")
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
        .frame(width: Self.size.width, height: Self.size.height)
        .background(style.background)
        .background(FrontmostWindow())
        .animation(.easeInOut(duration: 0.18), value: page)
        .background {
            // Esc closes, like any other window that is asking for nothing.
            Button("") { dismissWindow(id: Self.windowID) }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// The language the picker shows: the saved choice, or — while the setting is
    /// still on "System" — the language the system's preferences resolve to, so
    /// the control never claims a language the guide is not in.
    /// The language the guide is showing, which is also the screenshot set.
    private var effectiveLanguage: AppLanguage {
        let saved = workspace.settings.data.language
        return saved == .system ? AppLanguage.resolving() : saved
    }

    private var selectedLanguage: Binding<AppLanguage> {
        Binding(
            get: { effectiveLanguage },
            // The app's own language setting, so the whole app follows — the
            // same value Settings > Language edits.
            set: { workspace.settings.data.language = $0 }
        )
    }

    private var languagePicker: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe").foregroundStyle(style.secondaryText)
            Picker("Language", selection: selectedLanguage) {
                // Endonyms, so each is readable whatever language is showing.
                ForEach(AppLanguage.allCases.filter { $0 != .system }) { language in
                    Text(verbatim: language.endonym).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Language"))
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
                let suite = UserDefaults(suiteName: "guide-dump-\(language)")!
                suite.removePersistentDomain(forName: "guide-dump-\(language)")
                let workspace = Workspace(registry: VaultRegistry(defaults: suite),
                                          settings: AppSettings(defaults: suite))
                workspace.settings.data.language = AppLanguage(rawValue: language) ?? .system
                let view = OnboardingView(page: page)
                    .environment(workspace)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.style, .fallback)
                // NSHostingView, not ImageRenderer: the language picker is an
                // AppKit segmented control, which ImageRenderer draws as a
                // yellow "prohibited" placeholder.
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: Self.size)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds),
                      let png = { host.cacheDisplay(in: host.bounds, to: rep); return rep.representation(using: .png, properties: [:]) }()
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
    @MainActor
    static func consumeFirstShow() -> Bool {
        #if DEBUG
        // Screenshot runs use a throwaway defaults suite; a guide window on top
        // of the shot would ruin it.
        if ProcessInfo.processInfo.environment["INKSTONE_DEMO_DEFAULTS"] != nil { return false }
        #endif
        return Onboarding.consumeFirstShow(in: .standard)
    }
}

/// Brings the window this sits in to the front and makes it key.
///
/// `openWindow` from the main window's `onAppear` can lose the race with the main
/// window finishing its own appearance, leaving the guide behind it — which for a
/// first launch is the whole point missed. So it is brought forward explicitly,
/// once straight away and once after the main window has settled.
private struct FrontmostWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        for delay in [0.0, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let window = view?.window else { return }
                window.collectionBehavior.insert(.moveToActiveSpace)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Help > Show Welcome Guide.
///
/// The title is passed in, already localised: menus do not receive the app's
/// `\.locale`, so a `LocalizedStringKey` here would answer in the system language.
struct WelcomeGuideCommand: Commands {
    let title: String
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button(title) { openWindow(id: OnboardingView.windowID) }
        }
    }
}
#endif
