import Foundation
import SwiftUI
import Testing

@testable import Herm

struct FileAnnotationTests {
    @Test func renderedSelectionsMatchRawMarkdown() {
        let doc = "Use **SQLite** for `local` storage, see [docs](https://x.y).\n- Step one"
        #expect(FileAnnotationText.contains(doc, "Use SQLite for local storage"))
        #expect(FileAnnotationText.contains(doc, "see docs"))
        #expect(FileAnnotationText.contains(doc, "x.y).\n- Step one"))
        #expect(!FileAnnotationText.contains(doc, "Use Postgres"))
        #expect(!FileAnnotationText.contains(doc, "  **  "))
    }

    @Test func rangePicksOccurrenceNearestHint() {
        let rendered = "Step one. Later: Step one again."
        #expect(FileAnnotationText.range(of: "Step one", in: rendered, near: nil) == NSRange(location: 0, length: 8))
        #expect(FileAnnotationText.range(of: "Step one", in: rendered, near: 20) == NSRange(location: 17, length: 8))
        #expect(FileAnnotationText.range(of: "missing", in: rendered, near: 0) == nil)
    }

    @MainActor
    @Test func selectionTrimsSurroundingWhitespace() {
        let text = "a\n  No login.\n• Next" as NSString
        let trimmed = AnnotatableDocumentView<EmptyView>.Coordinator.trimmed(NSRange(location: 1, length: 13), in: text)
        #expect(text.substring(with: trimmed) == "No login.")
        #expect(
            AnnotatableDocumentView<EmptyView>.Coordinator.trimmed(NSRange(location: 1, length: 3), in: text).length
                == 0)
    }

    @Test func promptQuotesEachNote() {
        let notes = [
            FileAnnotation(quote: "Use SQLite", note: "Change to Postgres"),
            FileAnnotation(quote: "Old\nbit", note: "Remove this"),
            FileAnnotation(note: "Shorter overall"),
        ]
        let prompt = FileAnnotationText.prompt(path: "/tmp/plan.md", annotations: notes)
        #expect(prompt.hasPrefix("Please revise `/tmp/plan.md` in place"))
        #expect(prompt.contains("1. \"Use SQLite\" → Change to Postgres"))
        #expect(prompt.contains("2. \"Old bit\" → Remove this"))
        #expect(prompt.contains("3. [General] Shorter overall"))
    }

    @Test func lineDiffListsRemovedThenInserted() {
        let diff = FileAnnotationText.lineDiff(old: "a\nb\nc", new: "a\nB\nc\nd")
        #expect(diff == [.init(sign: "-", text: "b"), .init(sign: "+", text: "B"), .init(sign: "+", text: "d")])
        #expect(FileAnnotationText.lineDiff(old: "same", new: "same").isEmpty)
    }

    @MainActor
    @Test func reconcileMarksSentNotesWhoseQuoteVanished() throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("reviews-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let center = FilePreviewCenter(fileURL: store)
        center.add(FileAnnotation(quote: "Use SQLite", note: "Postgres"), to: "/p.md")
        center.add(FileAnnotation(quote: "Keep me", note: "?"), to: "/p.md")
        center.markSent("/p.md", baseline: "Use **SQLite**. Keep me.")
        center.add(FileAnnotation(quote: "Use SQLite", note: "draft"), to: "/p.md")

        center.reconcile("/p.md", contents: "Use Postgres. Keep me.")

        let notes = center.review("/p.md").annotations
        #expect(notes.map(\.resolved) == [true, false, false])
        #expect(center.review("/p.md").baseline == "Use **SQLite**. Keep me.")
        // Persisted: a fresh center reads the same review back.
        center.flushSaves()
        #expect(FilePreviewCenter(fileURL: store).review("/p.md") == center.review("/p.md"))
    }

    @MainActor @Test func backgroundSavesRetainTheLastOrderedSnapshot() {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("reviews-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let center = FilePreviewCenter(fileURL: store)
        var note = FileAnnotation(note: "first")
        center.add(note, to: "/p.md")
        for index in 0..<40 {
            note.note = "edit \(index)"
            center.update(note, in: "/p.md")
        }
        center.markSent("/p.md", baseline: "Last review")
        center.flushSaves()
        #expect(FilePreviewCenter(fileURL: store).review("/p.md") == center.review("/p.md"))
        #expect(center.review("/p.md").annotations.first?.note == "edit 39")
    }
}
