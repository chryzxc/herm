import Foundation
import Testing

@testable import Herm

struct SpecMapParserTests {
    private let plan = """
        # Release plan

        Intro text that is not a task.

        ## Phase 1: Foundation

        - [x] P1.1 Parser
        - [~] P1.2 View
        - [ ] P1.3 Wire-up — depends on P1.2 and P1.1
        - [ ] Docs blocked by legal review

        ## Phase 2: Polish

        1. Measure
        2. Tune
           - [x] cache
           - [ ] batch
        3. Ship, requires `Tune`

        ```
        - [ ] not a task
        ## not a lane
        ```
        """

    @Test func lanesUseRepeatedHeadingLevel() {
        let map = SpecMapParser.parse(plan, fallbackTitle: "plan.md")
        #expect(map.title == "Release plan")
        #expect(map.lanes.map(\.title) == ["Phase 1: Foundation", "Phase 2: Polish"])
        #expect(map.lanes.map { $0.nodes.count } == [4, 3])
        #expect(map.lanes[0].doneCount == 1)
    }

    @Test func checklistStatusesComeFromTheDocument() {
        let nodes = SpecMapParser.parse(plan, fallbackTitle: "plan.md").lanes[0].nodes
        #expect(nodes.map(\.status) == [.done, .inProgress, .todo, .blocked])
        #expect(nodes.map(\.label) == ["P1.1", "P1.2", "P1.3", nil])
        #expect(nodes[0].title == "Parser")
    }

    @Test func numberedItemsChainAndNestedChecksFeedProgress() {
        let map = SpecMapParser.parse(plan, fallbackTitle: "plan.md")
        let phase2 = map.lanes[1].nodes
        #expect(phase2[1].subtasksDone == 1 && phase2[1].subtasksTotal == 2)
        #expect(phase2[1].status == nil)
        let sequence = map.edges.filter { $0.kind == .sequence }
        #expect(sequence.map(\.source) == [phase2[0].id, phase2[1].id])
        #expect(sequence.map(\.target) == [phase2[1].id, phase2[2].id])
    }

    @Test func explicitDependenciesResolveByLabelOrTitle() {
        let map = SpecMapParser.parse(plan, fallbackTitle: "plan.md")
        let phase1 = map.lanes[0].nodes
        let phase2 = map.lanes[1].nodes
        let deps = Set(map.edges.filter { $0.kind == .dependency }.map { [$0.source, $0.target] })
        #expect(deps.contains([phase1[1].id, phase1[2].id]))
        #expect(deps.contains([phase1[0].id, phase1[2].id]))
        #expect(deps.contains([phase2[1].id, phase2[2].id]))
        #expect(phase1[3].unresolved == ["legal review"])
        #expect(phase1[2].unresolved.isEmpty)
    }

    @Test func indexAnswersWhatTheLanesSay() {
        let map = SpecMapParser.parse(plan, fallbackTitle: "plan.md")
        let phase1 = map.lanes[0].nodes
        #expect(map.ordered == map.lanes.flatMap(\.allNodes))
        #expect(Set(map.sources(of: phase1[2].id).map(\.id)) == [phase1[0].id, phase1[1].id])
        #expect(map.lane(of: map.lanes[1].nodes[0].id)?.id == map.lanes[1].id)
        #expect(map.node(phase1[1].id) == phase1[1])
        #expect(map.node("missing") == nil)
    }

    @Test func sectionsTakeStatusFromTheirChecklists() {
        let text = """
            ## Backend
            ### Task 1: Schema
            - [x] tables
            - [x] indexes
            ### Task 2: API
            - [x] routes
            - [ ] auth
            ### Task 3: Notes
            Just prose.
            ## Frontend
            ### Screens
            - [ ] list
            """
        let map = SpecMapParser.parse(text, fallbackTitle: "spec.md")
        let backend = map.lanes[0].nodes
        #expect(backend.map(\.label) == ["Task 1", "Task 2", "Task 3"])
        #expect(backend.map(\.title) == ["Schema", "API", "Notes"])
        #expect(backend.map(\.status) == [.done, .inProgress, nil])
        #expect(backend[1].subtasksDone == 1 && backend[1].subtasksTotal == 2)
        #expect(map.lanes[1].nodes.first?.status == .todo)
    }

