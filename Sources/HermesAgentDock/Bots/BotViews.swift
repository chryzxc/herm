import AppKit
import SwiftUI

/// Full Bots destination page for the right workspace pane. Mirrors Hermes'
/// documented Bot Mode roster: search, presence, latest-message previews,
/// and a New Agent path built on the verified `profiles.*` contracts.
struct BotRosterPage: View {
    @ObservedObject var model: BotModeModel
    @ObservedObject var dockModel: DockModel
    let onSelectBot: (BotSummary) -> Void
    @State private var isShowingCreateSheet = false
    @State private var editingBot: BotSummary?
    @State private var duplicatingBot: BotSummary?
    @State private var isShowingRoutineForm = false
    @State private var showsHiddenBots = false
    @State private var activityBot: BotSummary?
    // These are presentation-only preferences. The roster data remains Hermes-owned.
    @State private var rosterColumns = BotRosterColumns()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dockCanvas)
        .sheet(isPresented: $isShowingCreateSheet) {
            BotCreationSheet(model: model, roster: model.bots)
        }
        .sheet(item: $editingBot) { bot in
            BotProfileEditorSheet(model: model, bot: bot) {
                Task {
                    await model.refreshNow(force: true)
                    await model.loadAvatars()
                }
            }
        }
        .sheet(item: $duplicatingBot) { bot in
            BotDuplicateSheet(model: model, bot: bot)
        }
        .sheet(item: $activityBot) { bot in
            BotActivityHistorySheet(
                bot: bot,
                records: activityRecords(for: bot),
                onOpenChat: {
                    activityBot = nil
                    onSelectBot(bot)
                }
            )
        }
        .sheet(isPresented: $isShowingRoutineForm) {
            BotRoutineFormSheet(model: model, bots: model.visibleBots)
        }
        .task {
            // A failed roster from a transient launch race or a starved
            // capability probe self-heals here: the page verifies the
            // profiles contract directly, like Hermes' own Bot Mode.
            if model.inventory.availability != .ready { await model.refreshNow(force: true) }
            await model.loadAvatars()
            await model.loadRoutines()
        }
        .task {
            // Presence is a live projection, not a value that should remain
            // frozen after the page was opened. Keep the refresh bounded to
            // this visible surface so the roster's blue activity state stays
            // truthful without creating a background poller for hidden pages.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await model.refreshNow(force: true)
            }
        }
    }

    private var header: some View {
        DockPageHeader(
            icon: "bot",
            title: "Bots",
            subtitle: "Profiles and routines",
            onRefresh: { Task { await model.refreshNow(force: true) } },
            isRefreshing: model.isRefreshing
        ) {
            HStack(spacing: 10) {
            if !model.hiddenBots.isEmpty {
                Button {
                    showsHiddenBots.toggle()
                } label: {
                    LucideImage(systemName: showsHiddenBots ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockSecondaryText)
                .help(showsHiddenBots ? "Hide hidden Bots" : "Reveal hidden Bots")
            }
            Button {
                isShowingRoutineForm = true
            } label: {
                LucideLabel("Routine", icon: "clock.arrow.circlepath")
            }
            .controlSize(.regular)
            .disabled(!model.canCreateBots || model.visibleBots.isEmpty)
            .help("Attach a recurring routine to a Bot")
            Button {
                isShowingCreateSheet = true
            } label: {
                LucideLabel("New Bot", icon: "plus")
            }
            .controlSize(.regular)
            .disabled(!model.canCreateBots)
            .help(model.canCreateBots ? "Create a Bot from a new Hermes profile" : "Bot creation requires a Hermes runtime with profile support")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.inventory.availability {
        case .ready:
            readyContent
        case .unsupported:
            unavailableContent(
                title: "Bots unavailable",
                detail: "This Hermes runtime does not advertise profile support yet.",
                showsRetry: false
            )
        case .unavailable, .stale:
            unavailableContent(
                title: "Bot roster is unavailable",
                detail: "Hermes did not answer the profile roster request.",
                showsRetry: true
            )
        case .malformed:
            unavailableContent(
                title: "Bot roster is malformed",
                detail: "Hermes returned Bot data the Dock cannot safely read.",
                showsRetry: true
            )
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                LucideImage(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockMetadataText)
                TextField("Search Bots", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockPrimaryText)
            }
            .padding(.horizontal, DockLayout.compactInset)
            .frame(minHeight: DockLayout.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .fill(Color.dockControlSurface)
                    .stroke(Color.dockBorder, lineWidth: DockLayout.hairline)
            )
            .padding(.horizontal, DockLayout.contentInset)
            .padding(.vertical, DockLayout.tight)

            if model.filteredBots.isEmpty {
                emptyRoster(isSearching: isSearching)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        rosterSummary
                        BotRosterTableHeader(columns: $rosterColumns)
                        ForEach(model.visibleBots) { bot in
                            botRow(bot)
                            Divider().overlay(Color.dockBorderLight)
                        }
                        if showsHiddenBots {
                            ForEach(model.hiddenBots) { bot in
                                botRow(bot)
                                Divider().overlay(Color.dockBorderLight)
                            }
                        }
                        routinesSection
                    }
                    .padding(.horizontal, DockLayout.contentInset)
                    .padding(.vertical, DockLayout.tight)
                }
            }
        }
    }

    private var rosterSummary: some View {
        HStack(spacing: 8) {
            Text("FLEET")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Color.dockMetadataText)
            Text("\(model.visibleBots.count) Bots")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockSecondaryText)
            if !model.activeNowBots.isEmpty {
                Text("\(model.activeNowBots.count) recently active")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.dockAccent)
            }
            Spacer(minLength: 0)
            Text("Open a chat or edit a Bot profile")
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
        }
        .padding(.horizontal, DockLayout.compactInset)
        .padding(.vertical, 8)
    }

    private func botRow(_ bot: BotSummary) -> some View {
        MissionControlBotRow(
            bot: bot,
            avatarData: model.avatarImages[bot.id],
            isSelected: false,
            onSelect: { onSelectBot(bot) },
            onEdit: { editingBot = bot },
            onShowActivity: { activityBot = bot },
            onDuplicate: { duplicatingBot = bot },
            onToggleHidden: {
                Task { await model.setHidden(!bot.isHidden, for: bot) }
            },
            columns: rosterColumns
        )
        .equatable()
    }

    private func activityRecords(for bot: BotSummary) -> [BotActivityRecord] {
        dockModel.botActivityBySessionID.values
            .flatMap { $0 }
            .filter { $0.botID == bot.id && !$0.isKanbanReference }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id > $1.id
            }
    }

    @ViewBuilder
    private var routinesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("ROUTINES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Button {
                    isShowingRoutineForm = true
                } label: {
                    LucideImage(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Color.dockSecondaryText)
                .help("New routine")
            }
            if model.isLoadingRoutines {
                Text("Loading routines…").font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
            } else if model.routines.isEmpty {
                Text("No routines yet — a routine is a recurring Hermes cron job that runs in its Bot's chat.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                ForEach(model.routines) { routine in
                    HStack(spacing: 8) {
                        LucideImage(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routine.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                            Text("\(botDisplayName(routine.profileID)) · \(routine.schedule)")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.dockMetadataText)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            Task { await model.removeRoutine(routine) }
                        } label: {
                            LucideImage(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockSecondaryText)
                        .help("Remove routine")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 12)
    }

    private func botDisplayName(_ profileID: String) -> String {
        model.inventory.bots.first { $0.id == profileID }?.name ?? profileID
    }

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func emptyRoster(isSearching: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(BotRosterPresentation.emptyStateTitle(isSearching: isSearching))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text(isSearching
                ? "Try a different name, role, or description."
                : "A Bot is a Hermes profile with its own model, memory, skills, and forever-chat. Create one to give it a role.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
            if !isSearching {
                Button {
                    isShowingCreateSheet = true
                } label: {
                    LucideLabel("New Bot", icon: "plus")
                }
                .controlSize(.regular)
                .disabled(!model.canCreateBots)
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unavailableContent(title: String, detail: String, showsRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LucideLabel(title, icon: "person.2.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
            if !model.inventory.diagnostic.isEmpty {
                Text(model.inventory.diagnostic)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
            }
            HStack {
                if showsRetry {
                    Button {
                        Task { await model.refreshNow(force: true) }
                    } label: {
                        LucideLabel("Retry", icon: "refresh-cw")
                    }
                    .controlSize(.regular)
                }
                if model.canCreateBots {
                    Button {
                        isShowingCreateSheet = true
                    } label: {
                        LucideLabel("New Bot", icon: "plus")
                    }
                    .controlSize(.regular)
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// New Agent quick path from the Hermes Bot Mode docs: Name, Title,
/// Description. The name becomes a new Hermes profile; Hermes remains the
/// authority for creation outcomes and error reporting.
struct BotCreationSheet: View {
    @ObservedObject var model: BotModeModel
    let roster: [BotSummary]
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var title = ""
    @State private var descriptionText = ""
    @State private var showsAdvanced = false
    @State private var cloneFrom = ""
    @State private var skipsSkills = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValidName: Bool { BotCreationSheet.isValidProfileName(trimmedName) }

    static func isValidProfileName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || "-_".contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            modalHeader(title: "New Bot", eyebrow: "BOT PROFILE")

            modalSection("IDENTITY") {
                labeledField("Name", hint: "Lowercase letters, numbers, dashes, or underscores") {
                    TextField("e.g. researcher", text: $name)
                        .textFieldStyle(.dockGlass)
                }
                if !trimmedName.isEmpty && !isValidName {
                    Text("Use lowercase letters, numbers, dashes, or underscores.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockWarning)
                }
                labeledField("Title", hint: "Optional role label") {
                    TextField("e.g. Research Analyst", text: $title)
                        .textFieldStyle(.dockGlass)
                }
                labeledField("Description", hint: "Optional one-line responsibility") {
                    TextField("What this Bot is responsible for", text: $descriptionText)
                        .textFieldStyle(.dockGlass)
                }
            }

            advancedSection
            if let error = model.botCreationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .lineLimit(3)
            }
            modalActions(primaryTitle: "Create Bot", isDisabled: !isValidName || model.isCreatingBot, isPending: model.isCreatingBot, onCancel: { dismiss() }) {
                guard isValidName else { return }
                Task {
                    if await model.createBot(
                        name: trimmedName, title: title, description: descriptionText,
                        cloneFrom: cloneFrom.isEmpty ? nil : cloneFrom,
                        skipsSkills: skipsSkills
                    ) {
                        dismiss()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Color.dockSurface2)
        .onDisappear { model.botCreationError = nil }
    }

    /// The docs' Advanced disclosure: clone an existing profile's config,
    /// skills, SOUL, and memory — or start empty without bundled skills.
    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showsAdvanced.toggle() }
            } label: {
                LucideLabel(showsAdvanced ? "Hide Advanced" : "Advanced", icon: showsAdvanced ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .controlSize(.small)
            if showsAdvanced {
                Picker("Clone from", selection: $cloneFrom) {
                    Text("Fresh profile").tag("")
                    ForEach(roster.filter { !$0.isDefault }) { bot in
                        Text(bot.name).tag(bot.id)
                    }
                }
                Toggle("Create empty (skip bundled skills)", isOn: $skipsSkills)
                    .controlSize(.small)
            }
        }
    }
}



@MainActor
@ViewBuilder
func modalHeader(title: String, eyebrow: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(eyebrow)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(Color.dockMetadataText)
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color.dockPrimaryText)
    }
}

@MainActor
@ViewBuilder
func modalSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 9) {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(Color.dockMetadataText)
        content()
    }
}

@MainActor
@ViewBuilder
func labeledField<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            if let hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
            }
        }
        content()
    }
}

