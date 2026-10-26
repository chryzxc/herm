import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

private actor ProjectsTransport: GitHubIssueTransport {
    var writes: [String] = []
    var inputs: [[String: String]] = []
    var missingScope = false
    func setMissingScope(_ value: Bool) { missingScope = value }
    let editable: Bool
    let stale: Bool
    let denyWrites: Bool
    init(editable: Bool = true, stale: Bool = false, denyWrites: Bool = false) {
        self.editable = editable
        self.stale = stale
        self.denyWrites = denyWrites
    }
    func count() -> Int { writes.count }
    func mutationInputs() -> [[String: String]] { inputs }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if missingScope {
            return (
                try JSONSerialization.data(withJSONObject: [
                    "errors": [["type": "INSUFFICIENT_SCOPES", "message": "private provider detail"]]
                ]),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let query = body["query"] as! String
        let variables = body["variables"] as? [String: Any] ?? [:]
        let project: [String: Any] = [
            "id": "project", "title": "Release", "viewerCanUpdate": editable, "closed": false,
            "fields": ["nodes": [["id": "status", "name": "Status", "options": [["id": "done", "name": "Done"]]]]],
        ]
        var data: [String: Any]
        if query.hasPrefix("mutation") {
            if denyWrites { throw GitHubRequestError.forbidden }
            writes.append(query)
            inputs.append(variables.compactMapValues { $0 as? String })
            if query.contains("createProjectV2") {
                data = ["createProjectV2": ["projectV2": project]]
            } else if query.contains("addProjectV2DraftIssue") {
                data = ["addProjectV2DraftIssue": ["projectItem": ["id": "new"]]]
            } else {
                data = ["updateProjectV2ItemFieldValue": ["projectV2Item": ["id": "item"]]]
            }
        } else if query.contains("items(first:") {
            var node = project
            node["items"] = [
                "nodes": [
                    [
                        "id": "item", "isArchived": false,
                        "content": ["__typename": "DraftIssue", "title": "Task", "body": "Notes"],
                        "fieldValueByName": stale ? ["optionId": "done"] : [:],
                    ]
                ], "pageInfo": ["hasNextPage": false],
            ]
            data = ["node": node]
        } else if query.contains("projectsV2") {
            let second = variables["after"] as? String == "next"
            var row = project
            row["id"] = second ? "second" : "first"
            data = [
                query.contains("repositoryOwner") ? "repositoryOwner" : "viewer": [
                    "projectsV2": [
                        "nodes": [row], "pageInfo": ["hasNextPage": !second, "endCursor": "next"],
                    ]
                ]
            ]
        } else {
            data = ["viewer": ["id": "viewer"]]
        }
        return (
            try JSONSerialization.data(withJSONObject: ["data": data]),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@MainActor
struct GitHubProjectsTests {
    @Test func paginatesProjectsAndLoadsDrafts() async throws {
        let service = GitHubProjectsService(client: GitHubClient(transport: ProjectsTransport()))
        let projects = try await service.projects(owner: "")
        #expect(projects.map(\.id) == ["first", "second"])
        let organization = try await service.projects(owner: "organization")
        #expect(organization.count == 2)
        let board = try await service.board("project")
        #expect(board.items.first?.title == "Task")
        #expect(board.items.first?.reference == nil)
        #expect(board.project.statusOptions.first?.id == "done")
    }

    @Test func parsesIssueAndRestrictedItemsWithoutInventingReferences() throws {
        let item = try GitHubProjectItem.parse([
            "id": "item",
            "content": [
                "__typename": "Issue", "title": "Fix", "number": 7, "repository": ["nameWithOwner": "owner/repo"],
            ], "fieldValueByName": ["optionId": "done"],
        ])
        #expect(item.reference?.number == 7)
        #expect(item.reference?.kind == .issue)
        #expect(item.statusID == "done")
        let restricted = try GitHubProjectItem.parse(["id": "restricted"])
        #expect(restricted.title == "Restricted item")
        #expect(restricted.reference == nil)
        #expect(throws: GitHubRequestError.self) { try GitHubProjectItem.parse([:]) }
    }

    @Test func rejectsBrokenPagination() throws {
        #expect(throws: GitHubRequestError.self) {
            try GitHubProjectsService.nextCursor(
                ["pageInfo": ["hasNextPage": true, "endCursor": "same"]], previous: "same")
        }
        #expect(throws: GitHubRequestError.self) { try GitHubProjectsService.nextCursor([:], previous: nil) }
    }

    @Test func deniedAndStaleBoardsNeverWrite() async throws {
        for transport in [ProjectsTransport(editable: false), ProjectsTransport(stale: true)] {
            let service = GitHubProjectsService(client: GitHubClient(transport: transport))
            let item = GitHubProjectItem(id: "item", title: "Task", body: "", reference: nil, archived: false)
            await #expect(throws: GitHubRequestError.self) {
                try await service.setStatus(projectID: "project", item: item, statusID: "done")
            }
            #expect(await transport.count() == 0)
        }
    }

    @Test func writesConfirmedStatusAndDraftAndCreatesPersonalProject() async throws {
        let transport = ProjectsTransport()
        let service = GitHubProjectsService(client: GitHubClient(transport: transport))
        let item = GitHubProjectItem(id: "item", title: "Task", body: "", reference: nil, archived: false)
        try await service.setStatus(projectID: "project", item: item, statusID: "done")
        try await service.addDraft(projectID: "project", title: "A task")
        let project = try await service.createProject(title: "Release")
        #expect(project.id == "project")
        #expect(await transport.count() == 3)
        let inputs = await transport.mutationInputs()
        #expect(inputs[0]["project"] == "project")
        #expect(inputs[0]["item"] == "item")
        #expect(inputs[0]["status"] == "done")
        #expect(inputs[1]["title"] == "A task")
        #expect(inputs[2]["owner"] == "viewer")
        await #expect(throws: GitHubRequestError.self) { try await service.addDraft(projectID: "project", title: " ") }
        #expect(await transport.count() == 3)
    }

    @Test func unknownStatusNeverWrites() async throws {
        let transport = ProjectsTransport()
        let service = GitHubProjectsService(client: GitHubClient(transport: transport))
        let item = GitHubProjectItem(id: "item", title: "Task", body: "", reference: nil, archived: false)
        await #expect(throws: GitHubRequestError.self) {
            try await service.setStatus(projectID: "project", item: item, statusID: "missing")
        }
        #expect(await transport.count() == 0)
    }

    @Test func failedSaveRetainsDraftAndBoard() async throws {
        let transport = ProjectsTransport(denyWrites: true)
        let model = GitHubProjectsModel(client: GitHubClient(transport: transport))
        let projects = try await model.service.projects(owner: "")
        await model.open(projects[0])
        model.draftTitle = "Keep this draft"
        await model.save()
        #expect(model.draftTitle == "Keep this draft")
        #expect(model.board?.items.first?.title == "Task")
        #expect(model.error != nil)
        #expect(!model.saving)
        #expect(!model.loading)
        await model.refresh()
        #expect(model.error == nil)
        #expect(model.draftTitle == "Keep this draft")
    }

    @Test func missingScopesShowsRecoveryAndRetryRetainsPriorResults() async throws {
        let transport = ProjectsTransport()
        let model = GitHubProjectsModel(client: GitHubClient(transport: transport))
        await model.browse()
        #expect(model.projects.count == 2)
        await transport.setMissingScope(true)
        await model.refresh()
        #expect(model.needsProjectAccess)
        #expect(model.projects.count == 2)
        #expect(model.error?.contains("private provider detail") == false)
        await transport.setMissingScope(false)
        await model.refresh()
        #expect(!model.needsProjectAccess)
        #expect(model.error == nil)
        model.owner = "another-owner"
        await transport.setMissingScope(true)
        await model.browse()
        #expect(model.projects.isEmpty)
    }

    @Test func navigationRemembersProjects() {
        let state = MissionControlNavigationState()
        state.selectGitHubProjects()
        #expect(state.selectedGitHubSection == .projects)
        state.selectIssues()
        #expect(state.selectedGitHubSection == .issues)
    }
    @Test func renderProjectBoard() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GITHUB_PROJECTS_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let transport = ProjectsTransport()
        let model = GitHubProjectsModel(client: GitHubClient(transport: transport))
        let projects = try await model.service.projects(owner: "")
        let savedTheme = DockThemeRuntime.current
        defer { DockThemeRuntime.current = savedTheme }
        for mode in ["index", "board", "access"] {
            let showsBoard = mode == "board"
            await transport.setMissingScope(mode == "access")
            if showsBoard { await model.open(projects[0]) } else { await model.browse() }
            for (theme, dark): (DockThemeID, Bool) in [
                (.clean, false), (.clean, true), (.glass, true), (.mono, true), (.storm, true),
            ] {
                DockThemeRuntime.current = theme
                DockThemeRuntime.revision &+= 1
                for width: CGFloat in [440, 1100] {
                    let root = GitHubProjectsView(model: model)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .frame(width: width, height: 720).dockThemedRoot()
                    let host = NSHostingView(rootView: root)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 720)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.orderFrontRegardless()
                    for _ in 0..<3 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(80))
                    }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent(
                            "projects-\(mode)-\(Int(width))-\(theme.rawValue)-\(dark).png"))
                    window.orderOut(nil)
                }
            }
        }
    }

}
