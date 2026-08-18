import Foundation
import Testing
@testable import InkstoneCore

@Suite("Sync configuration merge")
struct SyncConfigurationMergeTests {

    private func configuration(
        _ repository: String = "me/notes",
        branch: String = "main",
        at seconds: TimeInterval
    ) -> GitHubSyncConfiguration {
        GitHubSyncConfiguration(
            repository: repository,
            branch: branch,
            isEnabled: true,
            isAutomatic: true,
            intervalMinutes: 15,
            updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("With nothing published, this device publishes")
    func noRemote() {
        #expect(
            SyncConfigurationMerge.resolve(local: configuration(at: 10), remote: nil) == .publishLocal
        )
    }

    @Test("A newer remote is adopted")
    func newerRemoteWins() {
        let remote = configuration("me/vault", at: 20)
        #expect(
            SyncConfigurationMerge.resolve(local: configuration(at: 10), remote: remote)
                == .adopt(remote)
        )
    }

    @Test("An older remote is overwritten")
    func olderRemoteLoses() {
        #expect(
            SyncConfigurationMerge.resolve(
                local: configuration("me/vault", at: 30),
                remote: configuration(at: 20)
            ) == .publishLocal
        )
    }

    /// The case that would otherwise never settle: two devices agreeing, each
    /// seeing the other's timestamp as older, each publishing again.
    @Test("Identical setups are left alone whatever their timestamps say")
    func agreementIsNotAConflict() {
        #expect(
            SyncConfigurationMerge.resolve(
                local: configuration(at: 10),
                remote: configuration(at: 99)
            ) == .keepLocal
        )
        #expect(
            SyncConfigurationMerge.resolve(
                local: configuration(at: 99),
                remote: configuration(at: 10)
            ) == .keepLocal
        )
    }

    @Test("The timestamp is not part of the setup")
    func timestampIsNotConfiguration() {
        #expect(configuration(at: 1).describesSameSetupAs(configuration(at: 2)))
        #expect(!configuration(at: 1).describesSameSetupAs(configuration("other/repo", at: 1)))
    }

    @Test("A differing branch alone is a difference")
    func branchCounts() {
        let remote = configuration(branch: "drafts", at: 20)
        #expect(
            SyncConfigurationMerge.resolve(local: configuration(at: 10), remote: remote)
                == .adopt(remote)
        )
    }
}
