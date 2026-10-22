import AppKit
import Foundation
import Testing
@testable import Herm

@MainActor
struct ConversationRenderOptimizationTests {
    @Test func windowPagingTraversesAndReversesInFourRowBatches() {
        let messages = (0..<500).map { ChatMessage(role: .hermes, text: "Message \($0)") }
        var range = ConversationMessageWindow.tailRange(totalCount: messages.count)
        var visited = Set(range)
        for earlier in [true, false, true, false] {
            for _ in 0..<500 {
                let previous = range
                let visible = earlier
                    ? previous.lowerBound...min(previous.lowerBound + 2, previous.upperBound - 1)
                    : max(previous.lowerBound, previous.upperBound - 3)...(previous.upperBound - 1)
                range = earlier
                    ? ConversationMessageWindow.revealEarlier(previous, totalCount: messages.count, visibleSpan: visible)
                    : ConversationMessageWindow.revealLater(previous, totalCount: messages.count, visibleSpan: visible)
                let added = Set(range).subtracting(previous)
                #expect(added.count <= 4)
                #expect(range.contains(visible.lowerBound) && range.contains(visible.upperBound))
                #expect(range.lowerBound >= 0 && range.upperBound <= messages.count)
                #expect(range.count <= 36)
                #expect(messages[range].map(\.id) == range.map { messages[$0].id })
                visited.formUnion(range)
                if range == previous { break }
            }
            #expect(earlier ? range.lowerBound == 0 : range.upperBound == messages.count)
        }
        #expect(visited == Set(messages.indices))
        let middle = 200..<225
        let earlier = ConversationMessageWindow.revealEarlier(middle, totalCount: 500, visibleSpan: 205...210)
        let reversed = ConversationMessageWindow.revealLater(earlier, totalCount: 500, visibleSpan: 205...210)
        #expect(earlier == 196..<215)
        #expect(reversed == 201..<219)
    }

