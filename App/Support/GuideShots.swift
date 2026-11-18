#if DEBUG && os(macOS)
import AppKit
import SwiftUI
import InkstoneCore

/// Renders the welcome guide's screenshots from the app's real views, with no
/// screen capture and no synthetic input.
///
///     INKSTONE_GUIDE_SHOTS=<output dir> INKSTONE_GUIDE_SHOTS_ASSETS=<repo>/assets \
///       .../Inkstone.app/Contents/MacOS/Inkstone
///
/// For each of English, 简体中文 and 繁體中文 it copies a demo vault to a temporary
/// folder, opens it in a `Workspace` with the in-app language forced, puts the
/// real `RootView` (or `SettingsView`) in an `NSHostingView` and draws that into a
/// PNG. `scripts/make-guide-shots.py` then crops and compresses them into the
/// asset catalog.
///
/// Why this is not a screenshot script: other agents and people are using this
/// Mac, and a captured screen is whatever happened to be on it. Everything here
/// happens inside one process. The throwaway defaults suites keep it away from
/// the real vault list and settings; the vault is a temporary copy so the app's
/// own `.inkstone` folders never land in the repository.
///
/// Run it from an unsandboxed copy of the debug build (re-signed ad hoc with no
/// entitlements): the sandboxed app cannot read the repository or write the PNGs.
@MainActor
enum GuideShots {
    /// Render size in points. The website's original window was 1800 × 1130; the
    /// crops in `make-guide-shots.py` are expressed against that.
    static let windowSize = CGSize(width: 1800, height: 1130)

    private final class Flag: @unchecked Sendable { var done = false }

    static func runIfRequested() {
        guard let output = ProcessInfo.processInfo.environment["INKSTONE_GUIDE_SHOTS"],
              let assets = ProcessInfo.processInfo.environment["INKSTONE_GUIDE_SHOTS_ASSETS"]
        else { return }

        // No Dock icon, no menu bar, nothing on screen.
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)

