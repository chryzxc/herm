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
    @StateObject private var preferences = CommandCenterPreferencesStore()

    private enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case activity = "Activity"
        case files = "Files"
        case changes = "Changes"
        case terminal = "Terminal"
        case browser = "Browser"
        case verification = "Verify"

        var id: Self { self }
        var icon: String {
            switch self {
            case .overview: "bubble.left.and.bubble.right"
            case .activity: "waveform.path.ecg"
            case .files: "folder"
            case .changes: "doc.text.magnifyingglass"
            case .terminal: "terminal"
            case .browser: "safari"
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
        HStack(spacing: 0) {
            ForEach([Section.overview, .activity, .files]) { section in
                sectionButton(section)
            }
            Menu {
                ForEach([Section.changes, .terminal, .browser, .verification]) { section in
                    Button {
                        withAnimation(.scifiEase(duration: 0.2)) { selectedSection = section }
                    } label: {
                        Label(section.rawValue, systemImage: section.icon)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedSection == .overview || selectedSection == .activity || selectedSection == .files ? "More" : selectedSection.rawValue)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selectedSection == .overview || selectedSection == .activity || selectedSection == .files ? Color.scifiMuted : Color.scifiFg)
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay(alignment: .bottom) {
                    if selectedSection != .overview && selectedSection != .activity && selectedSection != .files {
                        Color.scifiAccent.frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 0)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    private func sectionButton(_ section: Section) -> some View {
        Button {
            withAnimation(.scifiEase(duration: 0.2)) {
                selectedSection = section
            }
        } label: {
            Text(section.rawValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selectedSection == section ? Color.scifiFg : Color.scifiMuted)
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay(alignment: .bottom) {
                    if selectedSection == section {
                        Color.scifiAccent.frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.scifiPress)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Show \(section.rawValue)")
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
                    inspectorMetric("RUNNING", value: model.activeSubagents.filter { AgentActivityPresentation.isActiveStatus($0.status) }.count, color: model.activeSubagents.contains { AgentActivityPresentation.isActiveStatus($0.status) } ? .scifiAccent : .scifiMuted)
                }
                inspectorCard(
                    title: "LATEST ACTIVITY",
                    value: model.recentEvents.last?.detail ?? "No Hermes activity in this session yet."
                )
            }
        case .activity:
            AgentBoardView(model: model, embedded: true)
        case .files:
            VStack(alignment: .leading, spacing: 14) {
                inspectorLabel("PROJECT FILES")
                SessionFilesView(
                    projectPath: workflow.repository.path.isEmpty ? nil : workflow.repository.path,
                    onRefresh: { await workflow.refresh(preferences: preferences, control: control) }
                )
            }
        case .changes:
            RepositoryChangesBrowser(
                model: model,
                workflow: workflow,
                projectPath: workflow.repository.path.isEmpty ? nil : workflow.repository.path,
                onRefresh: { await workflow.refresh(preferences: preferences, control: control) }
            )
        case .terminal:
            SessionTerminalView(projectPath: workflow.repository.path.isEmpty ? nil : workflow.repository.path)
        case .browser:
            VStack(alignment: .leading, spacing: 14) {
                inspectorLabel("SESSION BROWSER")
                SessionBrowserView(model: model)
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