    @Test func singleLaneFallsBackToTitleOrFilename() {
        let titled = SpecMapParser.parse("# Todo\n- [ ] a\n- [x] b", fallbackTitle: "todo.md")
        #expect(titled.lanes.map(\.title) == ["Todo"])
        #expect(titled.isUseful)
        let bare = SpecMapParser.parse("- [ ] a\n- [x] b", fallbackTitle: "todo.md")
        #expect(bare.lanes.map(\.title) == ["todo.md"])
    }

    @Test func fewerThanTwoTasksIsNotUseful() {
        #expect(!SpecMapParser.parse("# Notes\n\nSome prose.\n- a bullet", fallbackTitle: "n.md").isUseful)
        #expect(!SpecMapParser.parse("- [ ] only one", fallbackTitle: "n.md").isUseful)
    }

    @Test func codeFencesAreIgnored() {
        let map = SpecMapParser.parse(plan, fallbackTitle: "plan.md")
        #expect(!map.lanes.flatMap(\.nodes).contains { $0.title == "not a task" })
        #expect(!map.lanes.contains { $0.title == "not a lane" })
    }

    @Test func nestedItemsBecomeChildLevels() {
        let text = """
            ## Build
            - [ ] API
              - [x] routes
              - [ ] auth
                - [ ] tokens, depends on routes
              - plain note
            ### Task 2: UI
            - [x] list
            #### Detail screen
            - [ ] header
            ## Ship
            - [ ] release, requires API
            """
        let map = SpecMapParser.parse(text, fallbackTitle: "plan.md")
        let build = map.lanes[0]
        #expect(build.nodes.map(\.title) == ["API", "UI"])
        let api = build.nodes[0]
        #expect(build.children(of: api.id).map(\.title) == ["routes", "auth"])
        let auth = build.children(of: api.id)[1]
        #expect(build.children(of: auth.id).map(\.title) == ["tokens, depends on routes"])
        #expect(build.children(of: auth.id)[0].depth == 2)
        #expect(api.subtasksDone == 1 && api.subtasksTotal == 3)
        let ui = build.nodes[1]
        #expect(build.children(of: ui.id).map(\.title) == ["list", "Detail screen"])
        let detail = build.children(of: ui.id)[1]
        #expect(build.children(of: detail.id).map(\.title) == ["header"])
        let routes = build.children(of: api.id)[0]
        let tokens = build.children(of: auth.id)[0]
        let deps = map.edges.filter { $0.kind == .dependency }
        #expect(deps.contains(SpecMapEdge(source: routes.id, target: tokens.id, kind: .dependency)))
        #expect(!deps.contains { $0.target == api.id || $0.target == auth.id })
        #expect(deps.contains(SpecMapEdge(source: api.id, target: map.lanes[1].nodes[0].id, kind: .dependency)))
    }

    @Test func plainBulletPlansFallBackToLooseSteps() {
        let map = SpecMapParser.parse("# Todo\n- write parser\n  - handle tabs\n- ship it", fallbackTitle: "t.md")
        #expect(map.lanes.first?.nodes.map(\.title) == ["write parser", "ship it"])
        #expect(map.lanes[0].children(of: map.lanes[0].nodes[0].id).map(\.title) == ["handle tabs"])
        #expect(map.lanes[0].nodes.allSatisfy { $0.status == nil })
    }

    @Test func checklistsStayStrictBesidePlainBullets() {
        let map = SpecMapParser.parse("- [ ] a\n- [x] b\n- just a note", fallbackTitle: "t.md")
        #expect(map.lanes[0].nodes.map(\.title) == ["a", "b"])
    }