        let flag = Flag()
        Task { @MainActor in
            await run(output: URL(fileURLWithPath: output), assets: URL(fileURLWithPath: assets))
            flag.done = true
        }
        // `init` runs before SwiftUI starts the main run loop, so spin it by hand.
        while !flag.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        FileHandle.standardOutput.write(Data("guide shots written to \(output)\n".utf8))
        exit(0)
    }

    private struct Language {
        let language: AppLanguage
        let vault: String
        /// What the sidebar's vault menu shows.
        let vaultName: String
        let note: (measure: String, home: String)
        let canvas: String
    }

    private static let languages: [Language] = [
        Language(language: .english, vault: "demo-vault", vaultName: "demo-vault",
                 note: ("The Measure.md", "Home.md"), canvas: "Map.canvas"),
        Language(language: .simplifiedChinese, vault: "demo-vault-zh", vaultName: "示例仓库",
                 note: ("行长.md", "首页.md"), canvas: "地图.canvas"),
        Language(language: .traditionalChinese, vault: "demo-vault-zh-Hant", vaultName: "示範儲存庫",
                 note: ("行長.md", "首頁.md"), canvas: "地圖.canvas"),
    ]

    private static func run(output: URL, assets: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for entry in languages {
            await render(entry, assets: assets, output: output)
        }
    }

    private static func render(_ entry: Language, assets: URL, output: URL) async {
        let code = entry.language.rawValue
        let suiteName = "com.orris.inkstone.guide-shots-\(code)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A temporary copy: opening a vault creates folders inside it.
        // Symlinks resolved: the index keys notes by their real path, and
        // /var/folders is a symlink to /private/var/folders, so a note opened by
        // the unresolved path would find no metadata and the inspector would
        // say "Nothing selected".
        // `resolvingSymlinksInPath` is no use here: Foundation deliberately maps
        // /private/var back to /var, which is the opposite of what the index uses.
        let temporary = FileManager.default.temporaryDirectory
        let realTemporary = temporary.path.withCString { pointer -> URL in
            guard let resolved = realpath(pointer, nil) else { return temporary }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
        let copy = realTemporary
            .appending(path: "guide-shots-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.copyItem(at: assets.appending(path: entry.vault), to: copy)
        } catch {
            FileHandle.standardError.write(Data("cannot copy vault \(entry.vault): \(error)\n".utf8))
            return
        }
        defer { try? FileManager.default.removeItem(at: copy) }

        let settings = AppSettings(defaults: defaults)
        settings.data.language = entry.language
        settings.data.appearance = .light
        let workspace = Workspace(registry: VaultRegistry(defaults: defaults), settings: settings)
        guard let vault = try? workspace.registry.register(folder: copy, name: entry.vaultName) else { return }
        workspace.open(vault, startingBackgroundWork: false)
        await settle(seconds: 2.0) { !workspace.isIndexing }

        let skills = SkillLibrary()
        let semantic = SemanticSearchService()

        func root(_ extra: AnyView = AnyView(EmptyView())) -> some View {
            StyledRoot {
                ZStack {
                    // The inset a real window's title bar gives the sidebar.
                    RootView()
                        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 30) }
                    extra
                }
            }
            .environment(workspace)
            .environment(skills)
            .environment(semantic)
            .preferredColorScheme(.light)
            .environment(\.locale, Locale(identifier: code))
        }

        // 1 + 2. A note with its sidebar and inspector: the folder and the links pages.
        workspace.openNote(at: copy.appending(path: entry.note.measure))
        await capture(root(), size: windowSize, to: output.appending(path: "\(code)-note.png"), wait: 3.0)

        // 3. The quick switcher over a note. Composited rather than presented as a
        // sheet: a sheet is a separate window and is not part of the hosting view.
        workspace.openNote(at: copy.appending(path: entry.note.home))
        await settle(seconds: 1.5)
        let switcher = ZStack {
            Color.black.opacity(0.18)
            QuickSwitcherView()
                .frame(width: 470, height: 400)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 20)
        }
        await capture(root(AnyView(switcher)), size: windowSize, to: output.appending(path: "\(code)-switcher.png"), wait: 2.5)

        // 4. The graph. Its layout is a simulation; give it time to settle.
        workspace.open(.graph(focus: nil))
        await settle(seconds: 5.0)
        await capture(root(), size: windowSize, to: output.appending(path: "\(code)-graph.png"), wait: 8.0)

        // 5. The canvas.
        workspace.open(.canvas(copy.appending(path: entry.canvas)))
        await settle(seconds: 2.5)
        await capture(root(), size: windowSize, to: output.appending(path: "\(code)-canvas.png"), wait: 3.0)

        // 6. Settings > Sync. `INKSTONE_OPEN_SETTINGS` is read when the view's
        // state is created, so set it before building the view.
        setenv("INKSTONE_OPEN_SETTINGS", "sync", 1)
        let sync = StyledRoot { SettingsView() }
            .environment(workspace)
            .environment(skills)
            .environment(semantic)
            .preferredColorScheme(.light)
            .environment(\.locale, Locale(identifier: code))
        await capture(sync, size: CGSize(width: 560, height: 460), to: output.appending(path: "\(code)-sync.png"), wait: 1.5)
        unsetenv("INKSTONE_OPEN_SETTINGS")
    }

    /// Lets async work (indexing, layout, `.task`) land. The outer loop in
    /// `runIfRequested` is what keeps the main run loop turning; sleeping here
    /// hands it the main actor.
    private static func settle(seconds: Double, until condition: (() -> Bool)? = nil) async {
        try? await Task.sleep(for: .seconds(seconds))
        if let condition {
            let limit = Date(timeIntervalSinceNow: 20)
            while !condition(), Date() < limit {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Puts `view` in a window, waits for its async work to land, and draws it
    /// into a 2x PNG.
    ///
    /// The window is ordered in, because SwiftUI only starts `.task` work (the
    /// graph's layout, the quick switcher's ranking) for views that are in a
    /// *visible* window. It sits at coordinates no display covers, so nothing
    /// appears on screen and nothing on screen is captured.
    private static func capture(_ view: some View, size: CGSize, to url: URL, wait: Double) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        // The default (true) frees the window on close() and ARC frees it again.
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        window.orderFrontRegardless()
        host.frame = NSRect(origin: .zero, size: size)
        await settle(seconds: wait)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        window.close()
    }
}
#endif
