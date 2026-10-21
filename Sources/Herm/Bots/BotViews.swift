import AppKit
import SwiftUI

/// Full Bots destination page for the right workspace pane. Bot profiles use
/// an adaptive card grid; recurring jobs remain a compact schedule list.
struct BotRosterPage: View {
    @ObservedObject var model: BotModeModel
    @ObservedObject var dockModel: DockModel
    let onSelectBot: (BotSummary) -> Void
    let onOpenChat: (BotSummary) -> Void
    let onOpenRecentSession: (BotSummary, BotChatReference) -> Void
    @State private var isShowingCreateSheet = false
    @State private var isPopulatingAvatars = false
    @State private var avatarResult: String?
    @State private var showsAvatarTip = false
    @State private var confirmsRegenerateAll = false
    @State private var editingBot: BotSummary?
    @State private var duplicatingBot: BotSummary?
    @State private var isShowingRoutineForm = false
    @State private var showsHiddenBots = false
    @State private var activityBot: BotSummary?
    @State private var selectedSection: BotRosterSection = .bots
    @State private var activityFilter: BotRosterActivityFilter = .all
    @State private var pendingRoutineRemoval: BotRoutine?
    @State private var pendingBotDeletion: BotSummary?

    private func generateAvatars(all: Bool) {
        showsAvatarTip = false
        Task {
            isPopulatingAvatars = true
            avatarResult = await model.populateAvatars(all: all)
            isPopulatingAvatars = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dockCanvas)
        .alert("Generate Avatars", isPresented: Binding(get: { avatarResult != nil }, set: { if !$0 { avatarResult = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(avatarResult ?? "")
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            BotCreationSheet(model: model, roster: model.bots)
        }
        .sheet(item: $editingBot) { bot in
            BotProfileEditorSheet(model: model, bot: bot) {
                Task {
                    await model.refreshNow(force: true)
                    await model.loadAvatars()
                    await model.loadRuntimeConfigs(force: true)
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
        .confirmationDialog(
            "Remove Routine?",
            isPresented: Binding(
                get: { pendingRoutineRemoval != nil },
                set: { if !$0 { pendingRoutineRemoval = nil } }
            ),
            presenting: pendingRoutineRemoval
        ) { routine in
            Button("Remove \(routine.name)", role: .destructive) {
                pendingRoutineRemoval = nil
                Task { await model.removeRoutine(routine) }
            }
            Button("Cancel", role: .cancel) { pendingRoutineRemoval = nil }
        } message: { _ in
            Text("This removes the recurring Hermes routine. Existing sessions and transcripts are not deleted.")
        }
        .alert(
            "Could Not Remove Routine",
            isPresented: Binding(
                get: { model.routineRemovalError != nil },
                set: { if !$0 { model.clearRoutineRemovalError() } }
            )
        ) {
            Button("OK", role: .cancel) { model.clearRoutineRemovalError() }
        } message: {
            Text(model.routineRemovalError ?? "The routine could not be removed.")
        }
        .confirmationDialog(
            "Delete Bot?",
            isPresented: Binding(get: { pendingBotDeletion != nil }, set: { if !$0 { pendingBotDeletion = nil } }),
            presenting: pendingBotDeletion
        ) { bot in
            Button("Delete \(bot.name)", role: .destructive) {
                pendingBotDeletion = nil
                Task { await model.deleteBot(bot) }
            }
            Button("Cancel", role: .cancel) { pendingBotDeletion = nil }
        } message: { bot in
            Text("Permanently delete \(bot.name) (@\(bot.id)) and all its settings, credentials, memories, sessions, skills, and routines? This also stops its running gateway and affects any active sessions for this Bot. This cannot be undone.")
        }
        .alert("Bot Deletion Needs Attention", isPresented: Binding(
            get: { model.botDeletionError != nil },
            set: { if !$0 { model.botDeletionError = nil } }
        )) {
            Button("OK", role: .cancel) { model.botDeletionError = nil }
        } message: {
            Text(model.botDeletionError ?? "The Bot could not be deleted.")
        }
        .task { await model.loadBotDeletionCapability() }
        .task {
            // A failed roster from a transient launch race or a starved
            // capability probe self-heals here: the page verifies the
            // profiles contract directly, like Hermes' own Bot Mode.
            if model.inventory.availability != .ready { await model.refreshNow(force: true) }
            await model.loadAvatars()
            await model.loadRuntimeConfigs()
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
            title: "Bots",
            subtitle: "\(model.visibleBots.count) Bots · \(model.activeNowBots.count) active",
            onRefresh: { Task { await model.refreshNow(force: true); await model.loadBotDeletionCapability() } },
            isRefreshing: model.isRefreshing
        ) {
            HStack(spacing: 10) {
                if selectedSection == .bots {
                    Button {
                        isShowingCreateSheet = true
                    } label: {
                        DockIconLabel("New Bot", icon: .plus)
                    }
                    .controlSize(.regular)
                    .disabled(!model.canCreateBots)
                    .help(model.canCreateBots ? "Create a new Hermes Bot profile" : "Bot creation requires a Hermes runtime with profile support")
                    Button {
                        showsAvatarTip.toggle()
                    } label: {
                        DockActionLabel(title: "Generate Avatars", pendingTitle: "Generating…", isPending: isPopulatingAvatars)
                    }
                    .controlSize(.regular)
                    .disabled(isPopulatingAvatars)
                    .popover(isPresented: $showsAvatarTip, arrowEdge: .bottom) {
                        BotAvatarGeneratorTip(
                            pending: model.bots.filter { !$0.hasCustomAvatar && !$0.hasAvatar },
                            onFillMissing: { generateAvatars(all: false) },
                            onRegenerateAll: {
                                showsAvatarTip = false
                                confirmsRegenerateAll = true
                            }
                        )
                    }
                    .confirmationDialog("Regenerate all avatars?", isPresented: $confirmsRegenerateAll) {
                        Button("Regenerate All") { generateAvatars(all: true) }
                    } message: {
                        Text("Every Bot gets its Herm face, replacing uploaded and generated images.")
                    }
                } else {
                    Button {
                        isShowingRoutineForm = true
                    } label: {
                        DockIconLabel("New Routine", icon: .plus)
                    }
                    .controlSize(.regular)
                    .disabled(!model.canCreateBots || model.visibleBots.isEmpty)
                    .help("Attach a recurring routine to a Bot")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        // The inventory starts `.unavailable`; don't flash that error during the first fetch.
        if model.isRefreshing && model.inventory.availability != .ready && model.bots.isEmpty {
            DockLoadingState(title: "Loading Bots…", detail: "Reading the Hermes profile roster.")
        } else {
            availabilityContent
        }
    }

    @ViewBuilder
    private var availabilityContent: some View {
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
                detail: "Hermes returned Bot data Herm cannot safely read.",
                showsRetry: true
            )
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedSection == .bots {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        sectionPicker.fixedSize(horizontal: true, vertical: false)
                        botFilters
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionPicker.fixedSize(horizontal: true, vertical: false)
                        botFilters
                    }
                }
                .padding(.horizontal, DockLayout.contentInset)
                .padding(.vertical, DockLayout.tight)
            } else {
                sectionPicker
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, DockLayout.contentInset)
                    .padding(.vertical, DockLayout.tight)
            }
            if selectedSection == .bots { botsContent } else { routinesContent }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sectionPicker: some View {
        DockTabBar(options: BotRosterSection.allCases, selection: $selectedSection) { section in
            section == .bots ? "Bots \(model.visibleBots.count)" : "Routines \(model.routines.count)"
        }
    }

    private var botFilters: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(.magnifyingGlass)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockMetadataText)
                DockTextField("Search Bots", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockPrimaryText)
                    .frame(minWidth: 140)
            }
            .padding(.horizontal, DockLayout.compactInset)
            .frame(maxWidth: .infinity, minHeight: DockLayout.controlHeight)
            .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(Color.dockControlSurface))
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .stroke(Color.dockBorder, lineWidth: DockLayout.hairline)
            }

            DockMenu {
                ForEach(BotRosterActivityFilter.allCases) { filter in
                    Button {
                        activityFilter = filter
                    } label: {
                        if filter == activityFilter {
                            Label(filter.title, icon: .check)
                        } else {
                            Text(filter.title)
                        }
                    }
                }
            } label: {
                Label(activityFilter.title, icon: .funnelSimple)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(minHeight: DockLayout.controlHeight)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(Color.dockControlSurface))
                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                            .stroke(Color.dockBorder, lineWidth: DockLayout.hairline)
                    }
            }
            .help("Filter Bots by activity")