    @Test func headingOnlySpecsBecomeAnOutline() {
        let text = """
            # Design
            ## Goals
            Prose.
            ### Speed
            Prose.
            ## Non-goals
            Prose.
            """
        let map = SpecMapParser.parse(text, fallbackTitle: "d.md")
        #expect(map.lanes.map(\.title) == ["Design"])
        #expect(map.lanes[0].nodes.map(\.title) == ["Goals", "Non-goals"])
        #expect(map.lanes[0].children(of: map.lanes[0].nodes[0].id).map(\.title) == ["Speed"])
    }

    @Test func emojiAndStrikethroughCarryStatus() {
        let text = "- ✅ parser\n- 🚧 view\n- ⛔ docs\n- ☐ tests\n- ~~old idea~~"
        let nodes = SpecMapParser.parse(text, fallbackTitle: "t.md").lanes[0].nodes
        #expect(nodes.map(\.status) == [.done, .inProgress, .blocked, .todo, .done])
        #expect(nodes.map(\.title) == ["parser", "view", "docs", "tests", "old idea"])
    }

    @Test func proseWithoutStructureStaysADocument() {
        #expect(!SpecMapParser.parse("Just a paragraph.\n\nAnother one.", fallbackTitle: "p.md").isUseful)
        #expect(!SpecMapParser.parse("", fallbackTitle: "p.md").isUseful)
        #expect(!SpecMapParser.parse("# Title only", fallbackTitle: "p.md").isUseful)
    }

    @Test func windowsLineEndingsAndTabsParse() {
        let map = SpecMapParser.parse("## A\r\n- [ ] one\r\n\t- [x] sub\r\n## B\r\n- [x] two", fallbackTitle: "w.md")
        #expect(map.lanes.map(\.title) == ["A", "B"])
        #expect(map.lanes[0].nodes[0].subtasksDone == 1)
    }

    @Test func crlfKeepsLineNumbersAndTables() {
        let map = SpecMapParser.parse(
            "## A\r\n- [ ] one\r\n- [ ] two\r\n## B\r\n| a | b |\r\n|---|---|\r\n- [x] three",
            fallbackTitle: "w.md")
        #expect(map.lanes[0].nodes.map(\.line) == [2, 3])
        #expect(map.lanes[1].nodes.map(\.title) == ["three"])
    }

    @Test func sharedTitlesOnlyChangeWhenTheirTextDoes() {
        let old = SpecMapParser.parse("## A\n- [x] Tests\n- [ ] x\n## B\n- [ ] Tests\n- [ ] y", fallbackTitle: "p.md")
        let same = SpecMapParser.parse("## A\n- [x] Tests\n- [ ] x\n## B\n- [ ] Tests\n- [ ] y2", fallbackTitle: "p.md")
        #expect(same.changedTitles(since: old) == ["y2"])
    }

    @Test func selectionFollowsItsStepWhenLinesMove() {
        let old = SpecMapParser.parse("## A\n- [ ] one\n- [ ] two\n## B\n- [ ] three", fallbackTitle: "p.md")
        let new = SpecMapParser.parse("## A\n- [ ] two\n## B\n- [ ] three", fallbackTitle: "p.md")
        let one = old.lanes[0].nodes[0].id
        let two = old.lanes[0].nodes[1].id
        // "two" moved up into "one"'s line: "one"'s id must not now select "two".
        #expect(new.matching(one, from: old) == nil)
        #expect(new.matching(two, from: old) == new.lanes[0].nodes[0].id)
        #expect(new.matching("lane-1", from: old) == "lane-1")
    }

    @Test func sharedLinesStayInTheParentsNotes() {
        let text = """
            ## A
            - [ ] Build
              ```
              make
              ```
              - [ ] Child
                ```
                go
                ```
            - [ ] Ship, requires a schema migration first
            """
        let map = SpecMapParser.parse(text, fallbackTitle: "p.md")
        let lane = map.lanes[0]
        #expect(lane.notes(of: lane.nodes[0]) == "```\nmake\n```")
        // "requires" in prose is not a dependency unless it names a step.
        #expect(lane.nodes[1].unresolved.isEmpty)
    }

