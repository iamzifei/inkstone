#if os(macOS)
import Combine
import Sparkle
import SwiftUI

/// In-app updates, via Sparkle.
///
/// macOS only, and the whole file is inside `#if os(macOS)` rather than the
/// dependency being conditionally imported: Sparkle's package declares no iOS
/// platform, so the dependency in project.yml carries `destinationFilters:
/// [macOS]` and on an iOS build the module does not exist to import at all.
///
/// Three things about running this inside the App Sandbox, all of which are
/// required together and none of which fail loudly if you forget one:
///
///   * `SUEnableInstallerLauncherService` in Info.plist, so Sparkle installs
///     through its Installer XPC service instead of trying to replace the app
///     bundle from inside the sandbox, which it cannot do.
///   * Two `com.apple.security.temporary-exception.mach-lookup.global-name`
///     entries, `<bundle-id>-spks` and `<bundle-id>-spki`, so the app is allowed
///     to talk to that service. Without them the updater silently does nothing.
///   * `com.apple.security.network.client`, which the app already has for GitHub
///     sync. Because it does, Sparkle's *Downloader* XPC service is not needed
///     and `SUEnableDownloaderService` stays off — one fewer service to ship.
///
/// The temporary-exception entitlements are fine for Developer ID distribution,
/// which is how this app ships. They would be rejected by the Mac App Store, so
/// if it ever goes there, this is the thing that has to change.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Sparkle refuses overlapping checks, so the menu item has to be able to go
    /// grey while one is in flight. This mirrors that state into SwiftUI, which
    /// cannot observe the KVO property directly.
    @Published private(set) var canCheck: Bool = false

    private var cancellable: AnyCancellable?

    init() {
        // `startingUpdater: true` begins the scheduled-check cycle immediately.
        // On first launch Sparkle asks the user whether to check automatically
        // rather than deciding for them, which is why no `SUEnableAutomaticChecks`
        // is set in Info.plist — writing that key would answer a question that is
        // the user's to answer.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        cancellable = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheck, on: self)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// The File menu is replaced wholesale by this app, but the "Check for
/// Updates…" item belongs in the application menu next to About, which is where
/// every other Mac app puts it.
struct CheckForUpdatesCommand: Commands {
    @ObservedObject var updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
        }
    }
}
#endif
