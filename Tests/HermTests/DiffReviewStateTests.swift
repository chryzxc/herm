import AppKit
import Testing

@testable import Herm

@MainActor
struct DiffReviewStateTests {
    private let document = DiffDocument(path: "main.swift", patch: "@@ -1 +1 @@\n-old\n+new")

    @Test func gutterCommentsKeepOldAndNewLineAnchorsAndDisableWithTheAction() throws {
        let canvas = DiffCanvasContainer(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        let document = DiffDocument(path: "file.swift", patch: "@@ -4,2 +7,2 @@\n-old\n+new\n context")
        for split in [false, true] {
            var comments: [DiffLine] = []
            canvas.update(
                document, split: split, wraps: false, wordDiffs: false, findRequest: 0,
                reveal: nil, viewport: nil, onNote: { _ in }, onComment: { comments.append($0) })
            canvas.layoutSubtreeIfNeeded()
            let stack = try #require(canvas.subviews.first as? NSStackView)
            for case let scroll as NSScrollView in stack.arrangedSubviews {
                let ruler = try #require(scroll.verticalRulerView)
                let image = NSImage(size: NSSize(width: 100, height: 400))
                image.lockFocus()
                ruler.drawHashMarksAndLabels(in: ruler.bounds)
                image.unlockFocus()
                let buttons = ruler.subviews.compactMap { $0 as? NSButton }
                #expect(!buttons.isEmpty)
                for button in buttons { button.performClick(nil) }
            }
            #expect(comments.contains { $0.oldLine == 4 && $0.newLine == nil })
            #expect(comments.contains { $0.newLine == 7 && $0.oldLine == nil })
            #expect(!comments.contains { $0.oldLine == nil && $0.newLine == nil })
            canvas.update(
                document, split: split, wraps: false, wordDiffs: false, findRequest: 0,
                reveal: nil, viewport: nil, onNote: { _ in }, onComment: nil)
            for case let scroll as NSScrollView in stack.arrangedSubviews {
                let ruler = try #require(scroll.verticalRulerView)
                let image = NSImage(size: NSSize(width: 100, height: 400))
                image.lockFocus()
                ruler.drawHashMarksAndLabels(in: ruler.bounds)
                image.unlockFocus()
                #expect(ruler.subviews.compactMap { $0 as? NSButton }.isEmpty)
            }
        }
    }

    @Test func commentingGutterStartsAtTheSourceEdgeAfterWindowLayout() async throws {
        let canvas = DiffCanvasContainer(frame: NSRect(x: 0, y: 0, width: 352, height: 200))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        canvas.update(
            DiffDocument(path: "file.swift", patch: "@@ -1 +1 @@\n-old\n+" + String(repeating: "source ", count: 60)),
            split: false, wraps: false, wordDiffs: false, findRequest: 0,
            reveal: nil, viewport: nil, onNote: { _ in }, onComment: { _ in })
        for _ in 0..<4 {
            canvas.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let stack = try #require(canvas.subviews.first as? NSStackView)
        let scroll = try #require(stack.arrangedSubviews.first as? NSScrollView)
        #expect(scroll.contentView.bounds.minX == -scroll.contentView.contentInsets.left)
    }

    @Test func longDiffStartsAtLeftEdge() throws {
        let canvas = DiffCanvasContainer(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        let document = DiffDocument(
            path: "long.swift", patch: "@@ -1 +1 @@\n-old\n+" + String(repeating: "source ", count: 100))
        for split in [false, true] {
            canvas.update(
                document, split: split, wraps: false, wordDiffs: false, findRequest: 0,
                reveal: nil, viewport: nil, onNote: { _ in }, onComment: nil)
            canvas.layoutSubtreeIfNeeded()
            let stack = try #require(canvas.subviews.first as? NSStackView)
            for case let scroll as NSScrollView in stack.arrangedSubviews {
                #expect(scroll.contentView.bounds.minX == -scroll.contentView.contentInsets.left)
            }
        }
    }

    @Test func wrappedLongLinesFitThePaneAfterResizing() throws {
        let canvas = DiffCanvasContainer(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        let longLine = String(repeating: "longIdentifier", count: 60)
        let document = DiffDocument(path: "long.swift", patch: "@@ -1 +1 @@\n-" + longLine + "\n+" + longLine)
        for split in [false, true] {
            canvas.update(
                document, split: split, wraps: true, wordDiffs: false, findRequest: 0,
                reveal: nil, viewport: nil, onNote: { _ in }, onComment: nil)
            for width in [1000.0, 352.0, 800.0] {
                canvas.setFrameSize(NSSize(width: width, height: 400))
                canvas.layoutSubtreeIfNeeded()
                let stack = try #require(canvas.subviews.first as? NSStackView)
                for case let scroll as NSScrollView in stack.arrangedSubviews {
                    let text = try #require(scroll.documentView as? NSTextView)
                    let container = try #require(text.textContainer)
                    let layout = try #require(text.layoutManager)
                    layout.ensureLayout(for: container)
                    #expect(!scroll.hasHorizontalScroller)
                    #expect(!text.isHorizontallyResizable)
                    #expect(container.widthTracksTextView)
                    #expect(text.frame.width <= scroll.contentSize.width + 1)
                    #expect(layout.usedRect(for: container).height > CGFloat(document.lines.count) * 21)
                    #expect(text.string.contains(longLine))
                }
            }
        }
    }

    @Test func oneSidedSplitDiffUsesOneFullWidthPane() throws {
        let canvas = DiffCanvasContainer(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        for patch in ["@@ -0,0 +1 @@\n+added", "@@ -1 +0,0 @@\n-deleted"] {
            canvas.update(
                DiffDocument(path: "file.swift", patch: patch), split: true, wraps: true,
                wordDiffs: false, findRequest: 0, reveal: nil, viewport: nil, onNote: { _ in }, onComment: nil)
            canvas.layoutSubtreeIfNeeded()
            let stack = try #require(canvas.subviews.first as? NSStackView)
            #expect(stack.arrangedSubviews.count == 1)
            let scroll = try #require(stack.arrangedSubviews.first as? NSScrollView)
            #expect(scroll.frame.width > 900)
            let text = try #require(scroll.documentView as? NSTextView)
            #expect(text.string.contains(patch.contains("+added") ? "added" : "deleted"))
        }
    }

    @Test func cachedDocumentsKeepOriginalAndExpandedSourcesSeparate() {
        let state = DiffReviewState()
        let original = state.document(path: "file.swift", patch: "@@ -2 +2 @@\n-old\n+new")
        let expanded = state.document(path: "file.swift", patch: "@@ -1,2 +1,2 @@\n before\n-old\n+new")
        #expect(original.identity != expanded.identity)
        #expect(state.document(path: "file.swift", patch: original.patch) == original)
        #expect(state.document(path: "file.swift", patch: expanded.patch) == expanded)
        let other = state.document(path: "other.swift", patch: original.patch)
        #expect(other.path == "other.swift")
        #expect(other.identity != original.identity)
        let changed = state.document(path: "file.swift", patch: "@@ -2 +2 @@\n-old\n+changed")
        #expect(changed.identity != original.identity)
    }

    @Test func aHunkWithoutSourceLinesCannotCreateAnAnchor() {
        let state = DiffReviewState()
        state.beginNote(
            selection: DiffSelection(lines: []), documentID: document.identity,
            path: document.path, comparison: nil)
        #expect(state.pendingNote == nil)
        #expect(state.contextError != nil)
    }

    @Test func refreshedComparisonKeepsThePendingNotesOriginalAnchor() throws {
        let state = DiffReviewState()
        let original = DiffComparisonIdentity(repository: "/fixture", revision: String(repeating: "a", count: 40))
        let changed = DiffComparisonIdentity(repository: "/fixture", revision: String(repeating: "b", count: 40))
        let identity = original.documentID(document)
        state.revisionNotes.register(path: document.path, identity: identity)
        state.beginNote(
            selection: DiffSelection(lines: Array(document.lines.suffix(1))),
            documentID: identity, path: document.path, comparison: original)
        state.note = "Handle empty input"
        state.revisionNotes.register(path: document.path, identity: changed.documentID(document))
        #expect(state.saveNote())
        let saved = try #require(state.notes.first)
        #expect(saved.documentID == identity)
        #expect(saved.comparison == original)
        #expect(saved.selection.excerpt == "new")
        #expect(state.revisionNotes.isStale(saved))
        #expect(state.pendingNote == nil)
    }

    @Test func cancelledEditLeavesTheOriginalNoteUntouched() throws {
        let state = DiffReviewState()
        let note = RevisionNote(
            documentID: document.identity, path: document.path,
            selection: DiffSelection(lines: document.lines), text: "Original")
        state.notes = [note]
        state.editNote(note)
        state.note = "Uncommitted edit"
        state.cancelNote()
        #expect(state.notes.first?.id == note.id)
        #expect(state.notes.first?.text == "Original")
        #expect(state.pendingNote == nil)
    }

    @Test func concurrentRemovalKeepsEditedTextWithoutRecreatingTheNote() {
        let state = DiffReviewState()
        let note = RevisionNote(
            documentID: document.identity, path: document.path,
            selection: DiffSelection(lines: document.lines), text: "Original")
        state.notes = [note]
        state.editNote(note)
        state.note = "Keep this edited text"
        state.notes = []
        #expect(!state.saveNote())
        #expect(state.notes.isEmpty)
        #expect(state.note == "Keep this edited text")
        #expect(state.pendingNote?.id == note.id)
        #expect(state.noteError != nil)
    }

    @Test func oversizeUnicodeNoteStaysEditableUntilCorrected() {
        let state = DiffReviewState()
        state.beginNote(
            selection: DiffSelection(lines: document.lines), documentID: document.identity,
            path: document.path, comparison: nil)
        state.note = String(repeating: "🙂", count: 5000)
        #expect(!state.saveNote())
        #expect(state.notes.isEmpty)
        #expect(state.pendingNote != nil)
        #expect(state.noteError != nil)
        state.note = "Shortened note"
        #expect(state.noteError == nil)
        #expect(state.saveNote())
        #expect(state.notes.first?.text == "Shortened note")
    }

    @Test func fullTrayStillAllowsEditingAnExistingNote() throws {
        let state = DiffReviewState()
        state.notes = (0..<100).map { index in
            RevisionNote(
                documentID: document.identity, path: document.path,
                selection: DiffSelection(lines: document.lines), text: "Note \(index)")
        }
        state.beginNote(
            selection: DiffSelection(lines: document.lines), documentID: document.identity,
            path: document.path, comparison: nil)
        state.note = "New note retained for later"
        #expect(!state.saveNote())
        #expect(state.pendingNote != nil)
        #expect(state.notes.count == 100)
        state.editNote(try #require(state.notes.first))
        state.note = "Corrected existing note"
        #expect(state.saveNote())
        #expect(state.notes.count == 100)
        #expect(state.notes.first?.text == "Corrected existing note")
    }

    @Test func mixedUnifiedSelectionUsesTheWholeRangeOnItsAnchorSide() {
        let patch = "@@ -10,3 +10,2 @@\n-a\n-b\n-c\n+x\n+y"
        let selection = DiffSelection(lines: DiffDocument(path: "file", patch: patch).lines)
        let note = RevisionNote(documentID: "captured", path: "file", selection: selection, text: "Review this")
        #expect(note.locationLabel == "file:10–12 · old")
        #expect(note.context(currentIdentity: "captured").body.contains("old lines 10–12"))
    }

    @Test func unchangedPatchRebindsActionsWithoutLosingSelection() throws {
        _ = NSApplication.shared
        let canvas = DiffCanvasContainer(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        var callbacks: [String] = []
        var commented = false
        canvas.update(
            document, split: false, wraps: false, wordDiffs: false, findRequest: 0,
            reveal: nil, viewport: nil, onNote: { _ in callbacks.append("old revision") }, onComment: nil)
        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let text = try #require(textView(in: canvas))
        let selection = (text.string as NSString).range(of: "new")
        #expect(selection.location != NSNotFound)
        text.setSelectedRange(selection)
        canvas.update(
            document, split: false, wraps: false, wordDiffs: false, findRequest: 0,
            reveal: nil, viewport: nil, onNote: { _ in callbacks.append("new revision") },
            onComment: { _ in commented = true })
        #expect(textView(in: canvas) === text)
        #expect(text.selectedRange() == selection)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 0))
        let menu = try #require(text.menu(for: event))
        let note = try #require(menu.items.first { $0.title == "Add revision note" })
        #expect(NSApp.sendAction(try #require(note.action), to: note.target, from: note))
        #expect(callbacks == ["new revision"])
        let comment = try #require(menu.items.first { $0.title == "Comment on GitHub…" })
        #expect(NSApp.sendAction(try #require(comment.action), to: comment.target, from: comment))
        #expect(commented)
        canvas.update(
            document, split: false, wraps: false, wordDiffs: false, findRequest: 0,
            reveal: nil, viewport: nil, onNote: { _ in }, onComment: nil)
        #expect(textView(in: canvas) === text)
        #expect(try #require(text.menu(for: event)).items.allSatisfy { $0.title != "Comment on GitHub…" })
    }
}
