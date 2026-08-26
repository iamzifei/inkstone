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
        case .anthropic: return String(localized: "Anthropic")
        case .openAICompatible: return String(localized: "OpenAI-compatible")
        case .appleOnDevice: return String(localized: "On this Mac")
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
    /// Off until the user turns it on, since it is a new panel in a familiar
    /// window and appearing unbidden in the inspector would be a surprise.
    public var isEnabled: Bool

    public init(
        profiles: [AssistantProfile] = [],
        activeProfileID: UUID? = nil,
        includesCurrentNote: Bool = true,
        isEnabled: Bool = false
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

    /// The profiles offered on a fresh install: one per kind, unconfigured.
    ///
    /// Seeded rather than left empty so the first screen shows what is possible.
    /// An empty list plus an "Add" button hides the fact that a local model is
    /// an option at all.
    public static func seeded() -> AssistantSettings {
        AssistantSettings(profiles: [
            AssistantProfile(name: String(localized: "Claude"), kind: .anthropic,
                             model: "claude-sonnet-5"),
            AssistantProfile(name: String(localized: "OpenAI"), kind: .openAICompatible,
                             model: "gpt-5"),
            AssistantProfile(name: String(localized: "On this Mac"), kind: .appleOnDevice),
        ])
    }
}
