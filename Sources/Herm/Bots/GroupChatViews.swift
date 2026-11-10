import SwiftUI

/// Mirrors the session row: stacked member avatars, title with its last
/// activity time, and the newest message underneath.
struct GroupChatSidebarRow: View {
    let room: GroupRoom
    @ObservedObject var store: GroupChatStore
    @ObservedObject var botMode: BotModeModel
    let style: DockThemePalette
    let isSelected: Bool
    let date: Date
    let onOpen: () -> Void
    @State private var isHovered = false
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var isConfirmingDisband = false

    private var isWorking: Bool { store.workingRooms.contains(room.id) }
    private var isUnread: Bool { !isSelected && store.isUnread(room) }
    private var activity: DockActivityState? {
        if !(store.approvals[room.id] ?? []).isEmpty { return .approval }
        return isWorking ? .running : isUnread ? .done : nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            avatars
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .dockFont(.navigation, weight: isSelected || isUnread ? .medium : .regular)
                        .foregroundStyle(isSelected ? style.primaryText : style.primaryText.opacity(0.88))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if store.pendingRooms.contains(room.id) {
                        ProgressView().controlSize(.mini).accessibilityLabel("Updating group")
                    }
                    if isHovered {
                        DockMenu {
                            actions
                        } label: {
                            Ph.dotsThree.image(size: 13, color: NSColor(Color.dockSecondaryText))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .fixedSize()
                        .help("More group actions")
                        .accessibilityLabel("More actions for \(room.name)")
                    } else if let activity {
                        DockActivityIndicator(state: activity, size: 12, unreadDot: true)
                    } else {
                        Text(SidebarSessionTime.short(date))
                            .dockFont(.metadata)
                            .monospacedDigit()
                            .foregroundStyle(style.metadataText)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .frame(height: 24)
                Text(store.lastMessages[room.id]?.text ?? room.members.map { "@\($0.handle)" }.joined(separator: " "))
                    .dockFont(.body)
                    .foregroundStyle(style.metadataText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .dockPadding(.horizontal, 6)
        .dockPadding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .dockSelectionFill(
                    isSelected,
                    fallback: isSelected ? style.selectedFill : isHovered ? style.selectedFill.opacity(0.4) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        .dockHoverable().onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .dockContextMenu { actions }
        .alert("Rename group", isPresented: $isRenaming) {
            DockTextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await store.rename(room.id, to: renameText) } }
        }
        .confirmationDialog("Disband \(room.name)?", isPresented: $isConfirmingDisband) {
            Button("Disband", role: .destructive) { Task { await store.disband(room.id) } }
        } message: {
            Text("This stops any running turns and permanently removes the room.")
        }
    }

    /// Hermes rooms support rename, stop and disband; there is no archive.
    @ViewBuilder
    private var actions: some View {
        Button("Rename…", icon: .pencilSimple) {
            renameText = room.name
            isRenaming = true
        }
        if isWorking {
            Button("Stop All Turns", icon: .stop) { Task { await store.stop(room.id) } }
        }
        if store.isUnread(room) {
            Button("Mark as Read", icon: .checks) { store.markSeen(room.id, through: room.latestSeq) }
        }
        Button("Copy Room ID", icon: .copy) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(room.id, forType: .string)
        }
        Divider()
        Button("Disband…", icon: .trash, role: .destructive) { isConfirmingDisband = true }
    }

    /// Up to three avatars; each names its member on hover.
    /// A fixed 42pt tile (the bot row's avatar size): up to four faces in a 2×2 grid, the last slot turning into "+N".
    private var avatars: some View {
        let slots = room.members.count > 4 ? 3 : 4
        let shown = Array(room.members.prefix(slots))
        let extra = room.members.count - shown.count
        let tile = RoundedRectangle(cornerRadius: 20 * 0.28, style: .continuous)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 2), count: 2), spacing: 2) {
            ForEach(shown, id: \.memberID) { member in
                Group {
                    if let bot = botMode.botsByID[member.profile] {
                        BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 20, orbits: isWorking)
                    } else {
                        Text(member.displayName.prefix(1).uppercased())
                            .dockFont(.metadata, weight: .semibold)
                            .foregroundStyle(Color.dockSecondaryText)
                            .frame(width: 20, height: 20)
                            .background(tile.fill(Color.dockSurface2))
                    }
                }
                .help("\(member.displayName) · @\(member.handle)")
            }
            if extra > 0 {
                Text("+\(extra)")
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 20, height: 20)
                    .background(tile.fill(Color.dockSurface2))
                    .help(room.members.dropFirst(slots).map(\.displayName).joined(separator: ", "))
            }
        }
        .frame(width: 42, height: 42)
    }
}