@MainActor
@ViewBuilder
func modalActions(primaryTitle: String, isDisabled: Bool, isPending: Bool, onCancel: @escaping () -> Void, onPrimary: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
        Spacer()
        Button("Cancel", action: onCancel)
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.dockPress)
        Button(action: onPrimary) {
            DockActionLabel(title: primaryTitle, pendingTitle: "Saving…", isPending: isPending)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.dockPrimary)
        .disabled(isDisabled)
    }
}

/// Presentation dimensions shared by the roster header and every Bot row.
/// Activity intentionally takes the remaining width so it remains useful as
/// either adjacent column is resized.
struct BotRosterColumns: Equatable {
    var identity: CGFloat = 230
    var metadata: CGFloat = 168
    let actions: CGFloat = 132

    static let minimumIdentity: CGFloat = 160
    static let minimumMetadata: CGFloat = 132
    static let minimumActivity: CGFloat = 190
    static let horizontalInset: CGFloat = DockLayout.compactInset
    static let columnSpacing: CGFloat = 12

    func maximumIdentity(for availableWidth: CGFloat) -> CGFloat {
        max(
            Self.minimumIdentity,
            availableWidth - (Self.horizontalInset * 2) - (Self.columnSpacing * 3) - metadata - actions - Self.minimumActivity
        )
    }

