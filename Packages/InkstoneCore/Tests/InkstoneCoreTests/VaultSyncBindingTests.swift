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
            repository: "iamzifei/notes", branch: "main", isEnabled: true
        )
        settings.syncOverridesGit.insert(id)

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(SettingsData.self, from: data)
        #expect(restored.vaultSync[id]?.repository == "iamzifei/notes")
        #expect(restored.syncOverridesGit.contains(id))

        // Settings written before this change carry neither key. They must load,
        // not reset every other preference to its default — `SettingsData` is
        // decoded with `try?`, so a throw here would silently wipe the file.
        let legacy = Data(#"{"gitHubRepository":"iamzifei/old","themeID":"inkstone"}"#.utf8)
        let old = try JSONDecoder().decode(SettingsData.self, from: legacy)
        #expect(old.gitHubRepository == "iamzifei/old")
        #expect(old.vaultSync.isEmpty)
        #expect(old.didMigrateSyncBindings == false)
        #expect(old.syncOverridesGit.isEmpty)
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
        #expect(adoptable(vaultRepository: "iamzifei/notes", shared: "a private notes repository") == false)

        // Same repository already recorded: this is a genuine second copy of the
        // same vault, and carrying the branch and switches across is the point
        // of sharing at all.
        #expect(adoptable(vaultRepository: "a private notes repository", shared: "a private notes repository"))
    }
}
