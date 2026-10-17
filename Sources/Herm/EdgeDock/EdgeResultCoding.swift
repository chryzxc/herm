import SwiftUI

struct EdgeResultCoding: View {
  let origin: HermesSession
  let client: HermesRPCClientProtocol
  let activate: () -> Void
  let opened: (String) -> Void
  let created: (IsolatedTaskSetup) -> Void
  @ObservedObject private var developer = DeveloperWorkflowModel.shared
  @State private var expanded = false
  @State private var repository: RepositorySnapshot?
  @State private var baseline: TurnRepositoryBaseline?
  @State private var files: [String] = []
  @State private var diff: String?
  @State private var diffTitle: String?
  @State private var evidence: VerificationEvidenceSummary?
  @State private var error: String?
  @State private var taskText = ""
  @State private var confirming = false
  @State private var pending = false
  @State private var revision = 0
  private var service: HermesWorkflowRPC {
    HermesWorkflowRPC(client: client, profileID: origin.profileID)
  }
  var body: some View {
    DisclosureGroup("Coding review & worktrees", isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        if let repository {
          Text("Repository snapshot: refresh after external changes.").font(.system(size: 11))
            .foregroundStyle(Color.dockSecondaryText)
          Text(repository.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
          if let baseline, baseline.eligible, baseline.clean, baseline.path == repository.path,
            let head = baseline.head
          {
            Text(
              "Changes since turn started (\(head)). This scope may include changes by other writers."
            ).font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
          } else {
            Text("Current repository changes. A clean, owned turn baseline is unavailable.").font(
              .system(size: 11)
            ).foregroundStyle(Color.dockSecondaryText)
          }
          ForEach(Array(files.prefix(12)), id: \.self) { file in
            HStack {
              Text(file).lineLimit(1).truncationMode(.middle)
              Spacer()
              if let baseline, baseline.eligible, baseline.clean, let head = baseline.head,
                baseline.path == repository.path
              {
                Button("Diff") {
                  Task {
                    do {
                      diff = try await RepositoryService.diffSince(
                        path: repository.path, head: head, file: file)
                      diffTitle = file
                    } catch {
                      self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
                    }
                  }
                }.buttonStyle(.dockHover)
              }
              Button("Reveal") {
                ExternalOpen.reveal([
                  URL(fileURLWithPath: repository.path).appendingPathComponent(file)
                ])
              }.buttonStyle(.dockHover)
            }
          }
          if files.count > 12 {
            Text("\(files.count - 12) more files. Open repository review.").font(.system(size: 11))
          }
          if let diff {
            Text(diffTitle ?? "Comparison").font(.system(size: 12, weight: .semibold))
            Text(diff.isEmpty ? "No tracked diff; this may be an untracked file." : diff).font(
              .system(size: 11, design: .monospaced)
            ).textSelection(.enabled)
          }
          if let evidence {
            Text("Recorded repository verification").font(.system(size: 12, weight: .semibold))
            Text(
              "\(evidence.command ?? "Check") · exit \(evidence.exitCode.map(String.init) ?? "unknown")"
            )
            Text("Scope: \(evidence.scope ?? "Not supplied")").font(.system(size: 11))
            if let output = evidence.outputSummary {
              Text(String(output.prefix(1500))).font(.system(size: 11)).textSelection(.enabled)
            }
          } else {
            Text(
              "Current verification evidence is unavailable or lacks matching revision provenance."
            ).font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
          }
          HStack {
            Button("Refresh review") { revision += 1 }.buttonStyle(.dockHover)
            Button("Open repository review") { opened(repository.path) }.buttonStyle(.dockHover)
          }
          DockTextField("Task for a new worktree", text: $taskText, axis: .vertical).textFieldStyle(
            .dockGlass
          ).lineLimit(1...3)
            .simultaneousGesture(TapGesture().onEnded(activate))
            .accessibilityAction(named: Text("Edit isolated worktree task"), activate)
          Button("New task in worktree…") { confirming = true }.buttonStyle(.dockHover)
            .disabled(
              pending || !repository.isGitRepository
                || taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else if pending {
          ProgressView().controlSize(.small)
        } else {
          Text(
            "No verified repository directory is available. Open the session to select its repository."
          ).font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
        }
        if let error { Text(error).foregroundStyle(Color.dockWarning) }
      }.padding(.top, 8)
    }.font(.system(size: 12))
      .task(id: "\(expanded)/\(revision)") { if expanded { await load() } }
      .onChange(of: developer.repositoryFingerprint) { _, _ in
        if let repository, developer.repository.path == repository.path { evidence = nil }
      }
      .confirmationDialog("Create an isolated task?", isPresented: $confirming) {
        Button("Create worktree and session") { Task { await create() } }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Starts at committed HEAD \(repository?.headRevision ?? "unknown") in \(repository?.path ?? ""). The new session belongs to \(origin.profileID ?? "Launch profile"). Worktree and draft remain available if session setup fails."
        )
      }
  }
  private func load() async {
    pending = true
    error = nil
    defer { pending = false }
    do {
      let path = try await service.sessionDirectory(origin)
      let repo = await RepositoryService.inspect(path: path)
      guard !Task.isCancelled else { return }
      repository = repo
      let destination = QuickDestination(profileID: origin.profileID, sessionID: origin.id)
      baseline = developer.turnBaselines[destination.sessionKey]
      if let baseline, baseline.eligible, baseline.clean, baseline.path == path,
        let head = baseline.head
      {
        files = try await RepositoryService.changesSince(path: path, head: head)
      } else {
        files = Array(Set((await RepositoryService.changeSnapshot(path: path)).files.map(\.path)))
          .sorted()
      }
      let verification = try await HermesControlRPC(client: client).verificationStatus(
        sessionID: origin.id, cwd: path)
      let parsed = ControlCenterModel.parseVerification(verification)
      if let record = parsed.evidence, let commit = record.commitFingerprint,
        let head = repo.headRevision, commit.hasPrefix(head), record.repositoryIdentity == path,
        record.staleReason == nil, !record.hasInvalidStaleReason, repo.changedFiles == 0
      {
        evidence = record
      } else {
        evidence = nil
      }
    } catch {
      if !Task.isCancelled {
        self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
      }
    }
  }
  private func create() async {
    guard !pending, let repository else { return }
    pending = true
    defer { pending = false }
    do {
      let id = UUID()
      let path = try await RepositoryService.createTaskWorktree(path: repository.path, id: id)
      let result = await service.createIsolatedSession(path: path, text: taskText, id: id)
      created(result)
    } catch { self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription) }
  }
}