    func maximumMetadata(for availableWidth: CGFloat) -> CGFloat {
        max(
            Self.minimumMetadata,
            availableWidth - (Self.horizontalInset * 2) - (Self.columnSpacing * 3) - identity - actions - Self.minimumActivity
        )
    }
}

private struct BotRosterTableHeader: View {
    @Binding var columns: BotRosterColumns
    @State private var identityStart: CGFloat?
    @State private var metadataStart: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: BotRosterColumns.columnSpacing) {
                headerLabel("BOT")
                    .frame(width: columns.identity, alignment: .leading)
                headerLabel("ACTIVITY")
                    .frame(maxWidth: .infinity, alignment: .leading)
                headerLabel("MODEL / LAST ACTIVE")
                    .frame(width: columns.metadata, alignment: .trailing)
                headerLabel("ACTIONS")
                    .frame(width: columns.actions, alignment: .trailing)
            }
            .padding(.horizontal, BotRosterColumns.horizontalInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                BotRosterColumnResizeHandle(accessibilityLabel: "Resize Bot column") { translation in
                    if identityStart == nil { identityStart = columns.identity }
                    let start = identityStart ?? columns.identity
                    columns.identity = min(
                        max(BotRosterColumns.minimumIdentity, start + translation),
                        columns.maximumIdentity(for: proxy.size.width)
                    )
                } onEnded: {
                    identityStart = nil
                }
                .offset(x: BotRosterColumns.horizontalInset + columns.identity + (BotRosterColumns.columnSpacing / 2))
            }
            .overlay(alignment: .leading) {
                BotRosterColumnResizeHandle(accessibilityLabel: "Resize Model and last active column") { translation in
                    if metadataStart == nil { metadataStart = columns.metadata }
                    let start = metadataStart ?? columns.metadata
                    columns.metadata = min(
                        max(BotRosterColumns.minimumMetadata, start - translation),
                        columns.maximumMetadata(for: proxy.size.width)
                    )
                } onEnded: {
                    metadataStart = nil
                }
                .offset(x: proxy.size.width - BotRosterColumns.horizontalInset - columns.actions - BotRosterColumns.columnSpacing - columns.metadata - (BotRosterColumns.columnSpacing / 2))
            }
        }
        .frame(height: 27)
        .background(Color.dockSurface4.opacity(0.35))
        .overlay(alignment: .bottom) {
            Divider().overlay(Color.dockBorderLight)
        }
        .accessibilityElement(children: .contain)
    }

    private func headerLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.65)
            .foregroundStyle(Color.dockMetadataText)
            .lineLimit(1)
    }
}