/// A thread tab: titles are clipped until hovered, then ease open to their full text.
private struct GroupThreadChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let isSelected: Bool
    let onClose: (() -> Void)?
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                Text(title)
                    .dockFont(.body, weight: isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .frame(maxWidth: isHovered ? 480 : 110, alignment: .leading)
            }
            .buttonStyle(.dockHover)
            if let onClose {
                Button(action: onClose) {
                    DockIcon(.x, size: 10, color: Color.dockSecondaryText).frame(width: 16, height: 16)
                }
                .buttonStyle(.dockHover)
                .help("Close thread")
                .accessibilityLabel("Close \(title)")
            }
        }
        .dockPadding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(isSelected ? Color.dockAccentMuted : Color.dockSurface2))
        .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isHovered)
    }
}

struct NewGroupChatSheet: View {
    @ObservedObject var store: GroupChatStore
    @ObservedObject var botMode: BotModeModel
    let bots: [BotSummary]
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.create
    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var isCreating = false
    /// Fixed when the sheet opens: invites from other machines are scoped to it.
    @State private var roomID = UUID().uuidString.lowercased()
    @State private var remote: [RemoteDraft] = []

    enum Mode { case create, share }

    /// A remote seat: the request code goes out, the other machine's invite comes back.
    struct RemoteDraft: Identifiable {
        let id = "peer-" + UUID().uuidString.prefix(8).lowercased()
        var handle = ""
        var reply = ""
        var invite: RemoteMemberInvite? {
            RoomLinkCode.decode(RemoteMemberInvite.self, from: reply).flatMap { $0.memberID == id ? $0 : nil }
        }
    }

    private var chosen: [BotSummary] { bots.filter { selected.contains($0.id) } }
    private var memberCount: Int { chosen.count + remote.count }
    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && GroupChatStore.memberLimits.contains(memberCount)
            && remote.allSatisfy { $0.invite != nil } && !isCreating
    }

    var body: some View {
        DockModal(
            title: mode == .create ? "New Group Chat" : "Share a Bot",
            subtitle: mode == .create
                ? "Bring several Bots into one conversation." : "Answer another Mac's request with one of your Bots.",
            width: 440
        ) {
            if store.isRoomLinkEnabled {
                DockSegmentedPicker(
                    selection: $mode, options: [(Mode.create, "Create a group"), (Mode.share, "Join from another Mac")])
            }
            if mode == .create { createForm } else { ShareBotForm(store: store, bots: bots) }
            if let message = store.errorMessage { ModalNote(text: message, icon: .warning, tone: .dockDestructive) }
        } footer: {
            if mode == .create {
                modalActions(
                    primaryTitle: "Create", pendingTitle: "Creating…", isDisabled: !canCreate, isPending: isCreating,
                    onCancel: { dismiss() }, onPrimary: create)
            } else {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(
                    DockModalButtonStyle(isPrimary: true))
            }
        }
    }

    private func create() {
        isCreating = true
        Task {
            if let created = await store.create(
                name: name.trimmingCharacters(in: .whitespaces), bots: chosen,
                remote: remote.compactMap(\.invite), roomID: roomID
            ) {
                onCreated(created)
                dismiss()
            }
            isCreating = false
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledField("Name") { DockTextField("Group name", text: $name).textFieldStyle(.dockGlass) }
            Text("Members (\(GroupChatStore.memberLimits.lowerBound)–\(GroupChatStore.memberLimits.upperBound))")
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bots) { bot in
                        Toggle(
                            isOn: Binding(
                                get: { selected.contains(bot.id) },
                                set: { if $0 { selected.insert(bot.id) } else { selected.remove(bot.id) } }
                            )
                        ) {
                            HStack(spacing: 8) {
                                BotAvatarView(
                                    bot: bot, imageData: botMode.avatarImages[bot.id], size: 22, animated: false)
                                Text(bot.name) + Text("  @\(bot.id)").foregroundColor(Color.dockMetadataText)
                            }
                        }
                        .toggleStyle(.dockCheckbox)
                        .disabled(!selected.contains(bot.id) && memberCount >= GroupChatStore.memberLimits.upperBound)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            if store.isRoomLinkEnabled, let installID = store.installID {
                ForEach($remote) { $seat in remoteSeat($seat, installID: installID) }
                Button {
                    remote.append(RemoteDraft())
                } label: {
                    DockIconLabel("Add a bot from another Mac", icon: .plugsConnected)
                }
                .buttonStyle(.dockCompact)
                .disabled(memberCount >= GroupChatStore.memberLimits.upperBound)
            }
        }
    }

    private func remoteSeat(_ seat: Binding<RemoteDraft>, installID: String) -> some View {
        let handle = seat.wrappedValue.handle.trimmingCharacters(in: .whitespaces).lowercased()
        let request = RoomLinkCode.encode(
            RemoteMemberRequest(
                roomID: roomID, homeInstallID: installID,
                memberID: seat.wrappedValue.id, handle: handle))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                DockTextField("Handle, e.g. scout", text: seat.handle).textFieldStyle(.dockGlass)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(request, forType: .string)
                } label: {
                    DockIconLabel("Copy request", icon: .copy)
                }
                .disabled(handle.isEmpty)
                Button {
                    remote.removeAll { $0.id == seat.wrappedValue.id }
                } label: {
                    DockIcon(.x)
                }
                .buttonStyle(.dockHover)
            }
            DockTextField("Paste the invite from the other Mac", text: seat.reply).textFieldStyle(.dockGlass)
            if !seat.wrappedValue.reply.isEmpty, seat.wrappedValue.invite == nil {
                Text("That invite isn't for this seat.").dockFont(.metadata).foregroundStyle(Color.dockWarning)
            } else if let invite = seat.wrappedValue.invite {
                Text("\(invite.displayName) joins as @\(invite.handle)").dockFont(.metadata).foregroundStyle(
                    Color.dockMetadataText)
            }
        }
        .dockPadding(10)
        .dockWell(radius: 8)
    }
}

