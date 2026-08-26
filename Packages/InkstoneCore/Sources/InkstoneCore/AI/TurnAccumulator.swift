import Foundation

/// Builds one assistant message out of a stream of events.
///
/// Separated from the panel because this is where a turn can go subtly wrong —
/// text arriving after a tool call, two calls interleaving, a stream stopping
/// mid-argument — and none of that is testable through a SwiftUI view. The panel
/// keeps the current `message` and redraws; this decides what it says.
public struct TurnAccumulator: Sendable {
    /// Tool arguments arrive as text fragments that are only valid JSON once
    /// the call ends, so they are held aside and parsed at `toolUseEnded`
    /// rather than after every delta.
    private struct PendingCall {
        let name: String
        var json: String = ""
        /// Where the finished call goes in `blocks`, reserved when the call
        /// starts so that text arriving afterwards cannot jump ahead of it.
        let slot: Int
    }

    private var pending: [String: PendingCall] = [:]
    private var blocks: [ContentBlock] = []
    /// Index of the text block currently being appended to, if any. Deltas
    /// coalesce into one block rather than one block per delta — a thousand
    /// single-character blocks would be correct and unusable.
    private var openTextSlot: Int?
    private var openThinkingSlot: Int?

    public private(set) var stopReason: StopReason?
    public private(set) var usage = TokenUsage()

    public init() {}

    /// The message as it stands. Safe to read after every event.
    public var message: ChatMessage {
        ChatMessage(role: .assistant, blocks: resolvedBlocks)
    }

    /// Blocks with any unfinished tool call included as best it can be.
    ///
    /// A call whose arguments never finished streaming is still shown, with
    /// whatever parsed — a stopped turn should show what the model was about to
    /// do, not drop it silently.
    private var resolvedBlocks: [ContentBlock] {
        var resolved = blocks
        for (id, call) in pending {
            let input = JSONValue.parse(call.json) ?? .object([:])
            let block = ContentBlock.toolUse(id: id, name: call.name, input: input)
            if call.slot < resolved.count {
                resolved[call.slot] = block
            } else {
                resolved.append(block)
            }
        }
        return resolved
    }

    public mutating func consume(_ event: StreamEvent) {
        switch event {
        case .textDelta(let piece):
            Self.append(piece, to: &blocks, slot: &openTextSlot, as: ContentBlock.text) {
                if case .text(let t) = $0 { return t }; return nil
            }
            // Prose after thinking means the thought is over; a later thinking
            // delta starts a new block rather than reopening the old one.
            openThinkingSlot = nil

        case .thinkingDelta(let piece):
            Self.append(piece, to: &blocks, slot: &openThinkingSlot,
                        as: ContentBlock.thinking) {
                if case .thinking(let t) = $0 { return t }; return nil
            }
            openTextSlot = nil

        case .toolUseStarted(let id, let name):
            // A placeholder holds the position. Without it, text streamed after
            // the call would be appended first and the transcript would show
            // the answer before the step that produced it.
            blocks.append(.toolUse(id: id, name: name, input: .object([:])))
            pending[id] = PendingCall(name: name, slot: blocks.count - 1)
            openTextSlot = nil
            openThinkingSlot = nil

        case .toolInputDelta(let id, let json):
            pending[id]?.json += json

        case .toolUseEnded(let id):
            guard let call = pending.removeValue(forKey: id) else { return }
            // A model that emits `{}` for a no-argument tool and one whose
            // arguments were cut off both land here; the difference is not
            // recoverable, so both become an empty object and the tool itself
            // reports a missing argument.
            let input = JSONValue.parse(call.json) ?? .object([:])
            if call.slot < blocks.count {
                blocks[call.slot] = .toolUse(id: id, name: call.name, input: input)
            }

        case .finished(let reason, let totals):
            stopReason = reason
            usage = totals
        }
    }

    /// `static`, taking both pieces of state as separate `inout` parameters.
    ///
    /// As a `mutating` method reading `&openTextSlot` it was an exclusivity
    /// violation: the slot is part of `self`, and passing it to something that
    /// also mutates `self` overlaps. Naming the two accesses separately is not
    /// a workaround for the compiler — it says which state this touches.
    private static func append(
        _ piece: String,
        to blocks: inout [ContentBlock],
        slot: inout Int?,
        as make: (String) -> ContentBlock,
        existing: (ContentBlock) -> String?
    ) {
        if let index = slot, index < blocks.count, let current = existing(blocks[index]) {
            blocks[index] = make(current + piece)
        } else {
            blocks.append(make(piece))
            slot = blocks.count - 1
        }
    }

    /// Whether the model is waiting on tool results rather than finished.
    public var needsToolResults: Bool {
        stopReason == .toolUse && !message.toolUses.isEmpty
    }

    /// Whether anything at all arrived. A turn that produced nothing is worth
    /// showing as a failure rather than as an empty bubble.
    public var isEmpty: Bool {
        resolvedBlocks.allSatisfy { block in
            if case .text(let t) = block { return t.isEmpty }
            if case .thinking(let t) = block { return t.isEmpty }
            return false
        }
    }
}
