import SwiftUI

/// A read-only presentation of Hermes' verified skills and knowledge projection.
///
/// The view deliberately accepts an already parsed inventory. It does not inspect
/// the filesystem or render raw skill/memory content, and unavailable mutations
/// remain visibly disabled until Hermes exposes a verified contract.
struct KnowledgeCenterView: View {
    let inventory: SkillInventory
    @State private var query = ""

    private var filteredSkills: [SkillSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return inventory.skills }
        return inventory.skills.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            $0.source.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.dockBorderLight)
            if inventory.state == .ready {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusCards
                        skillSection
                        bundleSection
                        unavailableActions
                    }
                    .padding(20)
                }
            } else {
                unavailableState
            }
        }
        .background(Color.dockCanvas)
        .accessibilityIdentifier("knowledge-center")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("KNOWLEDGE CENTER")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                    .tracking(0.8)
                Text("Skills & memory")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
            }
            Spacer()
            Text(inventory.state.label.uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(inventory.state == .ready ? Color.dockAccent : Color.dockWarning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var statusCards: some View {
        HStack(spacing: 10) {
            statusCard(title: "CURATOR", status: inventory.curator.status.displayName, icon: .magicWand)
            statusCard(title: "MEMORY", status: inventory.memory.status.displayName, icon: .brain)
            statusCard(title: "MUTATIONS", status: "Unavailable", icon: .shieldCheck)
        }
    }

    private func statusCard(title: String, status: String, icon: Ph) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DockIconLabel(title, icon: icon)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
            Text(status)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 12)
    }

    private var skillSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("SKILLS", detail: "\(filteredSkills.count) visible")
            TextField("Search verified skill summaries", text: $query)
                .textFieldStyle(.dockGlass)
                .accessibilityLabel("Search skills")
            if filteredSkills.isEmpty {
                Text("No matching skill summaries.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
            } else {
                ForEach(filteredSkills) { skill in
                    summaryRow(title: skill.name, subtitle: skill.source,
                               state: skill.isEnabled ? "Enabled" : (skill.isInstalled ? "Installed" : "Not installed"))
                }
            }
        }
    }

    private var bundleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("BUNDLES", detail: "\(inventory.bundles.count) visible")
            if inventory.bundles.isEmpty {
                Text("No bundle summaries were returned by Hermes.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
            } else {
                ForEach(inventory.bundles) { bundle in
                    summaryRow(title: bundle.name, subtitle: bundle.id,
                               state: bundle.isEnabled ? "Enabled" : (bundle.isInstalled ? "Installed" : "Not installed"))
                }
            }
        }
    }

    private var unavailableActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("ACTIONS", detail: "Hermes contract required")
            HStack(spacing: 8) {
                actionButton("Install skill", mutation: .install)
                actionButton("Configure", mutation: .configure)
                actionButton("Curator action", mutation: .curatorMutation)
                actionButton("Write memory", mutation: .memoryWrite)
            }
            Text("Install, configure, Curator mutations, and memory writes are unavailable until exact Hermes contracts are verified.")
                .font(.system(size: 10))
                .foregroundStyle(Color.dockSecondaryText)
        }
        .dockCard(padding: 12)
    }

    private func actionButton(_ title: String, mutation: SkillMutation) -> some View {
        Button(title) { }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.dockMetadataText)
            .disabled(HermesSkillService.capability(mutation) == .unavailable)
            .accessibilityHint("Unavailable: Hermes contract is not verified")
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
                .tracking(0.8)
            Spacer()
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.dockSecondaryText)
        }
    }

    private func summaryRow(title: String, subtitle: String, state: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color.dockAccent).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
                Text(subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.dockSecondaryText)
            }
            Spacer()
            Text(state.uppercased()).font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.dockMetadataText)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 8) {
            DockIconLabel("Skill inventory unavailable", icon: .warning)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text(inventory.diagnostic.isEmpty ? "Hermes did not provide a verified structured inventory." : inventory.diagnostic)
                .font(.system(size: 11))
                .foregroundStyle(Color.dockSecondaryText)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension SkillInventoryState {
    var label: String {
        switch self {
        case .ready: return "Ready"
        case .unavailable: return "Unavailable"
        case .unsupported: return "Unsupported"
        case .malformed: return "Malformed"
        }
    }
}

private extension SkillLifecycleState {
    var displayName: String {
        switch self {
        case .builtIn: return "Built-in"
        default: return rawValue.capitalized
        }
    }
}
