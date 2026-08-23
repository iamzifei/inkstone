import Foundation
import Testing
@testable import InkstoneCore

/// The repository belongs to a vault, not to the app.
///
/// It used to be one global field, and every vault the app had ever opened
/// shared it. Opening a second vault made it inherit the first one's repository
/// and start making that repository look like itself. That destroyed content
/// twice in four days, so the shape is worth holding in tests rather than in
/// anyone's memory.
@Suite("Vault sync bindings")
struct VaultSyncBindingTests {

    @Test("An unbound vault is not configured, and an empty repository is not a repository")
    func unboundIsSilent() {
        var settings = SettingsData()
        let bound = UUID().uuidString
        let other = UUID().uuidString

        settings.vaultSync[bound] = VaultSyncBinding(
            repository: "a private notes repository", branch: "master", isEnabled: true
        )

        #expect(settings.vaultSync[bound]?.isConfigured == true)

        // The whole fix in one assertion: the second vault gets nothing, rather
        // than inheriting the first one's repository.
        #expect(settings.vaultSync[other] == nil)
        #expect((settings.vaultSync[other] ?? VaultSyncBinding()).isConfigured == false)
        #expect((settings.vaultSync[other] ?? VaultSyncBinding()).isEnabled == false)
    }

    @Test("Bindings survive a round trip, and a settings file without them still decodes")
    func decodingIsLenient() throws {
        var settings = SettingsData()
        let id = UUID().uuidString
        settings.vaultSync[id] = VaultSyncBinding(
            repository: "owner/notes", branch: "main", isEnabled: true
        )
        settings.syncOverridesGit.insert(id)

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(SettingsData.self, from: data)
        #expect(restored.vaultSync[id]?.repository == "owner/notes")
        #expect(restored.syncOverridesGit.contains(id))

        // Settings written before this change carry neither key. They must load,
        // not reset every other preference to its default — `SettingsData` is
        // decoded with `try?`, so a throw here would silently wipe the file.
        let legacy = Data(#"{"gitHubRepository":"owner/old","themeID":"inkstone"}"#.utf8)
        let old = try JSONDecoder().decode(SettingsData.self, from: legacy)
        #expect(old.gitHubRepository == "owner/old")
        #expect(old.vaultSync.isEmpty)
        #expect(old.didMigrateSyncBindings == false)
        #expect(old.syncOverridesGit.isEmpty)
    }

    /// One repository, one vault, per device.
    ///
    /// Stated as a predicate over the binding map because `Workspace` lives in
    /// the app target, out of this package's reach — but the rule is the thing
    /// worth failing on, and it should be written down somewhere that can fail.
    /// `SmokeTest` exercises the real implementation.
    @Test("Two vaults on one device cannot hold the same repository")
    func oneRepositoryPerDevice() {
        func otherVaultHolding(_ repository: String, besides me: String,
                               in map: [String: VaultSyncBinding]) -> String? {
            map.first { key, binding in key != me && binding.repository == repository }?.key
        }

        let mine = UUID().uuidString, theirs = UUID().uuidString
        var map: [String: VaultSyncBinding] = [
            mine: VaultSyncBinding(repository: "owner/notes", branch: "main", isEnabled: true),
            theirs: VaultSyncBinding(repository: "owner/notes", branch: "main", isEnabled: true),
        ]
        #expect(otherVaultHolding("owner/notes", besides: mine, in: map) == theirs)

        // Claiming it removes the other binding rather than leaving both — a
        // second vault kept "for later" is the state this exists to prevent.
        map.removeValue(forKey: theirs)
        #expect(otherVaultHolding("owner/notes", besides: mine, in: map) == nil)

        // Different repositories on one device are ordinary, and switching
        // between those vaults must stay unaffected.
        map[theirs] = VaultSyncBinding(repository: "owner/journal", branch: "main", isEnabled: true)
        #expect(otherVaultHolding("owner/notes", besides: mine, in: map) == nil)
        #expect(otherVaultHolding("owner/journal", besides: theirs, in: map) == nil)
    }

    /// The rule the shared-configuration path now follows. Written as a plain
    /// predicate because `Workspace` is in the app target, not this package —
    /// but the rule is the thing that matters, and it should be stated
    /// somewhere a test can fail.
    @Test("A shared configuration only ever confirms a binding the vault already has")
    func sharedConfigurationCannotIntroduceARepository() {
        func adoptable(vaultRepository: String, shared: String) -> Bool {
            vaultRepository == shared
        }

        // The Mac's vault and the phone's vault were different folders. The
        // phone adopting the Mac's repository is exactly what must not happen.
        #expect(adoptable(vaultRepository: "", shared: "a private notes repository") == false)
        #expect(adoptable(vaultRepository: "owner/notes", shared: "a private notes repository") == false)

        // Same repository already recorded: this is a genuine second copy of the
        // same vault, and carrying the branch and switches across is the point
        // of sharing at all.
        #expect(adoptable(vaultRepository: "a private notes repository", shared: "a private notes repository"))
    }
}