            DockMenu {
                Button {
                    showsHiddenBots = false
                } label: {
                    if !showsHiddenBots { Label("Visible only", icon: .check) }
                    else { Text("Visible only") }
                }
                Button {
                    showsHiddenBots = true
                } label: {
                    if showsHiddenBots { Label("Include hidden", icon: .check) }
                    else { Text("Include hidden") }
                }
            } label: {
                Label(showsHiddenBots ? "All Bots" : "Visible", icon: showsHiddenBots ? .eye : .eyeSlash)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(minHeight: DockLayout.controlHeight)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(Color.dockControlSurface))
                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                            .stroke(Color.dockBorder, lineWidth: DockLayout.hairline)
                    }
            }
            .disabled(model.hiddenBots.isEmpty)
            .help("Choose whether hidden Bots are included")

            if showsHiddenBots || activityFilter != .all {
                Button("Clear") {
                    showsHiddenBots = false
                    activityFilter = .all
                }
                .buttonStyle(.dockCompact)
                .foregroundStyle(Color.dockAccent)
                .fixedSize()
            }
        }
    }

    private var botsContent: some View {
        GeometryReader { proxy in
            let gridWidth = max(0, proxy.size.width - DockLayout.contentInset * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if shownBots.isEmpty {
                        emptyRoster(isSearching: isSearching || activityFilter != .all)
                    } else if model.visibleBots.isEmpty && !showsHiddenBots && !isSearching && activityFilter == .all {
                        hiddenOnlyRoster
                    } else {
                        LazyVGrid(columns: BotRosterGrid.columns(for: gridWidth), alignment: .leading, spacing: 12) {
                            ForEach(shownBots) { bot in botCard(bot) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DockLayout.contentInset)
                .padding(.vertical, DockLayout.tight)
            }
        }
    }

    private func botCard(_ bot: BotSummary) -> some View {
        MissionControlBotRow(
            bot: bot,
            avatarData: model.avatarImages[bot.id],
            runtime: model.runtimeConfigs[bot.id],
            counts: model.capabilityCounts[bot.id],
            isSelected: model.selectedProfileID == bot.id,
            onSelect: { onSelectBot(bot) },
            onOpenChat: { onOpenChat(bot) },
            onOpenRecentSession: { if let session = bot.liveWorkerChat ?? bot.recentSession { onOpenRecentSession(bot, session) } },
            onEdit: { editingBot = bot },
            onShowActivity: { activityBot = bot },
            onDuplicate: { duplicatingBot = bot },
            onToggleHidden: {
                Task { await model.setHidden(!bot.isHidden, for: bot) }
            },
            onDelete: { pendingBotDeletion = bot },
            canDelete: model.canDeleteBot(bot),
            isDeleting: model.deletingBotID == bot.id
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

    private var routinesContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("ROUTINES")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Color.dockMetadataText)
                    Text("\(model.routines.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer()
                    Text("Recurring Hermes jobs")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                }
                .padding(.horizontal, DockLayout.compactInset)
                .padding(.vertical, 10)

                if model.isLoadingRoutines {
                    Text("Loading routines…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .padding(.horizontal, DockLayout.compactInset)
                } else if model.routines.isEmpty {
                    Text("No routines yet — a routine is a recurring Hermes cron job that runs in its Bot’s chat.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        .padding(.horizontal, DockLayout.compactInset)
                } else {
                    ForEach(model.routines) { routine in
                        BotRoutineRow(
                            routine: routine,
                            botName: botDisplayName(routine.profileID),
                            isRemoving: model.removingRoutineID == routine.id,
                            onRemove: { pendingRoutineRemoval = routine }
                        )
                        .equatable()
                        Divider().overlay(Color.dockBorderLight)
                    }
                }
            }
            .padding(.horizontal, DockLayout.contentInset)
            .padding(.vertical, DockLayout.tight)
        }
    }

    private func botDisplayName(_ profileID: String) -> String {
        model.inventory.bots.first { $0.id == profileID }?.name ?? profileID
    }

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shownBots: [BotSummary] {
        model.filteredBots.filter { bot in
            (showsHiddenBots || !bot.isHidden) && activityFilter.includes(bot)
        }
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
                    DockIconLabel("New Bot", icon: .plus)
                }
                .controlSize(.regular)
                .disabled(!model.canCreateBots)
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hiddenOnlyRoster: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No visible Bots")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Button("Reveal hidden Bots", icon: .eye) { showsHiddenBots = true }
                .controlSize(.small)
        }
        .padding(.horizontal, DockLayout.compactInset)
        .padding(.vertical, 12)
    }

    private func unavailableContent(title: String, detail: String, showsRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DockIconLabel(title, icon: .users)
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
                        DockIconLabel("Retry", icon: .arrowsClockwise)
                    }
                    .controlSize(.regular)
                }
                if model.canCreateBots {
                    Button {
                        isShowingCreateSheet = true
                    } label: {
                        DockIconLabel("New Bot", icon: .plus)
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
        DockModal(icon: .ghost, title: "New Bot", subtitle: "Create a Hermes profile with its own identity and skills.", width: 420) {
            modalSection("IDENTITY") {
                labeledField("Name", hint: "Lowercase letters, numbers, dashes, or underscores") {
                    DockTextField("e.g. researcher", text: $name)
                        .textFieldStyle(.dockGlass)
                }
                if !trimmedName.isEmpty && !isValidName {
                    ModalNote(text: "Use lowercase letters, numbers, dashes, or underscores.", icon: .warning, tone: .dockWarning)
                }
                labeledField("Title", hint: "Optional role label") {
                    DockTextField("e.g. Research Analyst", text: $title)
                        .textFieldStyle(.dockGlass)
                }
                labeledField("Description", hint: "Optional one-line responsibility") {
                    DockTextField("What this Bot is responsible for", text: $descriptionText)
                        .textFieldStyle(.dockGlass)
                }
            }

            advancedSection
            if let error = model.botCreationError {
                ModalNote(text: error, icon: .warning, tone: .dockWarning)
            }
        } footer: {
            modalActions(primaryTitle: "Create Bot", pendingTitle: "Creating…", isDisabled: !isValidName || model.isCreatingBot, isPending: model.isCreatingBot, onCancel: { dismiss() }) {
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
                DockIconLabel(showsAdvanced ? "Hide Advanced" : "Advanced", icon: showsAdvanced ? .caretUp : .caretDown)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dockSecondaryText)
            }
            .buttonStyle(.dockPress)
            if showsAdvanced {
                DockMenuPicker("Clone from", title: roster.first { $0.id == cloneFrom }?.name ?? "Fresh profile", selection: $cloneFrom) {
                    DockMenuOption("Fresh profile", value: "")
                    ForEach(roster.filter { !$0.isDefault }) { bot in
                        DockMenuOption(bot.name, value: bot.id)
                    }
                }
                Toggle("Create empty (skip bundled skills)", isOn: $skipsSkills)
                    .controlSize(.small)
            }
        }
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
        DockModal(icon: .clockCounterClockwise, title: "\(bot.name) activity", subtitle: "Work Herm dispatched to this Bot", width: nil, contentPadding: 0) {
            if records.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No recorded Bot activity")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Herm has not dispatched work to \(bot.name) in the retained session history.")
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
        } footer: {
            Spacer()
            Button("Open Chat", action: onOpenChat)
                .buttonStyle(.dockPrimary)
        }
        .frame(minWidth: 500, minHeight: 360)
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