/// Target side of RoomLink: answer another Mac's request code with an invite
/// for one of this machine's bots.
private struct ShareBotForm: View {
    @ObservedObject var store: GroupChatStore
    let bots: [BotSummary]
    @State private var requestCode = ""
    @State private var botID: String?
    @State private var invite: String?
    @State private var isWorking = false

    private var request: RemoteMemberRequest? { RoomLinkCode.decode(RemoteMemberRequest.self, from: requestCode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Paste the request copied on the Mac that's creating the group, pick a bot to share, then send the invite back."
            )
            .dockFont(.metadata)
            .foregroundStyle(Color.dockMetadataText)
            .fixedSize(horizontal: false, vertical: true)
            DockTextField("Request code", text: $requestCode).textFieldStyle(.dockGlass)
            DockMenuPicker("Bot", title: bots.first { $0.id == botID }?.name ?? "Choose…", selection: $botID) {
                DockMenuOption("Choose…", value: String?.none)
                ForEach(bots) { DockMenuOption($0.name, value: Optional($0.id)) }
            }
            Button(isWorking ? "Creating invite…" : "Create invite") {
                guard let request, let bot = bots.first(where: { $0.id == botID }) else { return }
                isWorking = true
                Task {
                    invite = await store.invite(request, bot: bot)
                    isWorking = false
                }
            }
            .disabled(request == nil || botID == nil || isWorking)
            if let invite {
                HStack {
                    Text(invite).dockFont(.machineMetadata).lineLimit(2).truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invite, forType: .string)
                    } label: {
                        DockIconLabel("Copy invite", icon: .copy)
                    }
                }
            }
        }
    }
}

struct GroupChatView: View {
    @Environment(\.dockHostVisible) private var hostVisible
    @ObservedObject var store: GroupChatStore
    @ObservedObject var botMode: BotModeModel
    let roomID: String
    /// Wraps the room's name and actions in the app's conversation toolbar.
    /// The same reading and composer widths as the normal conversation.
    var metrics = ConversationWorkspaceMetrics.resolve(isFullscreen: true)
    let toolbar: (AnyView, AnyView) -> AnyView
    let onDisbanded: () -> Void
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    @StateObject private var voiceOutput = VoiceOutput()
    @State private var speakingEventID: String?
    @State private var replyQuote: ReplyQuote?
    @State private var draft = ""
    @State private var mentionIndex = 0
    @State private var dismissedMentionToken: String?
    // Not @State: the editor consumes it during a view update, where a state write is dropped and the caret keeps snapping back.
    private final class CaretBox { var value: Int? }
    private let pendingCaretBox = CaretBox()
    private var pendingCaret: Int? {
        get { pendingCaretBox.value }
        nonmutating set { pendingCaretBox.value = newValue }
    }
    @State private var editorHeight = ComposerLayout.minHeight
    @State private var isEditorFocused = true
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var isConfirmingDisband = false
    @State private var thread = GroupChatStore.mainThreadID
    @State private var newThreads: [String] = []
    /// Threads hidden from the bar; their messages stay in the room. Cleared when the room changes.
    @State private var closedThreads: Set<String> = []
    @State private var showingInsertPopover = false