private struct BotRosterColumnResizeHandle: View {
    let accessibilityLabel: String
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.dockAccent.opacity(0.7) : Color.dockBorderLight)
            .frame(width: isHovering ? 2 : DockLayout.hairline, height: 17)
            .frame(width: 10, height: 27)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChanged($0.translation.width) }
                    .onEnded { _ in onEnded() }
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Drag left or right to resize the column")
    }
}

/// Displays the Dock's retained records for explicit work dispatched to one
/// Bot. Hermes does not provide a full activity-feed contract here, so this
/// deliberately does not present chat previews as a complete audit trail.
private struct BotActivityHistorySheet: View {
    let bot: BotSummary
    let records: [BotActivityRecord]
    let onOpenChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(bot.name) activity")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("DOCK-DISPATCHED BOT WORK")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.65)
                        .foregroundStyle(Color.dockMetadataText)
                }
                Spacer()
                Button("Open chat", action: onOpenChat)
                    .buttonStyle(.dockPress)
            }
            .padding(DockLayout.contentInset)

            Divider().overlay(Color.dockBorderLight)

            if records.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No recorded Bot activity")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("The Dock has not dispatched work to \(bot.name) in the retained session history.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(DockLayout.contentInset)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(records) { record in
                            activityRow(record)
                            if record.id != records.last?.id {
                                Divider().overlay(Color.dockBorderLight)
                            }
                        }
                    }
                    .padding(.horizontal, DockLayout.contentInset)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 360)
        .background(Color.dockCanvas)
    }

    private func activityRow(_ record: BotActivityRecord) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(statusColor(for: record.state))
                .frame(width: 7, height: 7)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(record.state.label.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(statusColor(for: record.state))
                    Spacer(minLength: 8)
                    Text(record.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                }
                Text(record.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockPrimaryText)
                    .textSelection(.enabled)
                if let result = record.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func statusColor(for state: BotActivityState) -> Color {
        switch state {
        case .completed: Color.dockSuccess
        case .failed: Color.dockDestructive
        case .canceled: Color.dockMetadataText
        case .queued, .working, .waiting: Color.dockAccent
        }
    }
}

