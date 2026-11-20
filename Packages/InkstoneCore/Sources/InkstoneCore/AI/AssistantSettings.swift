import Foundation

/// Which kind of endpoint an assistant profile talks to.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic
    /// Anything speaking the OpenAI chat-completions format, official or not.
    case openAICompatible
    /// Apple's on-device model. No key, no network, no cost.
    case appleOnDevice

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return localized("Anthropic")
        case .openAICompatible: return localized("OpenAI-compatible")
        case .appleOnDevice: return localized("On this Mac")
        }
    }

    /// A local endpoint needs no credential, and demanding one would make
    /// Ollama impossible to configure.
    public var needsAPIKey: Bool {
        switch self {
        case .anthropic: return true
        case .openAICompatible: return false
        case .appleOnDevice: return false
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAICompatible: return "https://api.openai.com/v1"
        case .appleOnDevice: return ""
        }
    }
}

/// One configured way to reach a model.
///
/// A profile rather than a single global provider, because the endpoint, the
/// key, and the model are one unit: switching from a cloud model to a local one
/// changes all three, and settings that let them drift apart produce a request
/// sent to the wrong place with the wrong credential.
public struct AssistantProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    /// Empty means "use the default for this kind", which keeps a profile
    /// working when a vendor changes its host.
    public var endpoint: String
    public var model: String
    public var thinking: ThinkingEffort

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        endpoint: String = "",
        model: String = "",
        thinking: ThinkingEffort = .off
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.model = model
        self.thinking = thinking
    }

    public var resolvedEndpoint: String {
        endpoint.isEmpty ? kind.defaultEndpoint : endpoint
    }

    /// The Keychain account name for this profile's credential. Keyed by id, so
    /// two profiles on the same host can hold different keys — a work key and a
    /// personal one, or a proxy and the vendor behind it.
    public var credentialAccount: String { "profile-\(id.uuidString)" }
}

/// Everything the assistant panel needs that is not a secret.
public struct AssistantSettings: Codable, Hashable, Sendable {
    public var profiles: [AssistantProfile]
    public var activeProfileID: UUID?
    /// Whether the note on screen is attached to each new conversation.
    public var includesCurrentNote: Bool
    /// Whether the Assistant tab appears in the inspector.
    ///
    /// On. It was off at first, reasoning that a new panel appearing unbidden in
    /// a familiar window is a surprise — but that trades a small surprise for a
    /// feature nobody finds. Someone who installs a version that adds an
    /// assistant and sees no assistant concludes it is broken, not that there is
    /// a switch five tabs into Settings.
    ///
    /// The panel costs nothing until it is used: with no key configured it shows
    /// how to add one instead of a chat box, and it makes no request until
    /// asked. Anyone who wants it gone has one switch, in the pane it names.
    public var isEnabled: Bool

    public init(
        profiles: [AssistantProfile] = [],
        activeProfileID: UUID? = nil,
        includesCurrentNote: Bool = true,
        isEnabled: Bool = true
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.includesCurrentNote = includesCurrentNote
        self.isEnabled = isEnabled
    }

    public var activeProfile: AssistantProfile? {
        guard let id = activeProfileID else { return profiles.first }
        return profiles.first { $0.id == id } ?? profiles.first
    }

    /// Fills in the starting profiles if there are none.
    ///
    /// Called when settings load rather than when the switch is flipped, since
    /// the switch now starts on and nobody would ever flip it.
    public mutating func seedIfEmpty() {
        guard profiles.isEmpty else { return }
        let seeded = Self.seeded()
        profiles = seeded.profiles
        activeProfileID = seeded.profiles.first?.id
    }

    /// The profiles offered on a fresh install: one per kind, unconfigured.
    ///
    /// Seeded rather than left empty so the first screen shows what is possible.
    /// An empty list plus an "Add" button hides the fact that a local model is
    /// an option at all.
    public static func seeded() -> AssistantSettings {
        AssistantSettings(profiles: [
            AssistantProfile(name: localized("Claude"), kind: .anthropic,
                             model: "claude-sonnet-5"),
            AssistantProfile(name: localized("OpenAI"), kind: .openAICompatible,
                             model: "gpt-5"),
            AssistantProfile(name: localized("On this Mac"), kind: .appleOnDevice),
        ])
    }
}

// MARK: - Lenient decoding
//
// Settings are stored as one JSON blob, and a blob written by an older build
// (before `thinking` or the switches existed) or a newer one (a kind this build
// does not know) must still decode. Synthesised Codable fails the whole value on
// one missing key or unknown case; the settings decoder then falls back to the
// default, the profiles are re-seeded with new ids, and the API key stored in
// the Keychain under the old id is lost. So each field falls back on its own,
// and each profile is read on its own.

extension AssistantProfile {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Without its id a profile cannot find its key: not a profile.
        id = try c.decode(UUID.self, forKey: .id)
        // A kind this build does not know: not usable here, so not read (the
        // rest of the list still is).
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? kind.displayName
        endpoint = (try? c.decodeIfPresent(String.self, forKey: .endpoint)) ?? nil ?? ""
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil ?? ""
        thinking = (try? c.decodeIfPresent(ThinkingEffort.self, forKey: .thinking)) ?? nil ?? .off
    }
}

extension AssistantSettings {
    /// One profile that may or may not decode.
    private struct MaybeProfile: Decodable {
        let profile: AssistantProfile?
        init(from decoder: any Decoder) throws { profile = try? AssistantProfile(from: decoder) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AssistantSettings()
        let maybe = (try? c.decodeIfPresent([MaybeProfile].self, forKey: .profiles)) ?? nil ?? []
        self.init(
            profiles: maybe.compactMap(\.profile),
            activeProfileID: (try? c.decodeIfPresent(UUID.self, forKey: .activeProfileID)) ?? nil,
            includesCurrentNote: (try? c.decodeIfPresent(Bool.self, forKey: .includesCurrentNote)) ?? nil ?? defaults.includesCurrentNote,
            isEnabled: (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? nil ?? defaults.isEnabled
        )
    }
}