enum BotRosterSection: String, CaseIterable, Identifiable {
    case bots
    case routines

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum BotRosterActivityFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case working

    var id: Self { self }
    var title: String { rawValue.capitalized }

    func includes(_ bot: BotSummary) -> Bool {
        switch self {
        case .all: true
        case .active: bot.isRecentlyActive || bot.isWorkingNow
        case .working: bot.isWorkingNow
        }
    }
}

enum BotRosterRowLayout {
    static let minimumCardWidth: CGFloat = 280
    static let columnSpacing: CGFloat = 12

    static func columnCount(contentWidth: CGFloat) -> Int {
        if contentWidth >= 900 { return 3 }
        if contentWidth >= 600 { return 2 }
        return 1
    }
}

private enum BotRosterGrid {
    static func columns(for contentWidth: CGFloat) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: BotRosterRowLayout.minimumCardWidth), spacing: BotRosterRowLayout.columnSpacing),
            count: BotRosterRowLayout.columnCount(contentWidth: contentWidth)
        )
    }
}

struct BotRosterMetadata: Equatable {
    let model: String?
    let lastActive: String?

    var values: [String] {
        [model, lastActive]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct BotRoutineRow: View, Equatable {
    let routine: BotRoutine
    let botName: String
    let isRemoving: Bool
    let onRemove: () -> Void
    @State private var isHovering = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.routine == rhs.routine && lhs.botName == rhs.botName && lhs.isRemoving == rhs.isRemoving
    }

    var body: some View {
        HStack(spacing: 10) {
            DockIcon(.clockCounterClockwise)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(routine.enabled ? Color.dockAccent : Color.dockMetadataText)
                .frame(width: 28, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(routine.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                    if !routine.enabled {
                        Text("DISABLED")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                }
                HStack(spacing: 5) {
                    Text(botName)
                    Text("·")
                    Text(routine.schedule)
                    if let prompt = routine.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                        Text("·")
                        Text(prompt)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DockMenu {
                Button("Remove", icon: .trash, role: .destructive, action: onRemove)
            } label: {
                DockIcon(.dotsThree)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isRemoving)
            .help("More routine actions")
        }
        .padding(.horizontal, DockLayout.compactInset)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(isHovering ? Color.dockSurface4 : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .dockContextMenu {
            Button("Remove", icon: .trash, role: .destructive, action: onRemove)
                .disabled(isRemoving)
        }
    }
}

struct MissionControlBotRow: View, Equatable {
    let bot: BotSummary
    let avatarData: Data?
    var runtime: BotRuntimeConfig?
    var counts: BotCapabilityCounts?
    var isSelected = false
    let onSelect: () -> Void
    var onOpenChat: (() -> Void)?
    var onOpenRecentSession: (() -> Void)?
    var onEdit: (() -> Void)?
    var onShowActivity: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onToggleHidden: (() -> Void)?
    var onDelete: (() -> Void)?
    var canDelete = false
    var isDeleting = false
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    init(bot: BotSummary, avatarData: Data? = nil, runtime: BotRuntimeConfig? = nil, counts: BotCapabilityCounts? = nil, isSelected: Bool = false, onSelect: @escaping () -> Void, onOpenChat: (() -> Void)? = nil, onOpenRecentSession: (() -> Void)? = nil, onEdit: (() -> Void)? = nil, onShowActivity: (() -> Void)? = nil, onDuplicate: (() -> Void)? = nil, onToggleHidden: (() -> Void)? = nil, onDelete: (() -> Void)? = nil, canDelete: Bool = false, isDeleting: Bool = false) {
        self.bot = bot
        self.avatarData = avatarData
        self.runtime = runtime
        self.counts = counts
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onOpenChat = onOpenChat
        self.onOpenRecentSession = onOpenRecentSession
        self.onEdit = onEdit
        self.onShowActivity = onShowActivity
        self.onDuplicate = onDuplicate
        self.onToggleHidden = onToggleHidden
        self.onDelete = onDelete
        self.canDelete = canDelete
        self.isDeleting = isDeleting
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bot == rhs.bot && lhs.avatarData == rhs.avatarData && lhs.runtime == rhs.runtime && lhs.counts == rhs.counts && lhs.isSelected == rhs.isSelected && lhs.canDelete == rhs.canDelete && lhs.isDeleting == rhs.isDeleting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                BotAvatarView(bot: bot, imageData: avatarData, size: 44)
                identity
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
                    .opacity(isHovering || isFocused || isDeleting ? 1 : 0)
                    .allowsHitTesting(isHovering || isFocused)
                    .accessibilityHidden(!(isHovering || isFocused || isDeleting))
            }
            activity
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            runtimeDetails
            Divider().overlay(Color.dockBorderLight)
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(rowBackground)
        .disabled(isDeleting)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .dockHoverable().onTapGesture(perform: onSelect)
        .onKeyPress(.return) { onSelect(); return .handled }
        .onKeyPress(.space) { onSelect(); return .handled }
        .focusable()
        .focused($isFocused)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(bot.isHidden ? "Hidden Bots cannot be selected" : "Switches the active Bot")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .dockContextMenu {
            Button("Open Chat") { onOpenChat?() }
            if let onOpenRecentSession {
                Button("Open Recent Session", action: onOpenRecentSession)
            }
            Button("Show Activity") { onShowActivity?() }
            Button("Edit Profile…") { onEdit?() }
            Button("Duplicate…") { onDuplicate?() }
            Divider()
            Button(bot.isHidden ? "Unhide Bot" : "Hide Bot") { onToggleHidden?() }
            deleteAction
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(bot.name) Bot")
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(bot.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(bot.isHidden ? Color.dockSecondaryText : Color.dockPrimaryText)
                    .lineLimit(1)
                if isSelected { chip("Active", color: Color.dockSuccess) }
                if bot.isDefault { chip("Default", color: Color.dockAccent) }
                if bot.isHidden { chip("Hidden", color: Color.dockMetadataText) }
            }
            Text(BotRosterPresentation.role(for: bot))
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1)
        }
    }

    /// Fixed-height slot so cards don't resize when the config arrives.
    private var runtimeDetails: some View {
        let fallbacks = runtime?.fallbacks ?? []
        return HStack(spacing: 6) {
            if let modelLabel {
                chip(modelLabel, color: Color.dockSecondaryText, monospaced: true)
                    .help(bot.provider.map { "\($0) / \(modelLabel)" } ?? modelLabel)
            }
            if let effort = runtime?.reasoningEffort {
                chip("Thinking \(effort.capitalized)", color: Color.dockAccent)
            }
            if let first = fallbacks.first {
                chip("Fallback \(first.model)\(fallbacks.count > 1 ? " +\(fallbacks.count - 1)" : "")", color: Color.dockSecondaryText, monospaced: true)
                    .help(fallbacks.map { "\($0.provider) / \($0.model)" }.joined(separator: "\n"))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
    }

    private var isActive: Bool { bot.isWorkingNow || bot.isRecentlyActive }

    private var activity: some View {
        Text(BotRosterPresentation.activity(for: bot))
            .font(.system(size: 12))
            .foregroundStyle(bot.recentSession == nil && !isActive ? Color.dockMetadataText : Color.dockSecondaryText)
            .lineLimit(2)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if isActive {
                DockActivityIndicator(state: .running, size: 10)
            } else {
                Circle().fill(Color.dockMetadataText.opacity(0.5)).frame(width: 6, height: 6)
            }
            Group {
                if bot.isWorkingNow {
                    Text("Working")
                } else if let lastActive = bot.lastActive {
                    Text(lastActive, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                } else {
                    Text("Never active")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(isActive ? Color.dockAccent : Color.dockMetadataText)
            .lineLimit(1)
            Spacer(minLength: 8)
            if let counts {
                Text(counts.label)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
            }
        }
    }

    private func chip(_ text: String, color: Color, monospaced: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: monospaced ? .monospaced : .default))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var modelLabel: String? {
        let model = bot.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? nil : model
    }

    @ViewBuilder
    private var deleteAction: some View {
        if let onDelete {
            Button(isDeleting ? "Deleting…" : "Delete Bot…", role: .destructive, action: onDelete)
                .disabled(!canDelete)
                .help(bot.isDefault || bot.id.lowercased() == "default" ? "The default Bot cannot be deleted" : "Permanently delete this Hermes profile and its data")
        }
    }

    private var actions: some View {
        DockMenu {
            Button("Open Chat", icon: .chatText) { onOpenChat?() }
            if let onOpenRecentSession {
                Button("Open Recent Session", icon: .clock, action: onOpenRecentSession)
            }
            Button("Show Activity", icon: .clockCounterClockwise) { onShowActivity?() }
            Button("Edit Profile…", icon: .gear) { onEdit?() }
            Button("Duplicate…", icon: .copy) { onDuplicate?() }
            Divider()
            Button(bot.isHidden ? "Unhide Bot" : "Hide Bot", icon: bot.isHidden ? .eye : .eyeSlash) { onToggleHidden?() }
            deleteAction
        }
        label: {
            Group {
                if isDeleting { ProgressView().controlSize(.small) }
                else { DockIcon(.dotsThree) }
            }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .dockHitTarget()
        .help("More actions for \(bot.name)")
        .accessibilityLabel("More actions for \(bot.name)")
        .foregroundStyle(Color.dockSecondaryText)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
            .fill(isHovering || isFocused ? Color.dockSurface4 : isSelected ? Color.dockAccentMuted : Color.dockSurface2)
            .overlay {
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .stroke(isFocused || isSelected ? Color.dockAccent : Color.dockBorderLight, lineWidth: isFocused || isSelected ? 1.5 : DockLayout.hairline)
            }
    }
}

/// Live preview for Generate Avatars: the exact Hermes faces it will save,
/// or shuffleable samples when every Bot already has one. Hover a face to
/// set it working; click a sample for a new one. Opens on click and offers
/// the two generate modes.
private struct BotAvatarGeneratorTip: View {
    let pending: [BotSummary]
    let onFillMissing: () -> Void
    let onRegenerateAll: () -> Void
    @State private var samples = (0..<4).map { _ in UUID().uuidString }
    @State private var hovered: String?

    var body: some View {
        let faces = pending.isEmpty ? samples.map { ($0, nil as String?) } : pending.prefix(4).map { ($0.id, Optional($0.name)) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Herm faces for your Bots")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            HStack(spacing: 12) {
                ForEach(faces, id: \.0) { id, name in
                    VStack(spacing: 4) {
                        BotFaceMark(id: id, size: 48, animated: true, busy: hovered == id)
                            .background { if hovered == id { BotSwirlRing(id: id, size: 40) } }
                            .overlay { if hovered == id { BotSwirlRing(id: id, size: 40, front: true) } }
                            .scaleEffect(hovered == id ? 1.12 : 1)
                            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: hovered)
                            .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
                            .onTapGesture {
                                guard pending.isEmpty, let i = samples.firstIndex(of: id) else { return }
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { samples[i] = UUID().uuidString }
                            }
                            .transition(.scale.combined(with: .opacity))
                        if let name {
                            Text(name).font(.system(size: 10)).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
                        }
                    }
                    .frame(width: 56)
                }
            }
            Text(pending.isEmpty
                 ? "Faces blink and glance, and a star orbits them while their Bot works. Click a sample to shuffle."
                 : "Faces blink and glance, and a star orbits them while their Bot works.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Label("Uploaded images stay still. Animations only work on Herm faces.", icon: .info)
                .font(.system(size: 10))
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(spacing: 6) {
                BotAvatarOptionCard(title: "Fill Missing",
                                    detail: pending.isEmpty ? "Every Bot already has an avatar." : "Only Bots still using the placeholder.",
                                    icon: .sparkle, badge: pending.isEmpty ? nil : "\(pending.count)",
                                    done: pending.isEmpty, action: onFillMissing)
                BotAvatarOptionCard(title: "Regenerate All", detail: "Replace every avatar so all Bots match and animate.",
                                    icon: .arrowsClockwise, action: onRegenerateAll)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }
}

/// One Generate Avatars mode: icon tile, title and detail, with a count badge
/// or an "All set" check when there is nothing left to do.
private struct BotAvatarOptionCard: View {
    let title: String
    let detail: String
    let icon: Ph
    var badge: String?
    var done = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                DockIcon(icon, size: 14, color: done ? .dockMetadataText : .dockAccent)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(done ? Color.dockSurface4 : Color.dockAccent.opacity(hovering ? 0.22 : 0.14)))
                    .rotationEffect(.degrees(hovering && !done ? (icon == .arrowsClockwise ? 90 : 12) : 0))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(done ? Color.dockSecondaryText : Color.dockPrimaryText)
                        if let badge {
                            Text(badge).font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.dockAccent)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.dockAccent.opacity(0.14)))
                        }
                    }
                    Text(detail).font(.system(size: 10)).foregroundStyle(Color.dockSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if done {
                    DockIconLabel("All set", icon: .check)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.dockSuccess)
                } else {
                    DockIcon(.caretRight, size: 10, color: .dockMetadataText)
                        .offset(x: hovering ? 2 : 0)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .fill(hovering && !done ? Color.dockSurface6.opacity(0.8) : Color.dockSurface2.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(hovering && !done ? Color.dockAccent.opacity(0.5) : Color.dockBorderLight, lineWidth: DockLayout.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .accessibilityHint(detail)
    }
}