    @Test func windowPagingProtectsOversizedVisibleSpans() {
        #expect(ConversationMessageWindow.revealEarlier(
            100..<150, totalCount: 500, visibleSpan: 100...149
        ) == 96..<150)
        #expect(ConversationMessageWindow.revealLater(
            100..<150, totalCount: 500, visibleSpan: 100...149
        ) == 100..<154)
        #expect(ConversationMessageWindow.revealEarlier(
            2..<14, totalCount: 500, visibleSpan: nil
        ) == 0..<14)
        #expect(ConversationMessageWindow.revealLater(
            486..<498, totalCount: 500, visibleSpan: nil
        ) == 486..<500)
    }

    @Test func windowInitialJumpAndBackstopRemainIndependentOfPaging() throws {
        let messages = (0..<500).map { ChatMessage(role: .hermes, text: "Message \($0)") }
        #expect(ConversationMessageWindow.tailRange(totalCount: 500) == 488..<500)
        #expect(ConversationMessageWindow.rangeForSessionReplacement(totalCount: 500) == 488..<500)
        #expect(ConversationMessageWindow.compactedRange(totalCount: 500) == 488..<500)
        let items = ConversationMessageWindow.navigatorItems(messages: messages, sessionID: "history")
        let jump = try #require(ConversationMessageWindow.jumpPlan(
            for: items[250], sessionID: "history", messages: messages))
        #expect(jump.messageID == messages[250].id)
        #expect(jump.windowRange == 238..<263)
        #expect(ConversationMessageWindow.jumpWindow(aroundIndex: 0, totalCount: 500) == 0..<13)
        #expect(ConversationMessageWindow.jumpWindow(aroundIndex: 499, totalCount: 500) == 487..<500)
        #expect(ConversationMessageWindow.revealEarlier(
            200..<236, totalCount: 500, visibleSpan: nil) == 196..<232)
        #expect(ConversationMessageWindow.revealLater(
            200..<236, totalCount: 500, visibleSpan: nil) == 204..<240)
    }

    @Test func windowPagingClampsShrinkAndRetainsPrependIdentity() {
        let messages = (0..<500).map { ChatMessage(role: .hermes, text: "Message \($0)") }
        let shrunk = ConversationMessageWindow.visibleRange(488..<500, totalCount: 490)
        #expect(shrunk == 488..<490)
        #expect(ConversationMessageWindow.revealEarlier(shrunk, totalCount: 490, visibleSpan: 488...489) == 484..<490)
        #expect(ConversationMessageWindow.revealLater(shrunk, totalCount: 490, visibleSpan: 488...489) == shrunk)
        #expect(ConversationMessageWindow.revealEarlier(0..<0, totalCount: 0, visibleSpan: nil).isEmpty)
        #expect(ConversationMessageWindow.revealLater(0..<0, totalCount: 0, visibleSpan: nil).isEmpty)
        let prepended = (0..<20).map { ChatMessage(role: .hermes, text: "Earlier \($0)") } + messages
        // The transcript's prepend hook shifts the mounted indices before paging.
        let shifted = 220..<245
        #expect(prepended[shifted].map(\.id) == messages[200..<225].map(\.id))
        let revealed = ConversationMessageWindow.revealEarlier(shifted, totalCount: prepended.count, visibleSpan: 220...224)
        #expect(revealed == 216..<229)
        #expect(prepended[220..<225].map(\.id) == messages[200..<205].map(\.id))
        #expect(ConversationMessageWindow.rangeAfterCountChange(
            200..<225, oldCount: 500, newCount: 501, isAtBottom: false) == 200..<225)
        #expect(ConversationMessageWindow.rangeAfterCountChange(
            488..<500, oldCount: 500, newCount: 501, isAtBottom: true) == 489..<501)
    }

    @Test func navigatorProjectionTracksCanonicalEditsAndSessionReplacement() {
        let model = DockModel(initialSessionID: "history")
        model.messages = (0..<500).map { ChatMessage(role: .hermes, text: "Message \($0)") }
        let original = model.messageNavigatorItems
        #expect(model.messageNavigatorItems == original)
        model.messages[250] = ChatMessage(id: model.messages[250].id, role: .hermes, text: "Updated message")
        #expect(model.messageNavigatorItems[250].preview == "Updated message")
        model.messages.append(ChatMessage(role: .user, text: "New message"))
        #expect(model.messageNavigatorItems.count == 501)
        model.newChat()
        #expect(model.messageNavigatorItems.isEmpty)
    }

    @Test func thumbnailKeyChangesWhenImageIdentityInputsChange() {
        let id = UUID()
        let base = ConversationThumbnailCache.key(
            messageID: id,
            index: 0,
            imageCount: 1,
            contentRevision: 10
        )

        #expect(base != ConversationThumbnailCache.key(messageID: id, index: 1, imageCount: 1, contentRevision: 10))
        #expect(base != ConversationThumbnailCache.key(messageID: id, index: 0, imageCount: 2, contentRevision: 10))
        #expect(base != ConversationThumbnailCache.key(messageID: id, index: 0, imageCount: 1, contentRevision: 11))
        #expect(base == ConversationThumbnailCache.key(messageID: id, index: 0, imageCount: 1, contentRevision: 10))
    }

    @Test func mentionRosterRefreshOnlyRunsWhenPickerOpens() {
        #expect(ComposerMentionRefreshPolicy.shouldRefresh(wasPickerVisible: false, isPickerVisible: true))
        #expect(!ComposerMentionRefreshPolicy.shouldRefresh(wasPickerVisible: true, isPickerVisible: true))
        #expect(!ComposerMentionRefreshPolicy.shouldRefresh(wasPickerVisible: true, isPickerVisible: false))
        #expect(!ComposerMentionRefreshPolicy.shouldRefresh(wasPickerVisible: false, isPickerVisible: false))
    }

    @Test func longStreamingMarkdownUsesNativeRendererAtTheFixedBoundary() {
        let below = String(repeating: "a", count: StreamingMarkdownRendererPolicy.nativeThresholdBytes - 1)
        let at = String(repeating: "a", count: StreamingMarkdownRendererPolicy.nativeThresholdBytes)
        #expect(!StreamingMarkdownRendererPolicy.usesNativeRenderer(for: below))
        #expect(StreamingMarkdownRendererPolicy.usesNativeRenderer(for: at))
    }

    @Test func transcriptCacheKeyUsesMessageIdentityAndContentRevision() {
        let message = ChatMessage(id: UUID(), role: .hermes, text: "short")
        let key = "message:\(message.id.uuidString):\(message.contentRevision)"
        #expect(key.contains(message.id.uuidString))
        #expect(key.hasSuffix(":\(message.contentRevision)"))
    }

    @Test func nativeMarkdownDocumentPreservesContentAndLinks() {
        let source = "# Heading\n\nRead [the guide](https://example.com).\n\n```swift\nlet value = 1\n```"
        let rendered = NativeMarkdownMessageView.Coordinator.attributedString(for: source)
        #expect(rendered.string.contains("Heading"))
        #expect(rendered.string.contains("the guide"))
        #expect(rendered.length > 0)
    }

    @Test func semanticDocumentKeepsExactSourceAndStructuredBlocks() {
        let source = "# Heading\n\n| Name | Value |\n| --- | --- |\n| rows | 36 |\n\n```swift\nlet value = 1\n```\n"
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1)
        let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)
        #expect(document.source == source)
        #expect(document.sections.map(\.source).joined() == source)
        #expect(document.sections.contains { if case .table = $0.kind { true } else { false } })
        #expect(document.sections.contains { if case .code = $0.kind { true } else { false } })
    }

    @Test func mergedListAndQuoteLinesShareOneSectionUntilBlockChanges() {
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1)
        let source = """
        Intro paragraph.

        - one
        - two
        - three

        > quoted line one
        > quoted line two

        - four
        """
        let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)

        let listSections = document.sections.filter { if case .list = $0.kind { true } else { false } }
        let quoteSections = document.sections.filter { if case .quote = $0.kind { true } else { false } }
        #expect(listSections.count == 2)
        #expect(quoteSections.count == 1)
        #expect(listSections[0].source == "- one\n- two\n- three\n\n")
        #expect(listSections[1].source == "- four")
        #expect(quoteSections[0].source == "> quoted line one\n> quoted line two\n\n")
        #expect(document.sections.map(\.source).joined() == source)
    }

    @Test func listMergingSplitsOnMarkerAndIndentationChanges() {
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1)
        let source = "- alpha\n* beta\n  - nested\n- alpha again\n"
        let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)

        let listSections = document.sections.filter { if case .list = $0.kind { true } else { false } }
        #expect(listSections.count == 4)
        #expect(listSections[0].source == "- alpha\n")
        #expect(listSections[1].source == "* beta\n")
        #expect(listSections[2].source == "  - nested\n")
        #expect(listSections[3].source == "- alpha again\n")
        #expect(document.sections.map(\.source).joined() == source)
    }

    @Test func compactionStyleListWallYieldsBoundedSectionCount() {
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1)
        let body = (1...200).map { "- step \($0)" }.joined(separator: "\n")
        let document = MarkdownRenderDocumentBuilder.build(source: body, key: key)

        #expect(document.sections.count <= 10)
        #expect(document.sections.map(\.source).joined() == body)
    }

    @Test func streamingChunkSectionsRemainOneToOneWithChunks() {
        let chunks = [
            StreamingPresentationChunk(
                id: 0, text: "- one\n", revision: 0, isMutableTail: false,
                context: .list(marker: "-", indentation: 0)),
            StreamingPresentationChunk(
                id: 1, text: "- two\n", revision: 0, isMutableTail: false,
                context: .list(marker: "-", indentation: 0)),
            StreamingPresentationChunk(
                id: 2, text: "- three", revision: 0, isMutableTail: false,
                context: .list(marker: "-", indentation: 0)),
        ]

        let sections = MarkdownRenderDocumentBuilder.sections(for: chunks)

        #expect(sections.count == chunks.count)
        #expect(sections.map(\.source) == chunks.map(\.text))
    }

    @Test func nativeDocumentContainerCachesIntrinsicHeightPerWidth() {
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1)
        let document = MarkdownRenderDocumentBuilder.build(
            source: (1...40).map { "- item \($0)" }.joined(separator: "\n"),
            key: key
        )
        let container = NativeMarkdownDocumentContainerView(frame: NSRect(x: 0, y: 0, width: 620, height: 10))
        container.apply(document: document)

        #expect(container.cachedIntrinsicHeight == nil)
        let first = container.intrinsicContentSize.height
        #expect(container.cachedIntrinsicHeight == first)
        #expect(container.cachedSolveWidth == 620)

        let second = container.intrinsicContentSize.height
        #expect(second == first)
        #expect(container.cachedIntrinsicHeight == first)

        container.frame.size.width = 480
        _ = container.intrinsicContentSize.height
        #expect(container.cachedSolveWidth == 480)

        let resizedHeight = container.cachedIntrinsicHeight
        container.applyStreaming(sections: document.sections, source: document.source)
        #expect(container.cachedIntrinsicHeight == resizedHeight)
        #expect(container.cachedSolveWidth == 480)

        let changed = MarkdownRenderDocumentBuilder.build(source: document.source + "\n- another item", key: key)
        container.apply(document: changed)
        #expect(container.cachedIntrinsicHeight == nil)

        _ = container.intrinsicContentSize
        container.reset()
        container.apply(document: document)
        #expect(container.cachedIntrinsicHeight == nil)
    }

    @Test func completionProjectionCanDropBotEnvelopeWithoutReparse() {
        let streaming = StreamingText()
        let envelope = "Message from 🤖 Builder (@builder):\n\n# Result\n\nready"
        streaming.appendPresentation(envelope)
        streaming.retainCompletionPresentation()
        let chunks = streaming.completionChunks(matching: "# Result\n\nready")
        #expect(chunks?.map(\.text).joined() == "# Result\n\nready")
    }

    @Test func completedMessageRetainsNativeTableLayoutAmongProse() throws {
        let markdown = """
        I checked the current source:

        | Area | Existing coverage |
        | --- | --- |
        | **Design** | Planning instructions and safe decomposition. |
        | Review | Independent review and regression analysis. |

        > Preserve the existing principles.

        The distinction follows.
        """
        let view = NativeMarkdownTextSectionView()
        view.update(markdown: markdown, kind: .prose)
        let text = try #require(view.textStorage)
        var cells: [NSTextTableBlock] = []
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
               !cells.contains(where: { $0 === block }) { cells.append(block) }
        }
        #expect(cells.count == 6)
        #expect(cells.allSatisfy { $0.table === cells.first?.table && $0.table.numberOfColumns == 2 })
        #expect(!text.string.contains("│"))
        #expect(!text.string.contains("---"))
        #expect(text.string.contains("The distinction follows."))
        let after = (text.string as NSString).range(of: "The distinction follows.")
        let afterStyle = text.attribute(.paragraphStyle, at: after.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(afterStyle?.textBlocks.isEmpty == true)
        #expect(view.measuredHeight(forWidth: 480) > 0)
        #expect(view.measuredHeight(forWidth: 300) > view.measuredHeight(forWidth: 700))
        if let directory = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_DIR"] {
            let width: CGFloat = 700
            view.frame = NSRect(x: 0, y: 0, width: width, height: view.measuredHeight(forWidth: width))
            let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("completed-markdown-table.png"))
        }
    }

    @Test func tablesAllowOptionalOuterPipesAcrossRenderers() {
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1)
        for table in [
            "Area | Coverage\n--- | ---\n**Design** | Planning\nReview | Tests",
            "| Area | Coverage\n| --- | --- |\nDesign | Planning |\n| Review | Tests |"
        ] {
            let source = "Intro.\n\n" + table + "\n\nAfter."
            let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)
            #expect(document.sections.map(\.source).joined() == source)
            let tables = document.sections.filter { $0.kind == .table }
            #expect(tables.count == 1)
            #expect(NativeMarkdownAttributedTextBuilder.isPureTable(table))
            let output = NativeMarkdownAttributedTextBuilder.table(table, palette: NativeMarkdownPalette()).string
            let style = output.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            #expect((style?.textBlocks.first as? NSTextTableBlock)?.table.numberOfColumns == 2)
            #expect(!output.string.contains("---"))
            let rows = MarkdownMessageView.renderBlocks(for: source).filter {
                if case .tableRow = $0 { return true }; return false
            }
            #expect(rows.count == 3)
            let chunks = [StreamingPresentationChunk(id: 0, text: table, revision: 0, isMutableTail: false, context: .paragraph)]
            #expect(MarkdownRenderDocumentBuilder.sections(for: chunks).first?.kind == .table)
        }
        #expect(!NativeMarkdownAttributedTextBuilder.isPureTable("Use a | b in prose."))
        #expect(!NativeMarkdownAttributedTextBuilder.isPureTable("a \\| b\n--- | ---"))
    }

    @Test func tableCellsKeepEmptyColumnsAndDetectSeparators() {
        #expect(NativeMarkdownAttributedTextBuilder.tableCells("| a || c |") == ["a", "", "c"])
        #expect(NativeMarkdownAttributedTextBuilder.tableCells("| a \\| b | c |").count == 2)
        #expect(NativeMarkdownAttributedTextBuilder.isSeparatorRow(["---", ":--:", "--:"]))
        #expect(!NativeMarkdownAttributedTextBuilder.isSeparatorRow(["a", "---"]))
    }

    @Test func proseAfterAClosingFenceIsNotRenderedAsCode() {
        let chunks = [
            StreamingPresentationChunk(
                id: 0, text: "```swift\nlet x = 1\n```\nDone here.\n", revision: 0, isMutableTail: false,
                context: .fencedCode(marker: "`", length: 3, language: "swift")),
        ]

        let sections = MarkdownRenderDocumentBuilder.sections(for: chunks)

        #expect(sections.map(\.source).joined() == chunks[0].text)
        #expect(sections.count == 2)
        #expect(sections.first?.kind == .code(language: "swift"))
        #expect(sections.last?.kind == .prose)
    }

    @Test func completionSnapshotIsScopedToItsMessage() {
        let streaming = StreamingText()
        let ownerID = UUID()
        streaming.appendPresentation("# Result\n\nready")
        streaming.retainCompletionPresentation(for: ownerID)

        #expect(streaming.completionChunks(matching: "# Result\n\nready", messageID: UUID()) == nil)
        #expect(streaming.completionChunks(matching: "# Result\n\nready", messageID: ownerID) != nil)
    }

    @Test func nativeDocumentHeightGrowsAsTheWidthNarrows() {
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1)
        let paragraph = String(repeating: "Long wrapping transcript text. ", count: 60)
        let document = MarkdownRenderDocumentBuilder.build(source: "# Title\n\n\(paragraph)", key: key)
        let container = NativeMarkdownDocumentContainerView(frame: NSRect(x: 0, y: 0, width: 620, height: 10))
        container.apply(document: document)

        let wide = container.measuredHeight(forWidth: 620)
        let narrow = container.measuredHeight(forWidth: 300)

        #expect(wide > 0)
        #expect(narrow > wide)
        // A zero-width proposal must never lay text out one glyph per line.
        #expect(NativeMarkdownDocumentContainerView(frame: .zero).intrinsicContentSize.height == 0)
    }
    @Test(arguments: DockThemeID.allCases)
    func sizingProbesKeepRenderedResponseAtItsAssignedWidth(theme: DockThemeID) throws {
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        defer { DockThemeRuntime.current = savedTheme; DockThemeRuntime.revision = savedRevision }
        DockThemeRuntime.current = theme
        DockThemeRuntime.revision &+= 1
        let source = """
        ## A useful structure when a question surprises you

        **Clarify → propose the simplest solution → explain failure cases → discuss trade-offs → describe verification.**

        For example:

        > Before choosing a design, I’d clarify the expected traffic and consistency requirements. I’d start with the existing database and a straightforward API. The main risks are concurrent writes and unsafe retries, so I’d protect those with atomic operations and idempotency. I’d add infrastructure only if measurements or requirements justify it.
        """
        let document = MarkdownRenderDocumentBuilder.build(
            source: source, key: MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1))
        let container = NativeMarkdownDocumentContainerView(frame: .zero)
        container.keepsAccessibilitySectionsMounted = true
        container.apply(document: document)
        for width: CGFloat in [620, 300, 740, 620, 619.75, 620.25, 300] {
            let height = container.measuredHeight(forWidth: width)
            container.setFrameSize(NSSize(width: width, height: height))
            container.layoutSubtreeIfNeeded()
            // SwiftUI may probe other widths without assigning a new frame.
            _ = container.measuredHeight(forWidth: 250)
            _ = container.measuredHeight(forWidth: 900)
            #expect(container.measuredHeight(forWidth: width) == height)
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
            for section in container.subviews.compactMap({ $0 as? NativeMarkdownTextSectionView }) {
                let textContainer = try #require(section.textContainer)
                let layout = try #require(section.layoutManager)
                layout.ensureLayout(for: textContainer)
                #expect(textContainer.containerSize.width == section.bounds.width)
                #expect(ceil(layout.usedRect(for: textContainer).height) == section.bounds.height)
                #expect(section.frame.maxY <= height)
            }
        }
    }

    @Test func markdownKeepsOnlyWebAndMailLinksClickable() {
        let parsed = NativeMarkdownAttributedTextBuilder.inlineMarkdown(
            "[a](https://x.dev) [b](file:///Applications/Calculator.app) [c](vscode://x) [d](mailto:a@b.c)"
        )
        let links = parsed.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["https://x.dev", "mailto:a@b.c"])
        #expect(String(parsed.characters).contains("b c"))
    }
}
