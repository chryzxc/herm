import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct RichExpansionTests {
    private func surface(_ source: String) throws -> RichSurface {
        try JSONDecoder().decode(RichSurface.self, from: Data(source.utf8))
    }
    private func reference(row: Int = 1, uid: String? = nil, profile: String? = "p", digest: String = "digest")
        -> RichArtifactReference
    {
        RichArtifactReference(
            profileID: profile, sessionID: "session", rowID: row, messageUID: uid, surfaceID: "example",
            sourceDigest: digest)
    }

    @Test func everyRegisteredExampleDecodesValidatesAndProjects() throws {
        #expect(Set(RichFeatureRegistry.local.map(\.id)).count == RichFeatureRegistry.local.count)
        for feature in RichFeatureRegistry.local {
            let source = RichFeatureRegistry.exampleSurface(feature)
            let value = try surface(source)
            #expect(value.validate(), "Invalid registered example: \(feature.id)")
            #expect(!value.plainText.isEmpty)
            #expect(try surface(String(decoding: JSONEncoder().encode(value), as: UTF8.self)) == value)
            let document = RichDocument("```herm-ui\n" + source + "\n```")
            #expect(document.segments == [.surface(value, source: source)])
        }
    }

    @Test func registryTracksAvailableFeaturesOnTheNextPromptWithoutDuplicatingContext() {
        let local = RichGenerationContext()
        let connected = RichGenerationContext(
            profileID: "p", sessionID: "session", availableRecords: [.trace],
            recordReferences: [RichRecordTarget(kind: .trace, id: "session")])
        let first = GenerativeUIIntegration.preparePrompt("Explain this", enabled: true, context: local)
        #expect(!first.contains("record.trace (v2)"))
        let next = GenerativeUIIntegration.preparePrompt(first, enabled: true, context: connected)
        #expect(next.contains("record.trace (v2)"))
        #expect(!next.contains("record.pullRequest (v2)"))
        #expect(next.components(separatedBy: "[Herm rendering context v1]").count == 2)
        #expect(GenerativeUIIntegration.displayUserText(next) == "Explain this")
        #expect(
            GenerativeUIIntegration.preparePrompt("Explain this", enabled: false, context: connected) == "Explain this")
        #expect(
            RichFeatureRegistry.descriptors(in: connected).map(\.id)
                == RichFeatureRegistry.descriptors(in: connected).map(\.id).sorted())
    }

    @Test func typedDatasetsSortNumericallyAndRetainSourceOrder() {
        let data = RichDataset(
            id: "sales", columns: [.init(id: "value", title: "Value", type: .number)],
            rows: [.init(id: "a", values: ["12"]), .init(id: "b", values: ["2"]), .init(id: "c", values: ["12"])])
        #expect(data.validate())
        #expect(data.displayedRows(query: "", column: nil, descending: false).map(\.id) == ["a", "b", "c"])
        #expect(data.displayedRows(query: "", column: 0, descending: false).map(\.id) == ["b", "a", "c"])
        #expect(data.displayedRows(query: "12", column: 0, descending: true).map(\.id) == ["a", "c"])
        #expect(!RichDataset(id: "bad", columns: data.columns, rows: [.init(id: "x", values: ["NaN"])]).validate())
    }

    @Test func selectionIdentitiesSeparateDatasetsBlocksAndEdges() throws {
        let suite = "RichSelection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = RichArtifactPresentationState(key: "tool", store: WorkspacePresentationStore(defaults: defaults))
        let dataset = RichDataset(
            id: "shared", columns: [.init(id: "value", title: "Value", type: .number)],
            rows: [.init(id: "row", values: ["12"])])
        let graph = RichGraph(
            nodes: [.init(id: "edge:0", title: "First"), .init(id: "end", title: "Second")],
            edges: [.init(source: "edge:0", target: "end", label: "supplied link")])
        let surface = RichSurface(
            version: 2, id: "tool", title: "Tool", fallback: "Supplied values", kind: .native,
            blocks: [RichBlock(type: .graph, id: "shared", payload: .graph(graph))], datasets: [dataset])
        state.snapshot.selected[RichSelectionIdentity.dataset("shared")] = "row"
        state.snapshot.selected[RichSelectionIdentity.block("shared")] = "edge:0"
        #expect(state.selectionText(in: surface).contains("Value: 12"))
        #expect(state.selectionText(in: surface).contains("First"))
        #expect(!state.selectionText(in: surface).contains("supplied link"))
        state.snapshot.selected[RichSelectionIdentity.edge("shared")] = "0"
        #expect(state.selectionText(in: surface).contains("First → Second: supplied link"))
        #expect(RichSelectionIdentity.edge("shared") != RichSelectionIdentity.block("shared:edge"))
    }

    @Test func typedReferencesRejectMissingDatasetsCyclesAndUnknownParents() throws {
        let descriptor = try #require(RichFeatureRegistry.local.first { $0.id == "section" })
        let source = RichFeatureRegistry.exampleSurface(descriptor)
        #expect(try surface(source.replacingOccurrences(of: "\"totals\"]", with: "\"missing\"]")).validate() == false)
        let tree = RichTree(items: [.init(id: "a", title: "A", parent: "b"), .init(id: "b", title: "B", parent: "a")])
        #expect(!tree.validate())
        #expect(!RichTree(items: [.init(id: "a", title: "A", parent: "missing")]).validate())
        let chart = RichBlockPayload.chart(.init(dataset: "missing", label: "month", series: ["sales"], style: "bar"))
        let empty = RichSurface(version: 2, id: "x", title: "X", fallback: "X", kind: .native, blocks: [])
        #expect(!chart.validate(in: empty))
        #expect(
            !RichBlockPayload.graph(
                .init(nodes: [.init(id: "a", title: "A")], edges: [.init(source: "a", target: "missing")])
            ).validate())
    }

    @Test func nativeStateRestoresWithoutSavingCanonicalSurfaceData() throws {
        let suite = "RichStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = WorkspacePresentationStore(defaults: defaults)
        let first = RichArtifactStateStore(store: persistence)
        let key = reference().presentationKey
        let state = first.state(for: key)
        state.snapshot.selected["dataset"] = "row-a"
        state.snapshot.checked.insert("packing:coat")
        state.snapshot.values["answer"] = ["Three"]
        let restored = RichArtifactStateStore(store: persistence).state(for: key)
        #expect(restored.snapshot == state.snapshot)
        #expect(
            RichArtifactStateStore(store: persistence).state(for: reference(digest: "changed").presentationKey).snapshot
                == .init())
        restored.reset()
        #expect(restored.snapshot == .init())
        let draft = first.form(for: key + ":form")
        draft.values = ["answer": ["Four"]]
        #expect(RichArtifactStateStore(store: persistence).form(for: key + ":form").values == draft.values)
    }

    @Test func stateMigrationRequiresTheSameReplyAndSource() {
        let message = UUID()
        let liveReference = RichArtifactReference(
            profileID: "p", sessionID: "session", rowID: nil, messageUID: nil,
            surfaceID: "example", sourceDigest: "digest")
        let live = RichArtifactPresentationIdentity(key: "live", reference: liveReference, messageID: message)
        let stored = RichArtifactPresentationIdentity(key: "stored", reference: reference(), messageID: message)
        #expect(live.canMigrate(to: stored))
        #expect(!live.canMigrate(to: .init(key: "other", reference: reference(), messageID: UUID())))
        #expect(!live.canMigrate(to: .init(key: "edited", reference: reference(digest: "changed"), messageID: message)))
        #expect(!live.canMigrate(to: .init(key: "other", reference: reference(profile: "other"), messageID: message)))
    }

    @Test func bookmarksReconcileNewUIDsAndNeverCrossProfiles() throws {
        let suite = "RichBookmarks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = RichArtifactStateStore(store: WorkspacePresentationStore(defaults: defaults))
        let old = reference()
        let current = reference(uid: "stable-uid")
        state.toggle(.init(reference: old, title: "Tool", sessionTitle: "Session"))
        state.reconcile([current])
        #expect(state.bookmarks.map(\.reference) == [current])
        #expect(old.presentationKey == current.presentationKey)
        #expect(!current.matches(reference(uid: "stable-uid", profile: "other")))
        #expect(reference(profile: nil).id != reference(profile: "default").id)
        state.toggle(.init(reference: old, title: "Tool", sessionTitle: "Session"))
        #expect(state.bookmarks.isEmpty)
    }

    @Test func artifactIndexExtractsGeneratedSurfacesWithoutLeakingEmbeddedURLs() throws {
        let session = HermesSession(
            id: "session", profileID: "p", title: "Session", preview: "", startedAt: nil, messageCount: 1,
            source: "test")
        let html =
            #"{"version":1,"id":"tool","title":"Tool","fallback":"Offline result","kind":"html","html":"<a href='https://example.com/embedded'>Embedded</a>"}"#
        let records = ArtifactService.extract(
            session: session,
            messages: [
                [
                    "role": "assistant", "id": 42, "message_uid": "uid",
                    "text": "```herm-ui\n" + html + "\n```\nOutside: https://example.org/reference",
                ]
            ])
        #expect(records.count == 2)
        let generated = try #require(records.first { $0.kind == .interactive }?.generated)
        #expect(generated.source == html)
        #expect(generated.reference.rowID == 42)
        #expect(generated.reference.messageUID == "uid")
        #expect(!records.contains { $0.value.contains("embedded") })
        #expect(try RichArtifactExport.document(source: html) == Data(html.utf8))
    }

    @Test func revisionLineageRequiresAnEarlierSourceInTheSameProfileAndSession() throws {
        let descriptor = try #require(RichFeatureRegistry.local.first { $0.id == "metrics" })
        let source = RichFeatureRegistry.exampleSurface(descriptor)
        let original = try surface(source)
        let parent = reference(row: 1)
        var revised = original
        revised.revisionOf = parent
        let older = ArtifactRecord(
            value: "", sessionID: "session", sessionTitle: "Session", timestamp: Date(timeIntervalSince1970: 1),
            profileID: "p",
            generated: .init(reference: parent, surface: original, source: source))
        let newer = ArtifactRecord(
            value: "", sessionID: "session", sessionTitle: "Session", timestamp: Date(timeIntervalSince1970: 2),
            profileID: "p",
            generated: .init(reference: reference(row: 2), surface: revised, source: source))
        #expect(RichArtifactIndex.latest([older, newer]).map(\.id) == [newer.id])
        #expect(RichArtifactIndex.versions(of: newer, in: [older, newer]).map(\.id) == [newer.id, older.id])
        var other = newer
        other.profileID = "other"
        #expect(RichArtifactIndex.latest([older, other]).count == 2)
    }

    @Test func allRecipeFamiliesHaveValidFixtures() throws {
        #expect(RichGenerationRecipes.all.count == 20)
        for recipe in RichGenerationRecipes.all {
            #expect(!recipe.prompt.isEmpty)
            #expect(try surface(RichGenerationRecipes.fixture(for: recipe)).validate())
        }
    }
}

