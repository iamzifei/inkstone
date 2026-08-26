import Testing
import Foundation
@testable import InkstoneCore

/// Message persistence, which the conversation store is built on.
@Suite("Message coding")
struct MessageCodingTests {
    private func roundTrip(_ message: ChatMessage) throws -> ChatMessage {
        let data = try JSONEncoder().encode(message)
        return try JSONDecoder().decode(ChatMessage.self, from: data)
    }

    @Test("Every kind of block survives a round trip")
    func codesEveryBlock() throws {
        // A conversation reopened after a relaunch has to be the same
        // conversation. A block type that silently fails to decode would take
        // the whole message with it.
        let message = ChatMessage(role: .assistant, blocks: [
            .text("答案"),
            .thinking("weighing it"),
            .toolUse(id: "t1", name: "search_notes",
                     input: .object(["query": .string("茶")])),
            .toolResult(id: "t1", content: "3 hits", isError: false),
            .image(mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47])),
        ])
        #expect(try roundTrip(message) == message)
    }

    @Test("The identity survives too")
    func keepsIdentity() throws {
        // The id is what an edit addresses. If it changed on reload, editing a
        // question from a reopened conversation would silently do nothing.
        let message = ChatMessage(role: .user, text: "hi")
        #expect(try roundTrip(message).id == message.id)
    }

    @Test("A failed turn keeps what went wrong")
    func keepsFailures() throws {
        var message = ChatMessage(role: .assistant, blocks: [.text("half")])
        message.failure = "Rate limited"
        #expect(try roundTrip(message).failure == "Rate limited")
    }

    @Test("A whole transcript round-trips")
    func codesTranscripts() throws {
        let transcript = [
            ChatMessage(role: .user, text: "问题"),
            ChatMessage(role: .assistant, blocks: [.text("答案")]),
        ]
        let data = try JSONEncoder().encode(transcript)
        #expect(try JSONDecoder().decode([ChatMessage].self, from: data) == transcript)
    }
}

/// Reading a Claude Code skill library.
@Suite("Skills")
struct SkillTests {
    private let folder = URL(fileURLWithPath: "/skills/ad-creative")

    @Test("Name and description come out of the frontmatter")
    func parsesFrontmatter() {
        let head = """
            ---
            name: ad-creative
            description: "When the user wants to generate ad creative."
            metadata:
              version: 1.0.0
            ---

            # Ad Creative
            """
        let manifest = SkillIndex.manifest(fromHead: head, folder: folder)
        #expect(manifest?.name == "ad-creative")
        #expect(manifest?.description == "When the user wants to generate ad creative.")
    }

    @Test("A nested name does not shadow the real one")
    func ignoresNestedKeys() {
        // `metadata:` blocks carry their own keys, and indentation is the only
        // thing separating them from the ones that matter.
        let head = """
            ---
            name: real-name
            metadata:
              name: wrong-name
              description: wrong description
            ---
            """
        #expect(SkillIndex.manifest(fromHead: head, folder: folder)?.name == "real-name")
    }

    @Test("A truncated head still yields what it already had")
    func survivesTruncation() {
        // The head is a 4 KB prefix of a file that is usually much longer, so it
        // almost always cuts mid-document. A YAML parser would call this a
        // syntax error; the two fields are right there.
        let head = """
            ---
            name: adapt
            description: Adapt designs across screen sizes.
            args:
              - name: targ
            """
        let manifest = SkillIndex.manifest(fromHead: head, folder: folder)
        #expect(manifest?.name == "adapt")
        #expect(manifest?.description == "Adapt designs across screen sizes.")
    }

    @Test("No frontmatter falls back to the folder name")
    func fallsBackToFolderName() {
        // Not a reason to hide a skill: the folder name is a usable label and
        // the body is still instructions.
        let manifest = SkillIndex.manifest(fromHead: "# Just a heading", folder: folder)
        #expect(manifest?.name == "ad-creative")
        #expect(manifest?.description == "")
    }

    @Test("Matching prefers the name over the description")
    func ranksNameFirst() {
        // Typing `/ad` means the skill called ad-creative, not the twelve whose
        // descriptions mention advertising.
        let skills = [
            SkillManifest(name: "copywriting", description: "ad copy and headlines", url: folder),
            SkillManifest(name: "ad-creative", description: "creative", url: folder),
            SkillManifest(name: "paid-ads", description: "campaigns", url: folder),
        ]
        #expect(SkillIndex.matching("ad", in: skills).map(\.name)
                == ["ad-creative", "paid-ads", "copywriting"])
    }

    @Test("An exact name wins outright")
    func ranksExactFirst() {
        let skills = [
            SkillManifest(name: "adapt-layout", description: "", url: folder),
            SkillManifest(name: "adapt", description: "", url: folder),
        ]
        #expect(SkillIndex.matching("adapt", in: skills).first?.name == "adapt")
    }

    @Test("The frontmatter is not sent to the model")
    func stripsFrontmatter() {
        // It is routing information for whoever picked the skill. Once picked it
        // has done its job, and sending it spends tokens explaining when to use
        // something already in use.
        let text = """
            ---
            name: x
            description: y
            ---

            # Do the thing

            Step one.
            """
        let instructions = SkillIndex.instructions(from: text)
        #expect(instructions == "# Do the thing\n\nStep one.")
        #expect(!instructions.contains("description:"))
    }

    @Test("A file with no frontmatter is passed through whole")
    func keepsBodyWithoutFrontmatter() {
        #expect(SkillIndex.instructions(from: "# Heading\n\nBody") == "# Heading\n\nBody")
    }
}