    @Test func wrappedItemsJoinAndBoldLeadsNameThem() {
        let text = """
            # Spec
            ## Options considered
            1. **Alternate view in Timeline — recommended.** Reuses the same request selection,
               live projection, details, navigation.
            2. Separate inspector tab. Easier to discover, but duplicates the feed
               and selection.
            """
        let lane = SpecMapParser.parse(text, fallbackTitle: "s.md").lanes[0]
        let options = lane.children(of: lane.nodes[0].id)
        #expect(options.map(\.title) == ["Alternate view in Timeline — recommended", "Separate inspector tab"])
        #expect(options[0].summary == "Reuses the same request selection, live projection, details, navigation.")
        #expect(options[1].summary == "Easier to discover, but duplicates the feed and selection.")
    }

    @Test func longTitlesBreakAtTheirFirstClause() {
        let named = SpecMapParser.name(
            "Keep the tab named Timeline: its saved identifiers stay unchanged across every release")
        #expect(named.title == "Keep the tab named Timeline")
        #expect(named.summary == "its saved identifiers stay unchanged across every release")
        let inline = SpecMapParser.name("**Delegated to** is a directed edge only when the parent exists")
        #expect(inline.title == "Delegated to is a directed edge only when the parent exists")
        #expect(inline.summary == nil)
    }

    @Test func designSpecsKeepEverySection() {
        let text = """
            # Work Map design
            ## Decision and scope
            Add Work Map as an alternate presentation.
            - **Timeline:** what happened, in order.
            ## Options considered
            1. First option
            2. Second option
            ## Non-goals
            Prose only.
            """
        let map = SpecMapParser.parse(text, fallbackTitle: "d.md")
        #expect(map.lanes.map(\.title) == ["Work Map design"])
        let sections = map.lanes[0].nodes
        #expect(sections.map(\.title) == ["Decision and scope", "Options considered", "Non-goals"])
        #expect(map.lanes[0].children(of: sections[1].id).map(\.title) == ["First option", "Second option"])
        #expect(map.lanes[0].children(of: sections[0].id).first?.title == "Timeline")
        #expect(!map.hasStatus)
    }

    @Test func notesLeaveOutWhatChildrenShow() {
        let text = "# S\n## Options\nWhy we compared.\n1. **A.** first\n   wrapped\n2. B\n## Other\nProse."
        let lane = SpecMapParser.parse(text, fallbackTitle: "s.md").lanes[0]
        let options = lane.nodes[0]
        #expect(lane.notes(of: options) == "Why we compared.")
    }

    private let design = """
        # Work Map
        ## Existing implementation
        Verified against main.
        | Source | Reuse |
        | --- | --- |
        | `Sources/A.swift` | Timeline tab |
        | `Sources/B.swift` | Inspector |
        ## Presentation
        Lanes read left to right. Each lane is a phase.
        ```mermaid
        graph TD; A-->B
        ```
        ```
        depends on Ghost
        ```
        ## Open questions
        - Should it **animate**?
        """

    @Test func tableRowsBecomeChildrenAndProseBecomesAPreview() {
        let lane = SpecMapParser.parse(design, fallbackTitle: "d.md").lanes[0]
        let existing = lane.nodes[0]
        let rows = lane.children(of: existing.id)
        #expect(rows.map(\.title) == ["Sources/A.swift", "Sources/B.swift"])
        #expect(rows[0].summary == "Timeline tab")
        #expect(lane.notes(of: existing) == "Verified against main.")
        #expect(existing.preview == "Verified against main.")
        #expect(lane.nodes[1].preview == "Lanes read left to right.")
    }

    @Test func fencedBlocksStayInNotesButNeverResolve() {
        let lane = SpecMapParser.parse(design, fallbackTitle: "d.md").lanes[0]
        let presentation = lane.nodes[1]
        #expect(lane.notes(of: presentation).contains("```mermaid\ngraph TD; A-->B\n```"))
        #expect(presentation.unresolved.isEmpty)
        #expect(SpecMapParser.preview("| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |") == "Table · 2 rows")
        #expect(SpecMapParser.preview("| a | b |\n| --- | --- |\n| 1 | 2 |") == "Table · 1 row")
    }

