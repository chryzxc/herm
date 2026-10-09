import Testing
@testable import Herm

struct ComposerMentionTests {
    @Test func annotatesEmbeddedAndMultipleMentionsWithCanonicalToolTargets() {
        let prompt = ComposerMentionPresentation.annotatedPrompt("Ask @CYPHER and @forge to audit", profileIDs: ["cypher", "forge"])
        #expect(prompt.hasPrefix("Ask @CYPHER and @forge to audit\n\n"))
        #expect(prompt.contains("message_agent target: \"cypher\""))
        #expect(prompt.contains("message_agent target: \"forge\""))
        #expect(prompt.contains("If this session has no message_agent tool"))
        #expect(ComposerMentionPresentation.annotatedPrompt("email@cypher.com @unknown @file:path", profileIDs: ["cypher", "file"]) == "email@cypher.com @unknown @file:path")
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
        #expect(ComposerMentionPresentation.directBotRequest(in: "Please @sentry audit this", profileIDs: ["sentry"]) == nil)
        #expect(ComposerMentionPresentation.directBotRequest(in: "@sentry audit this with @cypher", profileIDs: ["sentry", "cypher"]) == nil)
        #expect(ComposerMentionPresentation.directBotRequest(in: "@unknown audit this", profileIDs: ["sentry"]) == nil)
        #expect(ComposerMentionPresentation.directBotRequest(in: "@sentry", profileIDs: ["sentry"]) == nil)
    }

    @Test func attachmentsStayOnTheOrdinarySubmissionPathForBotMentions() {
        #expect(ComposerMentionPresentation.canDirectRouteBot(hasImages: false, hasPDF: false))
        #expect(!ComposerMentionPresentation.canDirectRouteBot(hasImages: true, hasPDF: false))
        #expect(!ComposerMentionPresentation.canDirectRouteBot(hasImages: false, hasPDF: true))
    }
}
