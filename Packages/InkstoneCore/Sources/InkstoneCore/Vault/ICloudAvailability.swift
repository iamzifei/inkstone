import Foundation

/// Why the app's own iCloud container is, or is not, usable.
///
/// This exists because "unavailable" was one word covering three unrelated
/// situations, and the three need different answers: one is the user's to fix,
/// one is nobody's, and one means the build being run cannot answer the
/// question at all.
///
/// That last case is not hypothetical. The diagnostic hook that reports on the
/// container is compiled into debug builds only, and debug builds were being
/// signed with `Inkstone-Dev.entitlements`, which carries no iCloud keys. So the
/// only binary that could run the check was the only binary guaranteed to fail
/// it, and its "container not reachable" was written down as fact — the
/// container was reachable the whole time, and had been syncing for a day.
///
/// A measurement taken with the wrong instrument reports on the instrument. The
/// order of the cases below is the fix: a build that cannot ask must never be
/// reported as an answer about the container.
public enum ICloudAvailability: Equatable, Sendable {

    /// Entitled, signed in, and the container is on disk.
    case available(URL)

    /// This binary has no ubiquity-container entitlement, so its `nil` says
    /// nothing about iCloud. Nothing the user can do; the build is wrong.
    case notEntitled

    /// No iCloud account, or iCloud Drive is switched off. The user's to fix.
    case notSignedIn

    /// Entitled and signed in, and the container still did not resolve. This is
    /// the only case that points at the container itself.
    case unreachable

    /// - Parameters:
    ///   - isEntitled: whether the *running* binary carries the entitlement,
    ///     read from its own signature rather than from the source file that
    ///     was supposed to be used.
    ///   - isSignedIn: whether there is an iCloud identity for ubiquitous files.
    ///   - container: the resolved container URL, if any.
    public static func diagnose(
        isEntitled: Bool,
        isSignedIn: Bool,
        container: URL?
    ) -> ICloudAvailability {
        // Entitlement first, on purpose: without it the other two answers are
        // not evidence about anything, and reporting them as though they were
        // is the mistake this type was written to make impossible.
        guard isEntitled else { return .notEntitled }
        guard isSignedIn else { return .notSignedIn }
        guard let container else { return .unreachable }
        return .available(container)
    }

    /// Whether a vault can be created right now.
    public var isUsable: Bool {
        if case .available = self { return true }
        return false
    }
}