    @Test func sectionTonesComeFromHeadingWords() {
        #expect(SpecMapSectionTone(title: "Non-goals") == .muted)
        #expect(SpecMapSectionTone(title: "Open questions") == .attention)
        #expect(SpecMapSectionTone(title: "Decision and scope") == .decision)
        #expect(SpecMapSectionTone(title: "Presentation") == nil)
    }

    @Test func outlineKeepsStatusesAndNesting() {
        let map = SpecMapParser.parse("# T\n## A\n- [x] one\n  - [ ] sub\n## B\n- [~] two", fallbackTitle: "t.md")
        #expect(map.outline == "# T\n\n## A\n- [x] one\n  - [ ] sub\n\n## B\n- [~] two")
    }

    @Test func changesAreTrackedByTitle() {
        let old = SpecMapParser.parse("## A\n- [ ] one\n- [ ] two\n## B\n- [ ] three", fallbackTitle: "t.md")
        let new = SpecMapParser.parse(
            "## A\n- [ ] zero\n- [ ] one\n- [x] two\n## B\n- [ ] three", fallbackTitle: "t.md")
        #expect(new.changedTitles(since: old) == ["zero", "two"])
    }

    @Test func renderedPositionsAndQuotesFindTheirNode() {
        let map = SpecMapParser.parse(design, fallbackTitle: "d.md")
        let rendered = "Work Map\nExisting implementation\nVerified against main.\nPresentation\nLanes read left"
        let offset = (rendered as NSString).range(of: "Lanes").location
        #expect(map.node(atRenderedOffset: offset, in: rendered)?.title == "Presentation")
        #expect(map.node(atRenderedOffset: 0, in: rendered) == nil)
        #expect(map.node(quoting: "Timeline   tab")?.title == "Sources/A.swift")
    }

    @Test func liveTasksMatchOnlyUnambiguousTitles() {
        let map = SpecMapParser.parse(
            "## A\n- [ ] Build parser\n- [ ] Ship view\n- [x] Write docs", fallbackTitle: "t.md")
        let live = map.liveStatuses([
            ("Build parser for specs", "in_progress"), ("Write docs", "completed"), ("Ship", "completed"),
        ])
        let nodes = map.lanes[0].nodes
        #expect(live == [nodes[0].id: .working])
    }

    @Test func filePathsSkipURLs() {
        let text = "Edit `Sources/Herm/A.swift` and docs/b.md, see https://x.com/c.html and Sources/Herm/A.swift."
        #expect(SpecMapParser.filePaths(in: text) == ["Sources/Herm/A.swift", "docs/b.md"])
    }

    @Test func hardWrappedProseJoinsButBlocksKeepTheirLines() {
        let notes = "Keep the tab\nunchanged. Add\n\n- item one\n  continues\n| a | b |\n| - | - |\n```\nx\ny\n```"
        #expect(
            SpecMapParser.unwrapped(notes)
                == "Keep the tab unchanged. Add\n\n- item one continues\n| a | b |\n| - | - |\n```\nx\ny\n```")
        #expect(SpecMapView.displayTitle("Sources/Herm/App/Thing.swift") == "Thing.swift")
        #expect(SpecMapView.displayTitle("Alternate view in Timeline") == "Alternate view in Timeline")
    }

    @Test func nextUpSkipsDoneAndWaitingSteps() {
        let map = SpecMapParser.parse(
            "# T\n## A\n- [x] one\n- [ ] two, depends on three\n- [ ] three\n## B\n- [ ] four", fallbackTitle: "t")
        #expect(map.nextUp?.title == "three")
        #expect(map.progress?.done == 1)
        #expect(map.progress?.total == 4)
        #expect(SpecMapParser.parse("# T\n## A\n- one\n- two\n## B\n- three", fallbackTitle: "t").nextUp == nil)
    }
}
