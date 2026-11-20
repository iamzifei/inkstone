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
        let body = String(text[decoder.upperBound...].prefix(while: { _ in true }))
            .components(separatedBy: "\n    }\n").first ?? ""
        let stored = declarations.split(separator: "\n").compactMap { line -> String? in
            // SettingsData's own properties only (four spaces in), not those
            // of the types nested inside it.
            guard line.hasPrefix("    public var ") else { return nil }
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.dropFirst("public var ".count).prefix { $0.isLetter || $0.isNumber }.description
        }
        #expect(stored.count > 40)
        let missing = stored.filter { !body.contains("value(.\($0),") }
        #expect(missing.isEmpty, "not read by SettingsData.init(from:): \(missing)")
    }
}
