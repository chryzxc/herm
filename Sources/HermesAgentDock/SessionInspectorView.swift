import AppKit
import KeyboardShortcuts
import SwiftUI
import Foundation
import UniformTypeIdentifiers
struct SessionInspector: View {
    @ObservedObject var model: DockModel
    @ObservedObject var control: ControlCenterModel
    @ObservedObject var workflow: DeveloperWorkflowModel
    var showsHeader = true
    @State private var selectedSection = Section.overview

    private enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case activity = "Activity"
        case changes = "Changes"
        case verification = "Verify"

        var id: Self { self }
        var icon: String {
            switch self {
            case .overview: "bubble.left.and.bubble.right"
            case .activity: "waveform.path.ecg"
            case .changes: "doc.text.magnifyingglass"
            case .verification: "checkmark.seal"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                inspectorHeader
            }
            sessionModePicker

            ScrollView {
                inspectorContent
                    .padding(16)
            }
        }
        .background(Color.scifiCanvas)
        .environment(\.colorScheme, .dark)
    }

    private var sessionModePicker: some View {
        HStack(spacing: 3) {
            ForEach(Section.allCases) { section in
                Button {
                    withAnimation(.scifiEase(duration: 0.2)) {
                        selectedSection = section
                    }
                } label: {
                    Text(section.rawValue.uppercased())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(0.75)
                        .foregroundStyle(selectedSection == section ? Color.scifiFg : Color.scifiMuted)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(selectedSection == section ? Color.scifiAccent.opacity(0.11) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.scifiPress)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Show \(section.rawValue)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    private var inspectorHeader: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.scifiAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentSessionTitle ?? "Untitled session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(model.status.title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(model.status == .working ? Color.scifiAccent : Color.scifiMuted)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch selectedSection {
        case .overview:
            VStack(alignment: .leading, spacing: 14) {
                inspectorLabel("SESSION OVERVIEW")
                inspectorCard(title: "MISSION", value: model.currentSessionTitle ?? "Waiting for a message")
                HStack(spacing: 8) {
                    inspectorMetric("AGENTS", value: control.activeAgents.count, color: .scifiAccent)
                    inspectorMetric("RUNNING", value: model.activeSubagents.count, color: model.activeSubagents.isEmpty ? .scifiMuted : .scifiAccent)
                }
                inspectorCard(
                    title: "LATEST ACTIVITY",
                    value: model.recentEvents.last?.detail ?? "No Hermes activity in this session yet."
                )
            }
        case .activity:
            AgentBoardView(model: model, embedded: true)
        case .changes:
            VStack(alignment: .leading, spacing: 14) {
                inspectorLabel("LOCAL CHANGES")
                if let changes = workflow.changes, workflow.repository.isGitRepository {
                    HStack(spacing: 8) {
                        inspectorMetric("STAGED", value: changes.stagedCount, color: .scifiAccent)
                        inspectorMetric("UNSTAGED", value: changes.unstagedCount, color: .scifiWarning)
                        inspectorMetric("UNTRACKED", value: changes.untrackedCount, color: .scifiMuted)
                    }
                    if changes.files.isEmpty {
                        inspectorCard(title: "WORKING TREE", value: "Clean — no local changes found.")
                    } else {
                        ForEach(changes.files.prefix(8)) { file in
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                    .foregroundStyle(Color.scifiAccent)
                                Text(file.path).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(file.isStaged ? "STAGED" : file.status.rawValue.uppercased())
                                    .foregroundStyle(Color.scifiTertiary)
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.scifiFg)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
                        }
                    }
                } else {
                    inspectorCard(title: "NO PROJECT FOLDER", value: "Choose a local folder from the session's project to inspect changes.")
                }
            }
        case .verification:
            VStack(alignment: .leading, spacing: 14) {
                inspectorLabel("VERIFICATION")
                if let verification = control.verification {
                    let color: Color = verification.state == .passed ? .scifiSuccess : verification.state == .failed ? .scifiDestructive : .scifiWarning
                    inspectorCard(title: "STATUS", value: verification.state.rawValue.uppercased(), accent: color)
                    if let evidence = verification.evidence,
                       let command = evidence.canonicalCommand ?? evidence.command {
                        inspectorCard(title: "EVIDENCE", value: command)
                    }
                } else {
                    inspectorCard(title: "NOT AVAILABLE", value: "Verification results will appear when Hermes reports them for this session.")
                }
            }
        }
    }

    private func inspectorLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(Color.scifiMuted)
    }

    private func inspectorMetric(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(Color.scifiTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.scifiSurface4)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func inspectorCard(title: String, value: String, accent: Color = .scifiFg) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.75)
                .foregroundStyle(Color.scifiTertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.scifiSurface4)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