struct MissionControlBotRow: View, Equatable {
    let bot: BotSummary
    let avatarData: Data?
    let isSelected: Bool
    let onSelect: () -> Void
    var onEdit: (() -> Void)?
    var onShowActivity: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onToggleHidden: (() -> Void)?
    var columns = BotRosterColumns()
    @State private var isHovering = false

    init(bot: BotSummary, avatarData: Data? = nil, isSelected: Bool, onSelect: @escaping () -> Void, onEdit: (() -> Void)? = nil, onShowActivity: (() -> Void)? = nil, onDuplicate: (() -> Void)? = nil, onToggleHidden: (() -> Void)? = nil, columns: BotRosterColumns = BotRosterColumns()) {
        self.bot = bot
        self.avatarData = avatarData
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onEdit = onEdit
        self.onShowActivity = onShowActivity
        self.onDuplicate = onDuplicate
        self.onToggleHidden = onToggleHidden
        self.columns = columns
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bot == rhs.bot && lhs.avatarData == rhs.avatarData && lhs.isSelected == rhs.isSelected && lhs.columns == rhs.columns
    }

    var body: some View {
        HStack(spacing: BotRosterColumns.columnSpacing) {
            identity
                .frame(width: columns.identity, alignment: .leading)
            activity
                .frame(maxWidth: .infinity, alignment: .leading)
            metadata
                .frame(width: columns.metadata, alignment: .trailing)
            actions
                .frame(width: columns.actions, alignment: .trailing)
        }
        .padding(.horizontal, DockLayout.compactInset)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open Chat") { onSelect() }
            Button("Show Activity") { onShowActivity?() }
            Button("Edit Profile…") { onEdit?() }
            Button("Duplicate…") { onDuplicate?() }
            Divider()
            Button(bot.isHidden ? "Unhide Bot" : "Hide Bot") { onToggleHidden?() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(bot.name) Bot")
    }

    private var identity: some View {
        HStack(spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                BotAvatarView(bot: bot, imageData: avatarData, size: 32)
                if bot.isRecentlyActive {
                    Circle()
                        .fill(Color.dockAccent)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.dockCanvas, lineWidth: 1.5))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(bot.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(bot.isHidden ? Color.dockSecondaryText : Color.dockPrimaryText)
                        .lineLimit(1)
                    if bot.isDefault {
                        Text("DEFAULT")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.dockMetadataText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.dockSurface4)
                            .clipShape(Capsule())
                    }
                }
                Text(BotRosterPresentation.role(for: bot))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(bot.isRecentlyActive ? "RECENT ACTIVITY" : "LAST ACTIVITY")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.65)
                .foregroundStyle(bot.isRecentlyActive ? Color.dockAccent : Color.dockMetadataText)
            Text(BotRosterPresentation.activity(for: bot))
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1)
        }
    }

    private var metadata: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(bot.model ?? "Model unavailable")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1)
            if let timestamp = bot.lastActive {
                Text(timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
            } else {
                Text("No activity timestamp")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                LucideImage(systemName: "text.bubble")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.dockPress)
            .dockHitTarget()
            .help("Open \(bot.name) chat")
            .accessibilityLabel("Open \(bot.name) chat")

            Button { onShowActivity?() } label: {
                LucideImage(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.dockPress)
            .dockHitTarget()
            .help("Show \(bot.name) activity")
            .accessibilityLabel("Show \(bot.name) activity")

            Button { onEdit?() } label: {
                LucideImage(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.dockPress)
            .dockHitTarget()
            .help("Edit \(bot.name) profile")
            .accessibilityLabel("Edit \(bot.name) profile")
        }
        .foregroundStyle(Color.dockSecondaryText)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
            .fill(isSelected ? Color.dockAccentMuted : (isHovering ? Color.dockSurface4 : Color.clear))
            .overlay {
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .stroke(isSelected ? Color.dockAccent.opacity(0.42) : (isHovering ? Color.dockBorder : Color.clear), lineWidth: DockLayout.hairline)
            }
    }
}
