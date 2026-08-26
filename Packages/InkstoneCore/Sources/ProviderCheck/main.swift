import Foundation
import InkstoneCore

// Calls the real providers, because unit tests cannot show that any of this
// works. They cover the parsing, which is where the fiddly rules live; they say
// nothing about whether the request we build is one the server accepts.
//
//     swift run provider-check
//
// Reads CLAUDE_API_KEY and OPENAI_API_KEY from the environment, or from ~/.env
// if they are not exported. Skips whichever it cannot find rather than failing,
// so this stays runnable with one key.

/// Loads `~/.env` for keys not already in the environment.
///
/// The file holds one key per line as `NAME=value`. Values are used but never
/// printed: a smoke check that echoed a credential into a terminal transcript
/// would be a worse problem than the one it was written to catch.
func environmentIncludingDotEnv() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let dotenv = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".env")
    guard let text = try? String(contentsOf: dotenv, encoding: .utf8) else { return environment }
    for line in text.split(separator: "\n") {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
        let name = String(line[line.startIndex..<equals])
        var value = String(line[line.index(after: equals)...])
        // Tolerate quoted values, which several tools write by default.
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        if environment[name] == nil { environment[name] = value }
    }
    return environment
}

/// Drives one turn and reports what actually came back.
func check(_ provider: any ModelProvider, named label: String, model: String) async -> Bool {
    print("\n── \(label) · \(model) ──")

    // Three answers rather than one, because the check asserts on streaming as
    // well as on correctness. A one-word reply arrives in one chunk about half
    // the time — which says nothing about whether the transport streams, and
    // failed this check once for exactly that reason.
    let request = CompletionRequest(
        model: model,
        system: "Answer with the bare names, comma separated. No other words.",
        messages: [.init(role: .user, text:
            "Capitals of Australia, France, and Japan?")],
        maxTokens: 64)

    var text = ""
    var deltas = 0
    var finish: (StopReason, TokenUsage)?
    do {
        for try await event in provider.stream(request) {
            switch event {
            case .textDelta(let piece): text += piece; deltas += 1
            case .finished(let reason, let usage): finish = (reason, usage)
            default: break
            }
        }
    } catch {
        print("  ✘ \(error)")
        return false
    }

    let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
    print("  answer   \(answer)")
    // More than one delta is the evidence that this streamed rather than
    // arriving whole — the difference the panel is built around.
    print("  streamed \(deltas) deltas")
    if let (reason, usage) = finish {
        print("  finish   \(reason), \(usage.inputTokens) in / \(usage.outputTokens) out")
    }

    let lowered = answer.lowercased()
    guard ["canberra", "paris", "tokyo"].allSatisfy(lowered.contains) else {
        print("  ✘ wrong answer"); return false
    }
    // Now meaningful: three names cannot arrive in a single chunk from a
    // provider that streams.
    guard deltas > 1 else { print("  ✘ did not stream"); return false }
    guard let (reason, usage) = finish, reason == .endTurn else {
        print("  ✘ no clean finish"); return false
    }
    guard usage.outputTokens > 0 else {
        print("  ✘ no usage reported"); return false
    }
    print("  ✔ ok")
    return true
}

/// Asks for a tool call, which is the part phase 2 depends on.
func checkTools(_ provider: any ModelProvider, named label: String, model: String) async -> Bool {
    print("\n── \(label) · tool calling ──")
    let tool = ToolDefinition(
        name: "search_notes",
        description: "Search the user's notes for a phrase.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("The phrase to search for"),
                ]),
            ]),
            "required": .array([.string("query")]),
        ]))

    let request = CompletionRequest(
        model: model,
        system: "Use the search_notes tool to answer. Do not answer from memory.",
        messages: [.init(role: .user, text: "What did I write about sourdough?")],
        tools: [tool],
        maxTokens: 512)

    // Keyed by call id, because a model may open several calls at once and
    // their fragments interleave. Concatenating them all into one buffer looks
    // like it works right up until the model asks two questions, and then
    // produces `{...}{...}` and an accusation against the wrong component.
    var names: [String: String] = [:]
    var arguments: [String: String] = [:]
    var order: [String] = []
    var reason: StopReason?
    do {
        for try await event in provider.stream(request) {
            switch event {
            case .toolUseStarted(let id, let toolName):
                names[id] = toolName
                order.append(id)
            case .toolInputDelta(let id, let json):
                arguments[id, default: ""] += json
            case .finished(let stop, _):
                reason = stop
            default: break
            }
        }
    } catch {
        print("  ✘ \(error)")
        return false
    }

    guard !order.isEmpty else {
        print("  tool     none"); print("  ✘ no tool call"); return false
    }
    for id in order {
        print("  tool     \(names[id] ?? "?")(\(arguments[id] ?? ""))")
    }
    print("  finish   \(reason.map(String.init(describing:)) ?? "none")")

    guard order.allSatisfy({ names[$0] == "search_notes" }) else {
        print("  ✘ called a tool that was not offered"); return false
    }
    // Every call's fragments must reassemble into valid JSON on their own.
    // This is the assertion the streaming decoder exists for, and the one a
    // unit test can only make against a recording.
    for id in order {
        guard let parsed = JSONValue.parse(arguments[id] ?? ""),
              parsed["query"]?.stringValue != nil else {
            print("  ✘ \(id): arguments did not reassemble into valid JSON"); return false
        }
    }
    guard reason == .toolUse else { print("  ✘ stop reason was not toolUse"); return false }
    print("  ✔ ok")
    return true
}

// MARK: - Run

let environment = environmentIncludingDotEnv()
var results: [(String, Bool)] = []

if let key = environment["CLAUDE_API_KEY"], !key.isEmpty {
    let provider = AnthropicProvider(configuration: .init(apiKey: key))
    let models = (try? await provider.models()) ?? []
    print("Anthropic: \(models.count) models, newest \(models.first?.id ?? "?")")
    let model = models.first?.id ?? "claude-sonnet-5"
    results.append(("anthropic/text", await check(provider, named: "Anthropic", model: model)))
    results.append(("anthropic/tools", await checkTools(provider, named: "Anthropic", model: model)))
} else {
    print("Anthropic: no CLAUDE_API_KEY, skipped")
}

if let key = environment["OPENAI_API_KEY"], !key.isEmpty {
    let provider = OpenAICompatibleProvider(configuration: .init(apiKey: key))
    let models = (try? await provider.models()) ?? []
    print("\nOpenAI: \(models.count) models")
    let model = "gpt-4.1-mini"
    results.append(("openai/text", await check(provider, named: "OpenAI", model: model)))
    results.append(("openai/tools", await checkTools(provider, named: "OpenAI", model: model)))
} else {
    print("OpenAI: no OPENAI_API_KEY, skipped")
}

print("\n════ summary ════")
for (name, ok) in results { print("  \(ok ? "✔" : "✘") \(name)") }
let failed = results.filter { !$0.1 }
if results.isEmpty {
    print("nothing ran — no keys found")
    exit(2)
}
exit(failed.isEmpty ? 0 : 1)