    private var room: GroupRoom? { store.rooms.first { $0.id == roomID } }
    private var allEvents: [GroupRoomEvent] { store.events[roomID] ?? [] }
    /// The selected thread plus room-wide notices. Events from before threads carry no id and stay in Main.
    private var events: [GroupRoomEvent] {
        allEvents.filter {
            ($0.threadID ?? GroupChatStore.mainThreadID) == thread || ($0.threadID == nil && $0.kind == .notice)
        }
    }

    /// Threads in first-seen order; Hermes has no thread names, so each is titled by its first message.
    private var threads: [(id: String, title: String)] {
        var ids = [GroupChatStore.mainThreadID]
        for id in allEvents.compactMap(\.threadID) + newThreads where !ids.contains(id) && !closedThreads.contains(id) {
            ids.append(id)
        }
        return ids.map { id in
            guard id != GroupChatStore.mainThreadID else { return (id, "Main") }
            let first = allEvents.first { $0.threadID == id && $0.kind == .user }?.text ?? "New thread"
            return (id, String(first.prefix(120)))
        }
    }
    /// Threads newest-activity first, each labelled with its title and last activity (✓ marks the open one).
    private var recentThreads: [(id: String, label: String)] {
        var rows: [(id: String, label: String, last: Date)] = []
        for item in threads {
            let last = allEvents.last { ($0.threadID ?? GroupChatStore.mainThreadID) == item.id }?.createdAt
            let when = last.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""
            rows.append((item.id, (item.id == thread ? "✓ " : "") + item.title + when, last ?? .distantPast))
        }
        return rows.sorted { $0.last > $1.last }.map { ($0.id, $0.label) }
    }
    private var isWorking: Bool { store.workingRooms.contains(roomID) }

