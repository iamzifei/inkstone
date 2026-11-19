import Testing
import Foundation
@testable import InkstoneCore

@Suite("Knowledge base settings")
struct KnowledgeBaseSettingsTests {
    @Test func oldSettingsFilesGetTheDefaults() throws {
        let data = try JSONDecoder().decode(SettingsData.self, from: Data(#"{"gitHubAutoSync": false}"#.utf8))
        #expect(data.gitHubAutoSync == false)
        #expect(data.knowledgeBase == KnowledgeBaseSettings())
        #expect(data.knowledgeBase.dropAction == .ask)
        #expect(data.knowledgeBase.autoOrganize)
        #expect(!data.knowledgeBase.useAssistantModel)      // nothing is sent anywhere unless turned on
    }

    @Test func aPartialOrUnknownValueKeepsTheRest() throws {
        let json = #"{"knowledgeBase": {"dropAction": "move", "autoOrganize": "nonsense", "later": 1}}"#
        let kb = try JSONDecoder().decode(SettingsData.self, from: Data(json.utf8)).knowledgeBase
        #expect(kb.dropAction == .move)
        #expect(kb.autoOrganize)
        #expect(kb.useOnDeviceModel)
    }

    @Test func roundTrips() throws {
        var data = SettingsData()
        data.knowledgeBase.dropAction = .copy
        data.knowledgeBase.maintainEntryFiles = false
        let back = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(data))
        #expect(back.knowledgeBase == data.knowledgeBase)
    }
}
