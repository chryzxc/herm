import SwiftUI

struct ModelComparisonView: View {
    let path: String
    @ObservedObject var model: DockModel
    @StateObject private var coordinator = ModelComparisonCoordinator()
    @State private var selected = Set<String>()
    @State private var prompt = ""
    @State private var ownerIdentity: String?
    private var ownerChanged: Bool {
        ownerIdentity.map { $0 != WorkspaceIdentity.session(model) } ?? false
    }
    private var selectedAvailableCount: Int { model.runtimeModelOptions.filter { selected.contains($0.id) }.count }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatContextRouter) private var contextRouter
    var body: some View {
        DockModal(
            title: "Compare approaches",
            subtitle: "Choose two or three models. Each runs in a separate local worktree and Hermes session.",
            width: nil
        ) {
            Text(path).font(DockTypography.metadata).foregroundStyle(Color.dockSecondaryText).textSelection(.enabled)
            if coordinator.runs.isEmpty {
                TextField("Task", text: $prompt, axis: .vertical).textFieldStyle(.dockGlass).lineLimit(3...8)
                ScrollView {
                    VStack(alignment: .leading, spacing: DockSpacing.control) {
                        if model.runtimeModelOptions.count < 2 {
                            Text("Two available models are required. Connect to Hermes and refresh the model list.")
                                .font(DockTypography.body).foregroundStyle(Color.dockSecondaryText)
                        }
                        ForEach(model.runtimeModelOptions, id: \.id) { option in
                            Toggle(
                                option.model,
                                isOn: Binding(
                                    get: { selected.contains(option.id) },
                                    set: { value in
                                        if value { selected.insert(option.id) } else { selected.remove(option.id) }
                                    })
                            ).toggleStyle(.checkbox).disabled(selected.count >= 3 && !selected.contains(option.id))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollView {
                    ForEach(coordinator.runs) { run in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(run.option.model).font(.system(size: 12, weight: .semibold))
                            if let error = run.error {
                                Text(error).font(DockTypography.body).foregroundStyle(Color.dockWarning)
                            }
                            if let session = run.session {
                                HStack {
                                    Button("Open conversation") {
                                        model.resumeSession(session)
                                        contextRouter?.onOpened(session.id)
                                        dismiss()
                                    }.buttonStyle(.dockCompact)
                                    if let directory = run.directory {
                                        Button("Review changes") {
                                            reviewSession = session
                                            reviewPath = directory
                                        }.buttonStyle(.dockCompact)
                                        if ProjectPreferences.shared.actions(path).contains(where: {
                                            $0.isSetup == true
                                        }) {
                                            ProjectActionsMenu(
                                                path: directory, model: model, configurationPath: path, onlySetup: true)
                                        }
                                    }
                                }
                            } else if coordinator.starting {
                                ProgressView().controlSize(.small)
                            }
                            if let taskID = run.taskID,
                                let task = model.backgroundTasks.first(where: { $0.id == taskID })
                            {
                                Text(String(describing: task.status)).font(DockTypography.metadata).foregroundStyle(
                                    Color.dockSecondaryText)
                                if let output = task.output {
                                    Text(GenerativeUIIntegration.plainText(output)).font(DockTypography.body).lineLimit(
                                        6
                                    ).textSelection(.enabled)
                                }
                            }
                            Divider().overlay(Color.dockBorderLight)
                        }.padding(.vertical, 8)
                    }
                }
            }
            if ownerChanged && coordinator.runs.isEmpty {
                Text(
                    "The conversation or connection changed. Your task is kept here; copy it before closing and reopen comparison from its project."
                )
                .font(DockTypography.body).foregroundStyle(Color.dockWarning)
            }
        } footer: {
            Button("Close") { dismiss() }.buttonStyle(.dockSecondary).disabled(coordinator.starting)
            Spacer()
            if coordinator.runs.isEmpty {
                Button("Create worktrees and start") {
                    guard !ownerChanged, (2...3).contains(selectedAvailableCount) else { return }
                    coordinator.start(
                        path: path, prompt: prompt,
                        options: model.runtimeModelOptions.filter { selected.contains($0.id) }, model: model)
                }.buttonStyle(.dockPrimary).disabled(
                    ownerChanged || !(2...3).contains(selectedAvailableCount)
                        || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.font(DockTypography.body).foregroundStyle(Color.dockPrimaryText).frame(width: 650, height: 540)
            .onAppear {
                if ownerIdentity == nil {
                    ownerIdentity = WorkspaceIdentity.session(model)
                    prompt = model.draft
                }
            }
            .onChange(of: model.runtimeModelOptions.map(\.id)) { _, ids in selected.formIntersection(ids) }
            .interactiveDismissDisabled(coordinator.starting)
            .disabled(coordinator.starting)
            .sheet(isPresented: Binding(get: { reviewPath != nil }, set: { if !$0 { reviewPath = nil } })) {
                if let reviewPath {
                    LocalReviewWorkspace(
                        owningSession: reviewSession,
                        onOpenConversation: { session in
                            self.reviewPath = nil
                            model.resumeSession(session)
                            contextRouter?.onOpened(session.id)
                            dismiss()
                        }, path: reviewPath, model: model
                    ).modifier(
                        ReviewSheetContext())
                }
            }
    }
    @State private var reviewPath: String?
    @State private var reviewSession: HermesSession?
}
