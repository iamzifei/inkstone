import Foundation

/// The part of the GitHub setup that describes *what to sync with*, as opposed
/// to the credential that proves you may.
///
/// It exists as its own value because it has to travel. Sync's whole purpose is
/// to make two devices hold the same vault, and until now each device was
/// configured separately — the repository typed once on the Mac and again on the
/// phone, which is the same fact stated twice and a second chance to state it
/// differently.
public struct GitHubSyncConfiguration: Codable, Hashable, Sendable {
    public var repository: String
    public var branch: String
    public var isEnabled: Bool
    public var isAutomatic: Bool
    public var intervalMinutes: Int
    /// When this device last changed any of the above. The only thing that
    /// decides which side wins.
    public var updatedAt: Date

    public init(
        repository: String,
        branch: String,
        isEnabled: Bool,
        isAutomatic: Bool,
        intervalMinutes: Int,
        updatedAt: Date
    ) {
        self.repository = repository
        self.branch = branch
        self.isEnabled = isEnabled
        self.isAutomatic = isAutomatic
        self.intervalMinutes = intervalMinutes
        self.updatedAt = updatedAt
    }

    /// Everything except the timestamp, which is bookkeeping rather than
    /// configuration: two devices holding the same settings have nothing to
    /// resolve, whatever order they wrote them in.
    public func describesSameSetupAs(_ other: GitHubSyncConfiguration) -> Bool {
        repository == other.repository
            && branch == other.branch
            && isEnabled == other.isEnabled
            && isAutomatic == other.isAutomatic
            && intervalMinutes == other.intervalMinutes
    }
}

/// Decides which device's GitHub setup wins.
///
/// Last-writer-wins, deliberately. A three-way merge is what the *files* need,
/// because losing an edit is unacceptable; this is five fields that a person
/// changes by hand every few months, and the worst case is picking a repository
/// again. Machinery proportional to the stake.
public enum SyncConfigurationMerge {

    public enum Resolution: Equatable, Sendable {
        /// Nothing to do — either there is no remote, or both sides agree.
        case keepLocal
        /// The other device's setup is newer; adopt it.
        case adopt(GitHubSyncConfiguration)
        /// This device's setup is newer; publish it.
        case publishLocal
    }

    public static func resolve(
        local: GitHubSyncConfiguration,
        remote: GitHubSyncConfiguration?
    ) -> Resolution {
        guard let remote else { return .publishLocal }
        // Identical setups are not a conflict, and resolving one would write a
        // fresh timestamp on every launch — two devices taking turns publishing
        // the same five values forever.
        if remote.describesSameSetupAs(local) { return .keepLocal }
        return remote.updatedAt > local.updatedAt ? .adopt(remote) : .publishLocal
    }
}
