import Foundation
import Testing
@testable import InkstoneCore

/// `SettingsData` decodes field by field (so an older file still decodes),
/// which means every stored property needs its own line in `init(from:)`.
/// `assistant` never had one: from the day the assistant arrived (2026-08-26)
/// every launch decoded an empty profile list, seeded new profiles with new
/// ids, and so lost the Keychain key stored under the old id — measured on a
/// real iPhone, whose profile ids changed on each of three launches
/// (found 2026-11-20).
@Suite("Settings decoding")
struct SettingsDecodeTests {

    @Test("Assistant profiles survive a save and a load")
    func assistantRoundTrips() throws {
        var data = SettingsData()
        data.assistant.seedIfEmpty()
        data.assistant.profiles[0].model = "a-model-someone-chose"
        let id = data.assistant.profiles[0].id
        data.assistant.activeProfileID = id
        data.assistant.isEnabled = false

        let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(data))
        #expect(decoded.assistant.profiles.map(\.id) == data.assistant.profiles.map(\.id))
        #expect(decoded.assistant.profiles.first?.model == "a-model-someone-chose")
        #expect(decoded.assistant.activeProfileID == id)
        #expect(decoded.assistant.isEnabled == false)
    }

    /// The assistant's own decoding was as strict as synthesised Codable: one
    /// missing field (a blob saved before `thinking` existed) or one unknown
    /// value failed the whole of it, `value()` fell back to the default, and the
    /// profiles were re-seeded with new ids — the same lost key by another road
    /// (review of the fix, 2026-11-20).
    @Test("Older or partly unknown assistant data keeps every profile it can read",
          arguments: [
            // Saved before `thinking` and the two switches existed.
            #"{"activeProfileID":"11111111-1111-1111-1111-111111111111","profiles":[{"name":"Claude","model":"m","id":"11111111-1111-1111-1111-111111111111","kind":"anthropic","endpoint":""},{"name":"Local","model":"","id":"22222222-2222-2222-2222-222222222222","kind":"appleOnDevice","endpoint":""}]}"#,
            // A profile of a kind this build does not know (written by a newer
            // one), and a thinking level it does not know either.
            #"{"isEnabled":true,"includesCurrentNote":true,"activeProfileID":"11111111-1111-1111-1111-111111111111","profiles":[{"name":"Claude","model":"m","thinking":"ultra","id":"11111111-1111-1111-1111-111111111111","kind":"anthropic","endpoint":""},{"name":"Future","model":"","thinking":"off","id":"33333333-3333-3333-3333-333333333333","kind":"somethingNew","endpoint":""},{"name":"Local","model":"","thinking":"off","id":"22222222-2222-2222-2222-222222222222","kind":"appleOnDevice","endpoint":""}]}"#,
          ])
    func lenientAssistant(json: String) throws {
        let blob = #"{"assistant":"# + json + "}"
        let decoded = try JSONDecoder().decode(SettingsData.self, from: Data(blob.utf8))
        let ids = decoded.assistant.profiles.map(\.id.uuidString)
        #expect(ids.contains("11111111-1111-1111-1111-111111111111"))
        #expect(ids.contains("22222222-2222-2222-2222-222222222222"))
        #expect(decoded.assistant.activeProfileID?.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(decoded.assistant.profiles.first?.model == "m")
        #expect(decoded.assistant.profiles.first?.thinking == .off)
    }

    /// The guard for next time: every stored property of `SettingsData` is read
    /// in its decoder. Checked against the source, because a forgotten line
    /// decodes silently as the default and no round trip of default values can
    /// tell.
    @Test("Every stored setting has a line in the decoder")
    func decoderReadsEveryProperty() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/InkstoneCore/Settings/AppSettings.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "public struct SettingsData"))
        let decoder = try #require(text.range(of: "public init(from decoder", range: start.upperBound..<text.endIndex))
        let declarations = String(text[start.upperBound..<decoder.lowerBound])
        let body = String(text[decoder.upperBound...]).components(separatedBy: "\n    }\n").first ?? ""
        let stored = declarations.split(separator: "\n").compactMap { line -> String? in
            // SettingsData's own properties only (four spaces in), not those
            // of the types nested inside it.
            // Stored only: a computed property ends its line with `{`.
            guard line.hasPrefix("    public var "), !line.hasSuffix("{") else { return nil }
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.dropFirst("public var ".count).prefix { $0.isLetter || $0.isNumber }.description
        }
        #expect(stored.count > 40)
        let missing = stored.filter { !body.contains("value(.\($0),") }
        #expect(missing.isEmpty, "not read by SettingsData.init(from:): \(missing)")
    }
}