    /// Members whose latest turn started but has not posted or failed yet.
    private var thinkingMembers: [GroupRoom.Member] {
        var open: [String] = []
        for event in events {
            switch event.kind {
            case .started(let id): if !open.contains(id) { open.append(id) }
            case .member(let id): open.removeAll { $0 == id }
            case .failed(let id): open.removeAll { $0 == id }
            default: break
            }
        }
        guard isWorking else { return [] }
        return open.compactMap { room?.member($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if threads.count > 1 || !newThreads.isEmpty { threadBar }
            transcript
            ForEach(store.approvals[roomID] ?? [], id: \.requestID) { approval in
                approvalBanner(approval)
            }
            ForEach(store.retries[roomID] ?? [], id: \.self) { taskID in
                banner(
                    icon: .warning,
                    text:
                        "A member's turn was interrupted and its result is unknown. Retrying may repeat work it already did."
                ) {
                    DockAsyncButton("Retry") { await store.retry(taskID, in: roomID) }
                        .buttonStyle(.dockPrimary)
                }
            }
            if store.blockedRooms.contains(roomID), (store.retries[roomID] ?? []).isEmpty {
                banner(icon: .pause, text: "The room is paused while Hermes settles a stopped or interrupted turn.") {
                    EmptyView()
                }
            }
            composer
        }
        .background(Color.dockCanvas)
        .onChange(of: roomID) {
            thread = GroupChatStore.mainThreadID
            newThreads = []
            closedThreads = []
        }
        .onChange(of: room == nil) { _, gone in if gone, store.isAvailable { onDisbanded() } }
        .task(id: "\(roomID):\(hostVisible)") {
            guard hostVisible else { return }
            while !Task.isCancelled {
                await store.poll(roomID)
                // ponytail: fixed-interval polling; Hermes has no room push events.
                try? await Task.sleep(for: .seconds(store.workingRooms.contains(roomID) ? 1.5 : 5))
            }
        }
        .alert("Rename group", isPresented: $isRenaming) {
            DockTextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await store.rename(roomID, to: renameText) } }
        }
        .confirmationDialog("Disband \(room?.name ?? "this group")?", isPresented: $isConfirmingDisband) {
            Button("Disband", role: .destructive) {
                Task {
                    await store.disband(roomID)
                    if store.rooms.contains(where: { $0.id == roomID }) == false { onDisbanded() }
                }
            }
        } message: {
            Text("This stops any running turns and permanently removes the room.")
        }
    }

    private var header: some View {
        toolbar(AnyView(headerIdentity), AnyView(headerActions))
    }

    /// The room's name with its members, where a bot chat shows the bot.
    private var headerIdentity: some View {
        HStack(spacing: 8) {
            memberAvatars
            Text(room?.name ?? "Group Chat")
                .dockFont(.navigation, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
            Text(headerSubtitle)
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
            if store.pendingRooms.contains(roomID) {
                ProgressView().controlSize(.mini).accessibilityLabel("Updating group")
            } else if isWorking {
                ThinkingDots()
            }
        }
        .dockPadding(.horizontal, 8)
    }

    private var headerActions: some View {
        HStack(spacing: 4) {
            DockMenu {
                Button("New thread") { startThread() }
                if threads.count > 1 {
                    DockMenu("Recent threads") {
                        ForEach(recentThreads, id: \.id) { item in
                            Button {
                                thread = item.id
                            } label: {
                                Text(item.label)
                            }
                        }
                    }
                }
                Button("Rename…") {
                    renameText = room?.name ?? ""
                    isRenaming = true
                }
                Button("Disband…", role: .destructive) { isConfirmingDisband = true }
            } label: {
                DockIcon(.dotsThree, size: DockLayout.toolbarIconSize, color: Color.dockSecondaryText)
                    .frame(width: DockLayout.iconControlSize, height: DockLayout.iconControlSize)
                    .contentShape(Rectangle())
            }
            .fixedSize()
            .help("Group actions")
        }
    }

    private var headerSubtitle: String {
        guard let room else { return "" }
        let thinking = thinkingMembers.map(\.displayName)
        if !thinking.isEmpty {
            return
                "\(ListFormatter.localizedString(byJoining: thinking)) \(thinking.count == 1 ? "is" : "are") replying"
        }
        return "\(room.members.count) members"
    }

    /// Stacked member chips under the title; hover names the member, a working member gets an accent ring.
    private var memberAvatars: some View {
        let thinking = Set(thinkingMembers.map(\.memberID))
        return HStack(spacing: -7) {
            ForEach(room?.members ?? [], id: \.memberID) { member in
                ZStack {
                    Circle().fill(Color.dockSurface)
                    if let bot = botMode.botsByID[member.profile] {
                        BotAvatarView(
                            bot: bot, imageData: botMode.avatarImages[bot.id], size: 22,
                            orbits: thinking.contains(member.memberID))
                    } else {
                        Text(member.displayName.prefix(1).uppercased())
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
                .frame(width: 26, height: 26)
                .overlay(
                    Circle().stroke(
                        thinking.contains(member.memberID) ? Color.dockAccent : Color.dockBorderLight, lineWidth: 1)
                )
                .background(Circle().stroke(Color.dockCanvas, lineWidth: 3))
                .help("\(member.displayName) · @\(member.handle)")
            }
        }
    }

    private var threadBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(threads, id: \.id) { item in
                    GroupThreadChip(
                        title: item.title, isSelected: item.id == thread,
                        onClose: item.id == GroupChatStore.mainThreadID ? nil : { closeThread(item.id) }
                    ) { thread = item.id }
                }
                Button {
                    startThread()
                } label: {
                    DockIcon(.plus, size: 12, color: Color.dockSecondaryText).frame(width: 24, height: 24)
                }
                .buttonStyle(.dockHover)
                .help("New thread — members only see messages in the same thread")
            }
            .dockPadding(.horizontal, 20)
            .dockPadding(.vertical, 8)
        }
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private func closeThread(_ id: String) {
        closedThreads.insert(id)
        newThreads.removeAll { $0 == id }
        if thread == id { thread = GroupChatStore.mainThreadID }
    }

    private func startThread() {
        let id = "t-" + UUID().uuidString.prefix(8).lowercased()
        newThreads.append(id)
        thread = id
        isEditorFocused = true
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if events.isEmpty {
                        Text(
                            "Mention a member with @handle, or address everyone with @all. With no mention, every member may reply."
                        )
                        .dockFont(.body)
                        .foregroundStyle(Color.dockMetadataText)
                        .frame(maxWidth: .infinity)
                        .dockPadding(.top, 40)
                    }
                    if (store.earliestLoadedSeq[roomID] ?? 0) > 0 {
                        DockAsyncButton("Load earlier messages") { await store.loadEarlier(roomID) }
                            .buttonStyle(.dockCompact)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockAccent)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(events) { event in row(event) }
                    ForEach(thinkingMembers, id: \.memberID) { member in
                        HStack(alignment: .top, spacing: 10) {
                            avatar(for: member, working: true)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(member.displayName)
                                        .dockFont(.body, weight: .semibold)
                                        .foregroundStyle(Color.dockSecondaryText)
                                    ThinkingDots()
                                }
                                TurnActivityView(
                                    activity: store.liveTools(for: member.memberID, in: roomID),
                                    runningSince: startedAt(member.memberID) ?? .now,
                                    duration: nil
                                )
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .dockPadding(.horizontal, metrics.contentInset)
                .dockPadding(.vertical, 12)
                .frame(maxWidth: metrics.readingWidth)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: events.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func row(_ event: GroupRoomEvent) -> some View {
        switch event.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                let split = ReplyQuote.split(GenerativeUIIntegration.displayUserText(event.text))
                VStack(alignment: .leading, spacing: 6) {
                    if let quote = split?.quote { ReplyQuoteChip(quote: quote) }
                    Text.withFileIcons(
                        AttributedString(split?.body ?? GenerativeUIIntegration.displayUserText(event.text)),
                        iconSize: 13
                    )
                    .textSelection(.enabled)
                }
                .dockPadding(.horizontal, 14)
                .dockPadding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.dockAccentMuted))
            }
        case .member(let memberID):
            let member = room?.member(memberID)
            HStack(alignment: .top, spacing: 10) {
                avatar(for: member)
                VStack(alignment: .leading, spacing: 4) {
                    Text(member?.displayName ?? memberID)
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockSecondaryText)
                    let tools = store.tools(for: event, in: roomID)
                    if !tools.isEmpty {
                        TurnActivityView(activity: tools, runningSince: nil, duration: turnDuration(ending: event))
                    }
                    GenerativeUIIntegration.renderReply(event.text) {
                        MarkdownMessageView(markdown: event.text, cacheKey: event.id)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    replyActions(for: event, author: member?.displayName ?? memberID)
                }
            }
        case .failed(let memberID):
            Label(
                "\(room?.member(memberID)?.displayName ?? "A member"): \(event.text)",
                systemImage: "exclamationmark.triangle"
            )
            .dockFont(.metadata)
            .foregroundStyle(Color.dockWarning)
        case .notice:
            Text(event.text)
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .frame(maxWidth: .infinity)
        case .started:
            EmptyView()
        }
    }

    /// Copy / read aloud / timestamp under a member reply, matching the single-chat row.
    private func replyActions(for event: GroupRoomEvent, author: String) -> some View {
        let isSpeaking = voiceOutput.isSpeaking && speakingEventID == event.id
        return HStack(spacing: 0) {
            DockCopyButton(
                GenerativeUIIntegration.plainText(event.text), accessibilityLabel: "Copy message", presentation: .icon,
                iconSize: 12
            )
            .buttonStyle(DockPressButtonStyle())
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            Button {
                if isSpeaking {
                    voiceOutput.stop()
                } else {
                    speakingEventID = event.id
                    voiceOutput.speak(messageID: UUID(), text: event.text)
                }
            } label: {
                DockIcon(
                    isSpeaking ? .stop : .speakerHigh, size: 12, color: isSpeaking ? .dockAccent : .dockSecondaryText)
            }
            .buttonStyle(DockPressButtonStyle())
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help(isSpeaking ? "Stop reading aloud" : "Read message aloud")
            Button {
                replyQuote = ReplyQuote(author: author, text: event.text)
                isEditorFocused = true
            } label: {
                DockIcon(.arrowBendUpLeft, size: 12, color: .dockSecondaryText)
            }
            .buttonStyle(DockPressButtonStyle())
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help("Reply to this message")
            Rectangle().fill(Color.dockBorderLight).frame(width: 1, height: 12).dockPadding(.horizontal, 6)
            Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                .dockFont(.machineMetadata)
                .foregroundStyle(Color.dockMetadataText)
        }
    }

    /// When the member's open turn started, from the last `turn.started`.
    private func startedAt(_ memberID: String) -> Date? {
        events.last { $0.kind == .started(memberID: memberID) }?.createdAt
    }

    private func turnDuration(ending event: GroupRoomEvent) -> TimeInterval? {
        guard case .member(let memberID) = event.kind,
            let start = events.last(where: { $0.seq < event.seq && $0.kind == .started(memberID: memberID) })
        else { return nil }
        return event.createdAt.timeIntervalSince(start.createdAt)
    }

    private func banner<Actions: View>(icon: Ph, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            DockIcon(icon).foregroundStyle(Color.dockWarning)
            Text(text).dockFont(.metadata)
            Spacer()
            actions()
        }
        .dockPadding(12)
        .dockWell(radius: 10)
        .dockPadding(.horizontal, 20)
        .dockPadding(.top, 8)
    }

    @ViewBuilder
    private func avatar(for member: GroupRoom.Member?, working: Bool = false) -> some View {
        if let member, let bot = botMode.botsByID[member.profile] {
            BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 28, orbits: working)
        } else {
            let side = DockWorkspaceScale.points(28, scale: workspaceScale)
            Circle().fill(Color.dockSurface4).frame(width: side, height: side)
        }
    }

    private func approvalBanner(_ approval: GroupRoomApproval) -> some View {
        HStack(spacing: 10) {
            Text("\(room?.member(approval.memberID)?.displayName ?? approval.memberID) wants to run:")
                .dockFont(.metadata, weight: .semibold)
            Text(approval.summary)
                .dockFont(.machineMetadata)
                .lineLimit(2)
            Spacer()
            Button("Deny") { Task { await store.respond(to: approval, in: roomID, approve: false) } }
                .disabled(store.pendingRooms.contains(roomID))
            Button {
                Task { await store.respond(to: approval, in: roomID, approve: true) }
            } label: {
                DockActionLabel(
                    title: "Allow once", pendingTitle: "Responding…", isPending: store.pendingRooms.contains(roomID))
            }
            .disabled(store.pendingRooms.contains(roomID))
            .buttonStyle(.dockPrimary)
        }
        .dockPadding(12)
        .dockWell(radius: 10)
        .dockPadding(.horizontal, 20)
        .dockPadding(.top, 8)
    }

    private var mentionToken: String? { ComposerMentionPresentation.activeToken(in: draft) }

    /// Room members (plus @all) matching the trailing `@token`, by handle or name.
    private var mentionItems: [ComposerCompletionItem] {
        guard let token = mentionToken, token != dismissedMentionToken, let room else { return [] }
        let query = token.dropFirst().lowercased()
        let rows =
            room.members.map {
                ComposerCompletionItem(
                    text: "@\($0.handle)", display: "@\($0.handle)", meta: memberDescription($0), group: "Members",
                    bot: botMode.botsByID[$0.profile])
            } + [ComposerCompletionItem(text: "@all", display: "@all", meta: "Everyone", group: "Members")]
        guard !query.isEmpty else { return rows }
        let names = Dictionary(
            room.members.map { ("@\($0.handle)", $0.displayName.lowercased()) }, uniquingKeysWith: { first, _ in first }
        )
        return rows.filter {
            $0.text.dropFirst().lowercased().hasPrefix(query) || names[$0.text]?.hasPrefix(query) == true
        }
    }

    /// The bot's description (what it does), like the main composer; the handle already names it.
    private func memberDescription(_ member: GroupRoom.Member) -> String {
        let bot = botMode.botsByID[member.profile]
        let text = bot?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text! : member.isRemote ? "On another Mac" : bot?.title ?? ""
    }

    private func acceptMention(_ item: ComposerCompletionItem) {
        guard let token = mentionToken else { return }
        draft = String(draft.dropLast(token.count)) + item.text + " "
        pendingCaret = (draft as NSString).length
    }

    /// The popover owns ↑↓, ↩/⇥ and esc while it shows rows.
    private func handleMentionKey(_ key: ComposerCompletionKey) -> Bool {
        let items = mentionItems
        guard !items.isEmpty else { return false }
        switch key {
        case .up: mentionIndex = (mentionIndex - 1 + items.count) % items.count
        case .down: mentionIndex = (mentionIndex + 1) % items.count
        case .escape: dismissedMentionToken = mentionToken
        case .tab, .enter: acceptMention(items[min(mentionIndex, items.count - 1)])
        }
        return true
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let token = mentionToken, !mentionItems.isEmpty {
                ComposerCompletionPopover(
                    trigger: .mention(token),
                    items: mentionItems,
                    selectedIndex: min(mentionIndex, mentionItems.count - 1),
                    avatarImages: botMode.avatarImages,
                    onSelect: acceptMention
                )
            }
            // Same native editor and card as the main chat composer; rooms are text-only, so no
            // attachment, model or voice controls.
            if let quote = replyQuote {
                ReplyQuoteChip(quote: quote) { replyQuote = nil }
                    .dockPadding(.horizontal, 12)
            }
            VStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    ComposerInputEditor(
                        text: $draft,
                        isFocused: isEditorFocused,
                        onSubmit: send,
                        onCompletionKey: handleMentionKey,
                        onFocusChanged: { isEditorFocused = $0 },
                        onCaretMoved: { _, _ in },
                        takePendingCaret: {
                            defer { pendingCaret = nil }
                            return pendingCaret
                        },
                        onTextChanged: { _, _ in mentionIndex = 0 },
                        onContentHeightChanged: { editorHeight = ComposerLayout.height(for: $0) }
                    )
                    .frame(height: max(1, editorHeight - 4))
                    if draft.isEmpty {
                        Text("Message the group — @ to mention a member")
                            .dockFont(.conversation, weight: .regular, design: DockThemeStyle.current.fontDesign)
                            .foregroundStyle(Color.dockSecondaryText)
                            .dockPadding(.leading, 16)
                            .allowsHitTesting(false)
                    }
                }
                .dockPadding(.top, 4)
                .frame(height: draft.isEmpty ? ComposerLayout.minHeight : editorHeight)
                .clipShape(DockThemeShape(cornerRadius: DockSkinPresentation.current.composerRadius, role: .pane))

                HStack(spacing: 8) {
                    Button {
                        showingInsertPopover = true
                    } label: {
                        DockIcon(.plus, size: 14, color: Color.dockSecondaryText)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                    .fill(DockSkinPresentation.current.composerControlFill))
                    }
                    .buttonStyle(.dockHover)
                    .help("Insert a snippet")
                    .dockPopover(isPresented: $showingInsertPopover, arrowEdge: .bottom) {
                        AttachmentPopover(
                            pasteImageAvailable: false,
                            onSelect: { _ in },
                            onSelectSnippet: {
                                draft = AttachmentPopoverPresentation.insertingSnippet($0, into: draft)
                                showingInsertPopover = false
                            },
                            actions: [.promptSnippets]
                        )
                    }
                    Button {
                        draft += (draft.isEmpty || draft.hasSuffix(" ") ? "@" : " @")
                        pendingCaret = (draft as NSString).length
                        isEditorFocused = true
                    } label: {
                        DockIcon(.at, size: 14, color: Color.dockSecondaryText)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                    .fill(DockSkinPresentation.current.composerControlFill))
                    }
                    .buttonStyle(.dockHover)
                    .help("Mention a member")
                    Spacer()
                    Button(action: isWorking ? { Task { await store.stop(roomID) } } : send) {
                        ZStack {
                            Circle()
                                .fill(isWorking ? Color.dockSurface6 : canSend ? Color.dockAccent : Color.dockSurface6)
                                .frame(width: 32, height: 32)
                            if store.pendingRooms.contains(roomID) {
                                ProgressView().controlSize(.small)
                            } else if isWorking && !canSend {
                                DockIcon(.stop, weight: .fill)
                                    .dockFont(.compactStatus, weight: .bold)
                                    .foregroundStyle(Color.dockDestructive)
                            } else {
                                DockIcon(.arrowUp)
                                    .dockFont(.body, weight: .semibold)
                                    .foregroundStyle(
                                        canSend ? Color.dockOnAccentText : Color.dockSecondaryText.opacity(0.5))
                            }
                        }
                    }
                    .buttonStyle(.dockHover)
                    .disabled(store.pendingRooms.contains(roomID) || (!isWorking && !canSend))
                    .help(isWorking && !canSend ? "Stop the room" : "Send")
                }
                .frame(height: 44)
            }
            .dockPadding(.leading, 6)
            .dockPadding(.trailing, 8)
            .dockPadding(.top, 6)
            .background {
                let shape = DockThemeShape(cornerRadius: DockSkinPresentation.current.composerRadius, role: .pane)
                shape
                    .dockInputFill()
                    .overlay {
                        shape.stroke(
                            isEditorFocused ? Color.dockAccent.opacity(0.42) : Color.dockBorder,
                            lineWidth: DockLayout.hairline)
                    }
            }
        }
        .dockPadding(.horizontal, metrics.composerInset)
        .dockPadding(.top, metrics.composerTopInset)
        .dockPadding(.bottom, metrics.composerBottomInset)
        .frame(maxWidth: metrics.composerMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        let text = draft
        guard !store.pendingRooms.contains(roomID), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        draft = ""
        let outgoing = replyQuote?.composing(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? text
        replyQuote = nil
        Task { await store.send(outgoing, to: roomID, thread: thread) }
    }
}
