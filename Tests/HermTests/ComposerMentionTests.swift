import Testing

@testable import Herm

struct ComposerMentionTests {
    @Test func annotatesEmbeddedAndMultipleMentionsWithCanonicalToolTargets() {
        let prompt = ComposerMentionPresentation.annotatedPrompt(
            "Ask @CYPHER and @forge to audit", profileIDs: ["cypher", "forge"])
        #expect(prompt.hasPrefix("Ask @CYPHER and @forge to audit\n\n"))
        #expect(prompt.contains("message_agent target: \"cypher\""))
        #expect(prompt.contains("message_agent target: \"forge\""))
        #expect(prompt.contains("If this session has no message_agent tool"))
        #expect(
            ComposerMentionPresentation.annotatedPrompt(
                "email@cypher.com @unknown @file:path", profileIDs: ["cypher", "file"])
                == "email@cypher.com @unknown @file:path")
    }

    @Test func detectsUnfinishedMentionAtCursor() {
        #expect(ComposerMentionPresentation.activeToken(in: "Ask @cy") == "@cy")
        #expect(ComposerMentionPresentation.activeToken(in: "Ask @") == "@")
        #expect(ComposerMentionPresentation.activeToken(in: "Ask @cy ") == nil)
        #expect(ComposerMentionPresentation.activeToken(in: "email@example.com") == nil)
    }

    @Test func replacesUnfinishedMentionWithProfileIDAndTrailingSpace() {
        #expect(ComposerMentionPresentation.replacingActiveToken(in: "Ask @cy", with: "cypher") == "Ask @cypher ")
    }

    @Test func resolvesOneLeadingRosterMentionAsADirectBotRequest() {
        let request = ComposerMentionPresentation.directBotRequest(
            in: "@sentry audit the codebase for regressions",
            profileIDs: ["sentry", "cypher"]
        )

        #expect(request?.profileID == "sentry")
        #expect(request?.text == "audit the codebase for regressions")
        #expect(
            ComposerMentionPresentation.directBotRequest(in: "Please @sentry audit this", profileIDs: ["sentry"]) == nil
        )
        #expect(
            ComposerMentionPresentation.directBotRequest(
                in: "@sentry audit this with @cypher", profileIDs: ["sentry", "cypher"]) == nil)
        #expect(ComposerMentionPresentation.directBotRequest(in: "@unknown audit this", profileIDs: ["sentry"]) == nil)
        #expect(ComposerMentionPresentation.directBotRequest(in: "@sentry", profileIDs: ["sentry"]) == nil)
    }

    @Test func relaysOneEmbeddedRosterMentionWithTheWholeMessage() {
        let ids = ["nexus", "cypher"]
        let text = "i think 03 is done. @Nexus please work on 36"
        #expect(
            ComposerMentionPresentation.botRelayRequest(in: text, profileIDs: ids)
                == .init(profileID: "nexus", text: text))
        #expect(
            ComposerMentionPresentation.botRelayRequest(in: "@nexus audit this", profileIDs: ids)?.text == "audit this")
        #expect(
            ComposerMentionPresentation.botRelayRequest(in: "@nexus do it, then @nexus report", profileIDs: ids)?
                .profileID == "nexus")
        #expect(ComposerMentionPresentation.botRelayRequest(in: "ask @nexus and @cypher", profileIDs: ids) == nil)
        #expect(ComposerMentionPresentation.botRelayRequest(in: "mail me@nexus.dev", profileIDs: ids) == nil)
        #expect(ComposerMentionPresentation.botRelayRequest(in: "@nexus", profileIDs: ids) == nil)
    }

    @Test func explainsWhenAPickedBotWouldNotBeReached() {
        func notice(_ draft: String, attachments: Bool = false, queued: Bool = false) -> String? {
            ComposerMentionPresentation.relayNotice(
                draft: draft, profileIDs: ["nexus", "cypher"], hasAttachments: attachments,
                isQueued: queued)
        }
        #expect(notice("please @ne") == nil)
        #expect(notice("@nexus") == nil)
        #expect(notice("ask @nexus and @cy")?.hasPrefix("Select one Bot per message") == true)
        #expect(notice("ask @ne", attachments: true)?.hasPrefix("Bots get text only") == true)
        #expect(notice("ask @ne", queued: true)?.contains("wait behind queued prompts") == true)
    }

    @Test func attachmentsStayOnTheOrdinarySubmissionPathForBotMentions() {
        #expect(ComposerMentionPresentation.canDirectRouteBot(hasImages: false, hasPDF: false))
        #expect(!ComposerMentionPresentation.canDirectRouteBot(hasImages: true, hasPDF: false))
        #expect(!ComposerMentionPresentation.canDirectRouteBot(hasImages: false, hasPDF: true))
    }
}
