import Foundation
import InkstoneCore

/// The models each configured channel offers, fetched once and kept.
///
/// The picker needs a list the moment it opens, and fetching on every open would
/// put a spinner in a menu. Fetching once per channel per launch is the trade:
/// a model added today appears after a relaunch, which is the right side of the
/// trade for a list that changes a few times a year.
///
/// Keyed by profile id rather than by endpoint, because two profiles may point
/// at the same host with different keys — a proxy and the vendor behind it — and
/// those can legitimately serve different lists.
@MainActor
@Observable
final class ModelCatalogue {
    enum State: Equatable {
        case idle
        case loading
        case loaded([ModelInfo])
        /// Kept as a sentence rather than a flag: a channel that cannot list its
        /// models is usually a channel with a bad key, and the picker is where
        /// someone will look first.
        case failed(String)
    }

    private var states: [UUID: State] = [:]
    private var inFlight: Set<UUID> = []

    func state(for profile: AssistantProfile) -> State {
        states[profile.id] ?? .idle
    }

    /// The models to show, which is always something.
    ///
    /// Falls back to whatever the profile already has selected, so the menu
    /// names the current model even when the list could not be fetched. A menu
    /// that shows nothing while a model is plainly in use reads as a bug.
    func models(for profile: AssistantProfile) -> [ModelInfo] {
        if case .loaded(let models) = state(for: profile), !models.isEmpty { return models }
        return profile.model.isEmpty
            ? []
            : [ModelInfo(id: profile.model,
                         displayName: ModelCapabilities.displayName(for: profile.model))]
    }

    /// Fetches a channel's models unless that is already done or under way.
    func load(_ profile: AssistantProfile, force: Bool = false) {
        if !force, states[profile.id] != nil, states[profile.id] != .idle { return }
        guard !inFlight.contains(profile.id) else { return }
        // The on-device model is not a list, and asking would spin forever.
        guard profile.kind != .appleOnDevice else {
            states[profile.id] = .loaded([
                ModelInfo(id: "apple-on-device",
                          displayName: String(localized: "Apple on-device")),
            ])
            return
        }

        inFlight.insert(profile.id)
        states[profile.id] = .loading

        Task { [weak self] in
            defer { self?.inFlight.remove(profile.id) }
            do {
                let provider = try ProviderFactory.provider(for: profile)
                let fetched = try await provider.models()
                    .filter { ModelCapabilities.isChatModel($0.id) }
                    .map {
                        ModelInfo(id: $0.id,
                                  displayName: $0.displayName == $0.id
                                      ? ModelCapabilities.displayName(for: $0.id)
                                      : $0.displayName)
                    }
                self?.states[profile.id] = .loaded(fetched)
            } catch let error as ProviderError {
                self?.states[profile.id] = .failed(Conversation.describe(error))
            } catch let error as ProviderFactory.Unusable {
                self?.states[profile.id] = .failed(
                    Conversation.describe(Conversation.describe(error)))
            } catch {
                self?.states[profile.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Forgets a channel's list, so the next open re-fetches it. Called when the
    /// key or endpoint changes, since either can change what is on offer.
    func invalidate(_ id: UUID) {
        states[id] = nil
    }
}
