import SwiftUI

struct ProjectActionsMenu: View {
    let path: String
    var model: DockModel?
    var configurationPath: String?
    var onlySetup = false
    @ObservedObject private var preferences = ProjectPreferences.shared
    @State private var presentation: Presentation?
    private enum Presentation: Identifiable {
        case editor(path: String)
        case comparison(path: String)
        case terminal(action: ProjectAction, directory: String)
        var id: String {
            switch self {
            case .editor(let path): "editor:" + path
            case .comparison(let path): "comparison:" + path
            case .terminal(let action, let directory): "terminal:" + action.id.uuidString + ":" + directory
            }
        }
    }
    @State private var error: String?
    var body: some View {
        HStack {
            Menu(onlySetup ? "Setup" : "Actions") {
                ForEach(preferences.actions(configurationPath ?? path).filter { !onlySetup || $0.isSetup == true }) {
                    action in Button("Run \(action.name)") { run(action) }
                }
                Button("Edit project actions…") { presentation = .editor(path: configurationPath ?? path) }
                if let model, !onlySetup {
                    if GatewayConnectionStore.shared.launchSettings.mode == .local, model.runtimeModelOptions.count >= 2
                    {
                        Button("Compare approaches…") { presentation = .comparison(path: path) }
                    }
                    Menu("Model for new sessions") {
                        Button("Use Hermes default") { preferences.setModel(nil, path: path) }
                        ForEach(model.runtimeModelOptions, id: \.id) { option in
                            Button(option.model) { preferences.setModel(option.id, path: path) }
                        }
                    }
                }
            }.menuStyle(.borderlessButton).buttonStyle(.dockCompact)
            if let error { Text(error).font(DockTypography.body).foregroundStyle(Color.dockWarning).lineLimit(2) }
        }
        .sheet(item: $presentation) { target in
            switch target {
            case .comparison(let capturedPath):
                if let model { ModelComparisonView(path: capturedPath, model: model) }
            case .editor(let capturedPath):
                ProjectActionsEditor(path: capturedPath, preferences: preferences)
            case .terminal(let action, let directory):
                VStack(spacing: 0) {
                    HStack {
                        Text(action.name).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Close") { presentation = nil }.buttonStyle(.dockCompact)
                    }.padding(12)
                    SessionTerminalView(
                        projectPath: directory, recipes: [], repositoryID: nil,
                        repositoryFingerprint: nil, workspaceKey: action.id.uuidString)
                }.frame(minWidth: 650, minHeight: 440).background(Color.dockCanvas)
            }
        }
    }

    private func run(_ action: ProjectAction) {
        do {
            let directory = try action.workingDirectory(project: path)
            let store = TerminalWorkspaceStore.shared.workspace(key: action.id.uuidString + ":" + directory)
            guard !store.selected.hasForegroundJob, store.selected.projectCommand?.isRunning != true else {
                throw QuickDraftError.message("This action is still running in its terminal.")
            }
            if store.selected.workingDirectory == nil { store.selected.start(directory: directory) }
            guard store.selected.runProjectCommand(action.command) else {
                throw QuickDraftError.message("The terminal could not start this action.")
            }
            presentation = .terminal(action: action, directory: directory)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
