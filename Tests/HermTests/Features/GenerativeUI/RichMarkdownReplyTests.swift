import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct RichMarkdownReplyTests {
    private let source = """
        ## Export formats

        | Format | Size (KB) | Use |
        | :--- | ---: | :--- |
        | **CSV** | 12 | Working with spreadsheets |
        | JSON | 8 | Sharing structured records |
        | Text | 10 | Reading a quick summary |

        > [!TIP]
        > Choose **CSV** to keep the column names in the exported file.
        """

    private func parts(_ source: String) -> [RichMarkdownPart] {
        RichMarkdownPart.project(
            MarkdownRenderDocumentBuilder.build(source: source, key: MarkdownMessageView.renderKey(for: source))
                .sections)
    }

    @Test func projectsOnlyRecognizedBlocksAndPreservesTheMessage() throws {
        #expect(RichMarkdownPart.isCandidate(source))
        let sections = parts(source)
        #expect(sections.count == 3)
        guard sections.count == 3, case .table(let table) = sections[1] else {
            Issue.record("Expected the Markdown table between the heading and tip")
            return
        }
        #expect(sections[0] == .text("## Export formats"))
        #expect(
            sections[2]
                == .callout(.init(tone: .tip, body: "Choose **CSV** to keep the column names in the exported file.")))
        #expect(table.dataset.columns.map(\.type) == [.text, .number, .text])
        #expect(table.dataset.displayedRows(query: "", column: 1, descending: false).map(\.id) == ["1", "2", "0"])
        #expect(table.dataset.displayedRows(query: "spreadsheets", column: nil, descending: false).map(\.id) == ["0"])
        #expect(table.dataset.rows.first?.values.first == "CSV")
        #expect(table.cells[0][0].runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(GenerativeUIIntegration.readableText(ChatMessage(role: .hermes, text: source)) == source)
        #expect(!RichDocument(source).hasSurfaces)
        #expect(RichDocumentParseRequest(source, streaming: true, identity: "test") == nil)
    }

    @Test func ordinaryExamplesAndMalformedStructuresRemainMarkdown() {
        for value in [
            "A short answer.", "> An ordinary quote.", "> [!UNKNOWN]\n> Unrecognized.",
            "> [!NOTE]\n>", "    > [!TIP]\n    > Indented code.",
            "A | B\n--- | ---\na | b | c", "| A | B |\n| Text | Only |",
            "~~~markdown\n" + source + "\n~~~", "````md\n" + source,
            "[Column](https://example.com) | B\n--- | ---\na | b",
        ] {
            #expect(parts(value).isEmpty, "\(value)")
        }
        #expect(!RichMarkdownPart.isCandidate(String(repeating: "|---", count: 20_000)))
        let link = RichMarkdownTable("A | B\n--- | ---\nA\\|B | [docs](https://example.com)")
        #expect(link?.dataset.rows.first?.values == ["A|B", "docs"])
        #expect(link?.cells[0][1].runs.first?.link?.host == "example.com")
    }

    @Test func ordinaryFactListsRequireConsecutiveLabelledValues() throws {
        let markdown = "- **File format:** CSV\n- **Encoding**: UTF-8"
        #expect(RichMarkdownPart.isCandidate(markdown))
        let expected = RichFacts(items: [
            .init(id: "0", label: "File format", value: "CSV"), .init(id: "1", label: "Encoding", value: "UTF-8"),
        ])
        #expect(parts(markdown) == [.facts(expected)])
        #expect(parts(markdown + "\n  \nNext paragraph.") == [.facts(expected), .text("Next paragraph.")])
        #expect(parts(markdown + "\n- A regular bullet").isEmpty)
        #expect(parts("- **File format:** CSV").isEmpty)
        #expect(parts("~~~markdown\n" + markdown + "\n~~~").isEmpty)
    }

    @Test func breakdownValidatesAmountsAndIncludesUnitsInTheReadableReply() {
        func example(_ values: [Double]) -> RichBreakdown {
            .init(
                items: values.enumerated().map { .init(id: String($0.offset), label: "Reading", value: $0.element) },
                unit: "min")
        }
        #expect(example([0, 24]).validate())
        #expect(example([24]).plainText == "Reading: 24 min")
        for values: [Double] in [[], [-1], [.infinity], [.nan], Array(repeating: 0, count: 41)] {
            #expect(!example(values).validate())
        }
    }

    @Test func typedReadingBlocksRejectMissingContentAndRoundTripTheirText() throws {
        for tone in RichCallout.Tone.allCases {
            let value = RichCallout(tone: tone, body: "First paragraph.\n\nSecond paragraph.")
            #expect(
                parts("> [!\(tone.rawValue.uppercased())]\n> First paragraph.\n>\n> Second paragraph.") == [
                    .callout(value)
                ])
            #expect(!RichCallout(tone: tone, body: "  ").validate())
            #expect(!RichCallout(tone: tone, body: String(repeating: "a", count: 16_385)).validate())
        }
        let item = RichFacts.Item(id: "format", label: "Format", value: "CSV")
        #expect(!RichFacts(items: [item, item]).validate())
        #expect(!RichFacts(items: [.init(id: "a", label: " ", value: "Value")]).validate())
        for id in ["facts", "callout"] {
            let descriptor = try #require(RichFeatureRegistry.local.first { $0.id == id })
            let surface = try JSONDecoder().decode(
                RichSurface.self, from: Data(RichFeatureRegistry.exampleSurface(descriptor).utf8))
            #expect(surface.validate())
            #expect(surface.plainText.contains(id == "facts" ? "File format: CSV" : "archived entries"))
            #expect(try JSONDecoder().decode(RichSurface.self, from: JSONEncoder().encode(surface)) == surface)
        }
    }

    @Test func ordinaryReplyExposesSortingAndRespectsThePreference() async throws {
        let suite = "RichMarkdownReplyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = NSApplication.shared
        let old = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(old, forKey: "accessibilityEnhancedUserInterface") }

        func elements(_ element: AnyObject) -> [AnyObject] {
            [element] + (element.accessibilityChildren?() ?? []).flatMap { elements($0 as AnyObject) }
        }
        let message = ChatMessage(role: .hermes, text: source)
        let view = ConversationMessageRow(
            message: message, isStreamingMessage: false, streamingText: nil, activeBotProfileID: nil,
            botsByID: [:], avatarImages: [:], botRosterRevision: 0, onImagePreview: { _ in }
        )
        .defaultAppStorage(defaults).frame(width: 420)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 540),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func sortButton() -> AnyObject? {
            elements(host).first { $0.accessibilityLabel?() == "Sort by Size (KB)" }
        }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if sortButton() != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let heading = try #require(sortButton()?.accessibilityFrame?())
        #expect(try #require(sortButton()).accessibilityPerformPress?() == true)
        host.layoutSubtreeIfNeeded()
        let restore = try #require(
            elements(host).first {
                ($0.accessibilityLabel?() ?? $0.accessibilityTitle?()) == "Restore source order"
            })
        let footer = try #require(restore.accessibilityFrame?())
        #expect(heading.midY > footer.midY && heading.midY - footer.midY < 180, "A short table should hug its rows.")
        defaults.set(false, forKey: GenerativeUIIntegration.preferenceKey)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if sortButton() == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sortButton() == nil)
    }
}
