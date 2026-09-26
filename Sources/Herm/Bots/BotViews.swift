import AppKit
import SwiftUI

/// Full Bots destination page for the right workspace pane. Bot profiles use
/// an adaptive card grid; recurring jobs remain a compact schedule list.
struct BotRosterPage: View {
    @ObservedObject var model: BotModeModel
    @ObservedObject var dockModel: DockModel
    let onSelectBot: (BotSummary) -> Void
    let onOpenRecentSession: (BotSummary, BotChatReference) -> Void
    @State private var isShowingCreateSheet = false
    @State private var editingBot: BotSummary?
    @State private var duplicatingBot: BotSummary?
    @State private var isShowingRoutineForm = false
    @State private var showsHiddenBots = false
    @State private var activityBot: BotSummary?
    @State private var selectedSection: BotRosterSection = .bots
    @State private var activityFilter: BotRosterActivityFilter = .all
    @State private var pendingRoutineRemoval: BotRoutine?

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
            icon: .robot,
            title: "Bots",
            subtitle: "\(model.visibleBots.count) Bots · \(model.activeNowBots.count) active",
            onRefresh: { Task { await model.refreshNow(force: true) } },
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
                detail: "Hermes returned Bot data the Dock cannot safely read.",
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
                TextField("Search Bots", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockPrimaryText)
                    .frame(minWidth: 140)
            }
            .padding(.horizontal, DockLayout.compactInset)
            .frame(maxWidth: .infinity, minHeight: DockLayout.controlHeight)
            .background(Color.dockControlSurface)
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .stroke(Color.dockBorder, lineWidth: DockLayout.hairline)
            }

            Menu {
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
                    .background(Color.dockControlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                            .stroke(Color.dockBorder, lineWidth: DockLayout.hairline)
                    }
            }
            .menuStyle(.borderlessButton)
            .help("Filter Bots by activity")

            Menu {
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
                    .background(Color.dockControlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                            .stroke(Color.dockBorder, lineWidth: DockLayout.hairline)
                    }
            }
            .menuStyle(.borderlessButton)
            .disabled(model.hiddenBots.isEmpty)
            .help("Choose whether hidden Bots are included")

            if showsHiddenBots || activityFilter != .all {
                Button("Clear") {
                    showsHiddenBots = false
                    activityFilter = .all
                }
                .buttonStyle(.borderless)
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
            onSelect: { onSelectBot(bot) },
            onOpenRecentSession: { if let session = bot.recentSession { onOpenRecentSession(bot, session) } },
            onEdit: { editingBot = bot },
            onShowActivity: { activityBot = bot },
            onDuplicate: { duplicatingBot = bot },
            onToggleHidden: {
                Task { await model.setHidden(!bot.isHidden, for: bot) }
            }
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
                DockIconLabel(showsAdvanced ? "Hide Advanced" : "Advanced", icon: showsAdvanced ? .caretUp : .caretDown)
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

            Menu {
                Button("Remove", icon: .trash, role: .destructive, action: onRemove)
            } label: {
                DockIcon(.dotsThree)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .disabled(isRemoving)
            .help("More routine actions")
        }
        .padding(.horizontal, DockLayout.compactInset)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(isHovering ? Color.dockSurface4 : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Remove", icon: .trash, role: .destructive, action: onRemove)
                .disabled(isRemoving)
        }
    }
}

struct MissionControlBotRow: View, Equatable {
    let bot: BotSummary
    let avatarData: Data?
    let onSelect: () -> Void
    var onOpenRecentSession: (() -> Void)?
    var onEdit: (() -> Void)?
    var onShowActivity: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onToggleHidden: (() -> Void)?
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    init(bot: BotSummary, avatarData: Data? = nil, onSelect: @escaping () -> Void, onOpenRecentSession: (() -> Void)? = nil, onEdit: (() -> Void)? = nil, onShowActivity: (() -> Void)? = nil, onDuplicate: (() -> Void)? = nil, onToggleHidden: (() -> Void)? = nil) {
        self.bot = bot
        self.avatarData = avatarData
        self.onSelect = onSelect
        self.onOpenRecentSession = onOpenRecentSession
        self.onEdit = onEdit
        self.onShowActivity = onShowActivity
        self.onDuplicate = onDuplicate
        self.onToggleHidden = onToggleHidden
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bot == rhs.bot && lhs.avatarData == rhs.avatarData
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                BotAvatarView(bot: bot, imageData: avatarData, size: 36)
                identity
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
                    .opacity(isHovering || isFocused ? 1 : 0)
                    .allowsHitTesting(isHovering || isFocused)
                    .accessibilityHidden(!(isHovering || isFocused))
            }
            activity
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            Divider().overlay(Color.dockBorderLight)
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .onKeyPress(.return) { onSelect(); return .handled }
        .onKeyPress(.space) { onSelect(); return .handled }
        .focusable()
        .focused($isFocused)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the canonical Bot chat")
        .contextMenu {
            Button("Open Chat") { onSelect() }
            if let onOpenRecentSession {
                Button("Open Recent Session", action: onOpenRecentSession)
            }
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(bot.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(bot.isHidden ? Color.dockSecondaryText : Color.dockPrimaryText)
                    .lineLimit(1)
                if bot.isDefault { chip("Default", color: Color.dockAccent) }
                if bot.isHidden { chip("Hidden", color: Color.dockMetadataText) }
            }
            Text(BotRosterPresentation.role(for: bot))
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1)
        }
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
            Circle()
                .fill(isActive ? Color.dockAccent : Color.dockMetadataText.opacity(0.5))
                .frame(width: 6, height: 6)
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
            if let modelLabel {
                chip(modelLabel, color: Color.dockSecondaryText, monospaced: true)
                    .help(bot.provider.map { "\($0) / \(modelLabel)" } ?? modelLabel)
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

    private var actions: some View {
        Menu {
            Button("Open Chat", icon: .chatText) { onSelect() }
            if let onOpenRecentSession {
                Button("Open Recent Session", icon: .clock, action: onOpenRecentSession)
            }
            Button("Show Activity", icon: .clockCounterClockwise) { onShowActivity?() }
            Button("Edit Profile…", icon: .gear) { onEdit?() }
            Button("Duplicate…", icon: .copy) { onDuplicate?() }
            Divider()
            Button(bot.isHidden ? "Unhide Bot" : "Hide Bot", icon: bot.isHidden ? .eye : .eyeSlash) { onToggleHidden?() }
        }
        label: {
            DockIcon(.dotsThree)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .dockHitTarget()
        .help("More actions for \(bot.name)")
        .accessibilityLabel("More actions for \(bot.name)")
        .foregroundStyle(Color.dockSecondaryText)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
            .fill(isHovering || isFocused ? Color.dockSurface4 : Color.dockSurface2)
            .overlay {
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .stroke(isFocused ? Color.dockAccent : Color.dockBorderLight, lineWidth: isFocused ? 1.5 : DockLayout.hairline)
            }
    }
}