@MainActor
struct RichLifecycleTests {
    @Test func rendererBuildsEveryRegisteredNativeExample() throws {
        for feature in RichFeatureRegistry.local {
            let source = RichFeatureRegistry.exampleSurface(feature)
            let document = RichDocument("```herm-ui\n" + source + "\n```")
            let host = NSHostingView(rootView: RichDocumentView(document: document).frame(width: 640))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height > 0, "Renderer missing for \(feature.id)")
        }
    }

    @Test func htmlTransfersOneWebViewAndRestoresItsOriginalContainer() async throws {
        let owner = GeneratedHTMLCoordinator()
        owner.open("artifact")
        let state = owner.state(for: "artifact")
        let coordinator = owner.coordinator(html: "<p>Offline tool</p>", identity: "artifact:0", state: state)
        let web = coordinator.makeWebView()
        coordinator.retainedWeb = web
        coordinator.retainsHost = true
        let inline = GeneratedHTMLContainer(frame: NSRect(x: 0, y: 0, width: 320, height: 420))
        let expanded = GeneratedHTMLContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        expanded.presentationPriority = 1
        coordinator.mount(inline)
        #expect(web.superview === inline)
        let reused = owner.coordinator(html: "<p>Offline tool</p>", identity: "artifact:0", state: state)
        #expect(reused === coordinator)
        coordinator.mount(expanded)
        #expect(web.superview === expanded)
        let remountedInline = GeneratedHTMLContainer(frame: inline.frame)
        coordinator.mount(remountedInline)
        #expect(web.superview === expanded)
        coordinator.unmount(remountedInline)
        coordinator.unmount(expanded)
        #expect(web.superview === inline)
        #expect(!coordinator.cancelled)
        owner.rekey(from: "artifact", to: "stored-artifact")
        #expect(owner.activeKey == "stored-artifact")
        #expect(
            owner.coordinator(html: "<p>Offline tool</p>", identity: "stored-artifact:0", state: state) === coordinator)
        owner.close()
        #expect(web.superview == nil)
        #expect(coordinator.cancelled)
        #expect(coordinator.retainedWeb == nil)
    }

    @Test func hostRegistrationAdvertisesOnlyKnownRecordsAndRejectsOtherDestinations() {
        var available = ["pr-1"]
        let router = RichHostActionRouter(
            scope: .init(profileID: "p", resourceID: "s"),
            features: [
                .init(kind: .pullRequest, ids: { available }) { id in
                    guard available.contains(id) else { return nil }
                    return .init(title: "PR", detail: "Observed record", open: {})
                }
            ])
        let provider = router.contextProvider()
        let destination = QuickDestination(profileID: "p", sessionID: "s", title: "S")
        #expect(provider(destination).availableRecords == [.pullRequest])
        #expect(router.resolve(.init(kind: .pullRequest, id: "pr-1")) != nil)
        #expect(router.resolve(.init(kind: .pullRequest, id: "invented")) == nil)
        #expect(provider(.init(profileID: "other", sessionID: "s", title: "S")).availableRecords.isEmpty)
        available = []
        #expect(provider(destination).availableRecords.isEmpty)
        #expect(router.resolve(.init(kind: .pullRequest, id: "pr-1")) == nil)
    }

    @Test func stateMigrationKeepsPendingInputsAndReceiptState() throws {
        let suite = "RichMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RichArtifactStateStore(store: WorkspacePresentationStore(defaults: defaults))
        store.state(for: "live").snapshot.checked.insert("coat")
        let draft = store.form(for: "live:form")
        draft.values = ["answer": ["Yes"]]
        draft.sent = true
        store.migrate(from: "live", to: "stored")
        #expect(store.state(for: "stored").snapshot.checked == ["coat"])
        #expect(store.form(for: "stored:form") === draft)
        #expect(store.form(for: "stored:form").sent)
        #expect(store.form(for: "stored:form").values == ["answer": ["Yes"]])
        let oldJSON = Data(
            #"{"values":{},"selected":{},"queries":{},"sortColumns":{},"descending":[],"checked":[]}"#.utf8)
        #expect(try JSONDecoder().decode(RichArtifactPresentationState.Snapshot.self, from: oldJSON) == .init())
    }

    @Test func graphPositionsAreStableAndDateSortingUsesActualInstants() {
        let positions = RichGraphLayout.positions(["a", "b", "c", "d"])
        #expect(positions == RichGraphLayout.positions(["a", "b", "c", "d"]))
        #expect(Set(positions.values.map { "\($0.x),\($0.y)" }).count == 4)
        let data = RichDataset(
            id: "dates", columns: [.init(id: "date", title: "Date", type: .date)],
            rows: [
                .init(id: "later", values: ["2026-10-24T10:00:00Z"]),
                .init(id: "earlier", values: ["2026-10-24T11:00:00+02:00"]),
                .init(id: "day", values: ["2026-10-24"]),
            ])
        #expect(data.validate())
        #expect(data.displayedRows(query: "", column: 0, descending: false).map(\.id) == ["day", "earlier", "later"])
    }

    @Test func sharedArtifactIndexCoalescesReadsAndInvalidatesChangedSessions() async {
        let owner = NSObject()
        let ownerID = ObjectIdentifier(owner)
        let index = ArtifactIndexStore()
        let session = HermesSession(
            id: "s", title: "S", preview: "", startedAt: Date(timeIntervalSince1970: 100), messageCount: 1,
            source: "test")
        var reads = 0
        let work: @MainActor @Sendable () async -> ArtifactIndexLoader.SessionResult = {
            reads += 1
            try? await Task.sleep(for: .milliseconds(30))
            return .init(sessionID: "s", profileID: nil, records: [], error: nil)
        }
        async let first = index.load(owner: ownerID, session: session, force: false, work: work)
        async let second = index.load(owner: ownerID, session: session, force: false, work: work)
        _ = await (first, second)
        #expect(reads == 1)
        _ = await index.load(owner: ownerID, session: session, force: false, work: work)
        #expect(reads == 1)
        _ = await index.load(owner: ownerID, session: session, force: true, work: work)
        #expect(reads == 2)
    }

    @Test func revisionComparisonReusesTheSharedDiffGrammar() {
        let old = "January: 12\nFebruary: 18"
        let new = "January: 12\nFebruary: 24"
        let comparison = ResultTextComparison.make(previous: old, current: new)
        let patch = RichRevisionComparisonView.patch(comparison, previous: old, current: new)
        let document = DiffDocument(path: "artifact.txt", patch: patch)
        #expect(document.supportsSplitView)
        #expect(!document.isTruncated)
        #expect(document.lines.contains { DiffDocument.source($0) == "February: 18" })
        #expect(document.lines.contains { DiffDocument.source($0) == "February: 24" })
    }

    @Test func captureExpandedSurfaceLayoutMatrix() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_UI_MATRIX_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousTheme = DockThemeRuntime.current
        let previousRevision = DockThemeRuntime.revision
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer {
            DockThemeRuntime.current = previousTheme
            DockThemeRuntime.revision = previousRevision
            application.appearance = previousAppearance
        }
        let descriptor = try #require(RichFeatureRegistry.local.first { $0.id == "dataset.chart" })
        var surface = try JSONDecoder().decode(
            RichSurface.self, from: Data(RichFeatureRegistry.exampleSurface(descriptor).utf8))
        let dataset = try #require(surface.datasets?.first)
        surface.blocks?.insert(RichBlock(type: .table, id: "table", payload: .table(.init(dataset: dataset.id))), at: 0)
        surface.metadata = .init(assumptions: "Illustrative supplied data", fictional: true)
        #expect(surface.validate())
        let source = String(decoding: try JSONEncoder().encode(surface), as: UTF8.self)
        let document = RichDocument("```herm-ui\n" + source + "\n```")
        for theme: DockThemeID in [.warmLight, .slate, .glass, .mono] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            let appearance = NSAppearance(named: theme == .warmLight ? .aqua : .darkAqua)
            application.appearance = appearance
            for width: CGFloat in [320, 640, 1000] {
                let host = NSHostingView(rootView: RichDocumentView(document: document).padding(16).frame(width: width))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = appearance
                window.contentView = host
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: root.appendingPathComponent("\(theme.rawValue)-\(Int(width)).png"))
                window.orderOut(nil)
            }
        }
    }
}
