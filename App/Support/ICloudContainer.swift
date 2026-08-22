import Foundation
import Security
import InkstoneCore

/// Resolves the app's own iCloud container, and says why when it cannot.
///
/// Two things here are deliberate and neither is obvious:
///
///   - **The entitlement is read from the running binary's signature**, not
///     assumed from the entitlements file in the repository. Which file was used
///     is a build-time decision that a test harness can override, and did: the
///     debug build was signed with the sandbox-free development entitlements,
///     which carry no iCloud keys, and its perfectly correct `nil` was recorded
///     as evidence that the container did not exist.
///
///   - **The lookup runs off the main thread.** `url(forUbiquityContainerIdentifier:)`
///     is documented as potentially slow — it can wait on the ubiquity daemon —
///     and it was being called straight from a SwiftUI button action.
enum ICloudContainer {

    /// The container this app owns, as named in its entitlements.
    static let identifier = "iCloud.com.orris.inkstone"

    /// Diagnoses the container, off the main thread.
    static func resolve(_ identifier: String? = nil) async -> ICloudAvailability {
        let entitled = isEntitled
        let signedIn = FileManager.default.ubiquityIdentityToken != nil

        // Only ask the daemon when the answer could mean something. Skipping it
        // also keeps an unentitled build from paying the wait for a lookup that
        // is guaranteed to fail.
        var container: URL?
        if entitled && signedIn {
            container = await Task.detached(priority: .userInitiated) {
                FileManager.default.url(forUbiquityContainerIdentifier: identifier)
            }.value
        }

        return ICloudAvailability.diagnose(
            isEntitled: entitled,
            isSignedIn: signedIn,
            container: container
        )
    }

    /// The folder a vault lives in inside the container.
    ///
    /// `Documents/` and not the container root: only that subfolder is shown to
    /// the user in Finder's iCloud Drive, and a vault they cannot find in Finder
    /// is not the "your notes are plain files you own" promise.
    static func vaultURL(in container: URL) -> URL {
        container
            .appending(path: "Documents", directoryHint: .isDirectory)
            .appending(path: "Inkstone", directoryHint: .isDirectory)
    }

    /// Creates the vault folder inside the container, if it isn't there already.
    ///
    /// Shared by the button and by the `INKSTONE_ICLOUD_CHECK=create` hook, so
    /// what the hook verifies is the path that actually ships rather than a
    /// second copy of it that can drift.
    static func createVaultFolder(in container: URL) throws -> URL {
        let url = vaultURL(in: container)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Whether the running binary is signed with a ubiquity-container
    /// entitlement — read from the signature, which is the only copy that
    /// governs what the process may actually do.
    ///
    /// Answered differently per platform, because the question only has teeth on
    /// one of them. On macOS the entitlements file is chosen at build time and a
    /// test harness swaps in `Inkstone-Dev.entitlements`, which drops iCloud
    /// entirely — that swap is what produced a false "the container doesn't
    /// exist", so the macOS answer is read from the running signature and
    /// nothing else. iOS has no such harness path and no public API to read your
    /// own entitlements, so it reports entitled and lets the account check do the
    /// discriminating: in the Simulator there is no iCloud account, which
    /// surfaces as `.notSignedIn` — which is both true and useful.
    static var isEntitled: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.ubiquity-container-identifiers" as CFString,
            nil
        )
        guard let identifiers = value as? [String] else { return false }
        return !identifiers.isEmpty
        #else
        return true
        #endif
    }
}

extension ICloudAvailability {

    /// What to tell the user, phrased by whose problem it is.
    var explanation: String {
        switch self {
        case .available:
            return String(localized: "iCloud Drive is ready.")
        case .notEntitled:
            // Not the user's fault and not fixable by them: this build simply
            // cannot use iCloud. Say so rather than sending them to Settings.
            return String(localized: """
                This build of Inkstone was not signed for iCloud, so it can't create \
                a vault there. Open any folder as a vault instead.
                """)
        case .notSignedIn:
            return String(localized: """
                Sign in to iCloud and turn on iCloud Drive, then try again. You can \
                also open any folder as a vault.
                """)
        case .unreachable:
            return String(localized: """
                iCloud Drive is signed in, but Inkstone's storage isn't responding \
                yet. It often sorts itself out in a minute or two — or open any \
                folder as a vault.
                """)
        }
    }

    /// A short title for the same, so an alert does not open with a sentence.
    var title: String {
        switch self {
        case .available: return String(localized: "iCloud Drive is ready")
        case .notEntitled: return String(localized: "This build can't use iCloud")
        case .notSignedIn: return String(localized: "iCloud Drive isn't switched on")
        case .unreachable: return String(localized: "iCloud Drive isn't responding")
        }
    }
}
