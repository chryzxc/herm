import AppKit
import Combine
import ImageIO

/// The cached image is immutable and decoded on a worker before publication.
struct HermesPetSheet: @unchecked Sendable {
    let image: CGImage
    let info: HermesPetInfo

    static func decode(_ info: HermesPetInfo) throws -> Self {
        guard let encoded = info.spritesheetBase64, encoded.utf8.count <= 44 * 1024 * 1024,
            ["image/png", "image/webp"].contains(info.mime ?? "image/webp"),
            let data = Data(base64Encoded: encoded), data.count <= 32 * 1024 * 1024,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 8 * 1024 * 1024,
            let frameW = info.frameW, let frameH = info.frameH,
            frameW > 0, frameH > 0, frameW <= width, frameH <= height,
            let frames = info.framesPerState, frames > 0, frames <= width / frameW,
            let loop = info.loopMs, (100...60_000).contains(loop),
            let rows = info.stateRows, !rows.isEmpty, rows.count <= height / frameH,
            rows.contains("idle"), Set(rows).count == rows.count,
            (info.framesByRow ?? [:]).values.allSatisfy({ $0 >= 0 && $0 <= width / frameW }),
            (info.framesByState ?? [:]).values.allSatisfy({ $0 >= 0 && $0 <= width / frameW }),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw HermesPetError.invalidImage }
        var metadata = info
        metadata.spritesheetBase64 = nil
        return Self(image: image, info: metadata)
    }
}

@MainActor
final class HermesPetModel: ObservableObject {
    @Published private(set) var sheet: HermesPetSheet?
    @Published private(set) var info = HermesPetInfo(enabled: false)
    @Published private(set) var gallery: HermesPetGallery?
    @Published private(set) var galleryNotice: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var notice: String?
    @Published private(set) var stale = false
    @Published private(set) var online = false
    @Published private(set) var pose = "idle"
    @Published private(set) var profile: String?
    @Published private(set) var revision = 0
    private weak var dock: DockModel?
    private var subscriptions = Set<AnyCancellable>()
    private var eventID: UUID?
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    private var beatTask: Task<Void, Never>?
    private var beat: String?
    private var notchWorking = false
    private var notchAttention = false
    private var thumbnailCache: [String: NSImage] = [:]
    private var thumbnailsLoading = Set<String>()

    var visible: Bool { info.enabled && sheet != nil }
    var profileLabel: String { profile ?? "Default profile" }

    func bind(to model: DockModel) {
        guard dock !== model else { return }
        if let eventID { dock?.eventRouter.unsubscribe(eventID) }
        subscriptions.removeAll()
        dock = model
        model.$profileScopeID.receive(on: RunLoop.main).sink { [weak self] profile in
            guard let self else { return }
            self.generation += 1
            self.refreshTask?.cancel()
            self.refreshTask = nil
            self.beatTask?.cancel()
            self.beat = nil
            self.notchWorking = false
            self.notchAttention = false
            self.profile = profile
            self.sheet = nil
            self.info = HermesPetInfo(enabled: false)
            self.gallery = nil
            self.galleryNotice = nil
            self.thumbnailCache = [:]
            self.thumbnailsLoading = []
            self.notice = nil
            self.isLoading = false
            self.isApplying = false
            self.revision += 1
            self.refresh()
        }.store(in: &subscriptions)
        model.$isHermesConnected.receive(on: RunLoop.main).sink { [weak self] connected in
            guard let self else { return }
            self.online = connected
            if connected {
                self.refresh()
            } else {
                self.generation += 1
                self.refreshTask?.cancel()
                self.refreshTask = nil
                self.isLoading = false
                self.isApplying = false
                self.stale = true
            }
            self.updatePose()
        }.store(in: &subscriptions)
        Publishers.Merge3(
            model.$status.map { _ in () }, model.$activityPresentationRevision.map { _ in () },
            model.$backgroundTasks.map { _ in () }
        )
        .receive(on: RunLoop.main).sink { [weak self] in self?.updatePose() }.store(in: &subscriptions)
        eventID = model.eventRouter.subscribe { [weak self, weak model] type, params in
            guard let self, let model else { return }
            // Change events need not identify a profile; re-read the selected profile.
            if type == "pet.changed" { self.refresh() }
            if type == "message.complete" {
                let payload = params["payload"] as? [String: Any] ?? [:]
                let session = params["session_id"] as? String ?? payload["session_id"] as? String
                guard session.map(model.currentSessionIDs.contains) == true else { return }
                if DockModel.messageCompletionError(from: payload) != nil { self.react(.failed) }
            }
        }
        Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }.store(
            in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.refresh()
        }.store(in: &subscriptions)
    }

    private func updatePose() {
        let next =
            visible
            ? Self.activityPose(
                online: online && !stale,
                attention: notchAttention || dock?.status == .needsApproval || dock?.status == .needsClarification,
                working: notchWorking || dock?.status == .working
                    || dock?.backgroundTasks.contains { $0.status == .running } == true,
                tool: dock?.activeToolCalls.contains { !$0.isComplete } == true,
                reasoning: dock?.reasoningState?.isComplete == false, beat: beat) : "idle"
        if pose != next { pose = next }
    }

    static func activityPose(online: Bool, attention: Bool, working: Bool, tool: Bool, reasoning: Bool, beat: String?)
        -> String
    {
        // Direct interactions are short-lived; afterwards the live pose resumes.
        if let beat { return beat }
        guard online else { return HermesPetReaction.idle.pose }
        if attention { return HermesPetReaction.attention.pose }
        if working { return (reasoning && !tool ? HermesPetReaction.thinking : .working).pose }
        return HermesPetReaction.idle.pose
    }

    func updateNotchActivity(working: Bool, attention: Bool) {
        guard notchWorking != working || notchAttention != attention else { return }
        notchWorking = working
        notchAttention = attention
        updatePose()
    }

    func greet() { if beat == nil { react(.greeting) } }
    func pet() { react(.petting) }
    func react(_ reaction: HermesPetReaction) { flash(reaction.pose) }

    private func flash(_ value: String) {
        guard visible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        beatTask?.cancel()
        beat = value
        updatePose()
        beatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            self?.beat = nil
            self?.updatePose()
        }
    }

    func refresh() {
        guard online, !isApplying, refreshTask == nil, let dock, !dock.profileScopeUnavailable else { return }
        let service = HermesPetService(client: dock.controlRPCClient, profile: profile)
        let generation = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.refreshTask = nil } }
            do { try await self.readInfo(service, generation: generation) } catch {
                if self.generation == generation {
                    self.stale = true
                    self.notice = "Herm companion unavailable. Reconnect or update Hermes, then retry."
                    self.updatePose()
                }
            }
        }
    }

    func readInfo(_ service: HermesPetService, generation: Int) async throws {
        var params: [String: Any] = [:]
        if let revision = info.spritesheetRevision, sheet != nil { params["knownRevision"] = revision }
        if sheet != nil, let raw = try? await service.request(.petInfoMeta) {
            let meta = try HermesPetInfo.decode(raw)
            guard self.generation == generation else { return }
            if !meta.enabled {
                publish(meta, sheet: nil)
                return
            }
            if let revision = info.spritesheetRevision, !revision.isEmpty,
                meta.slug == info.slug, meta.spritesheetRevision == revision
            {
                var next = info
                next.displayName = meta.displayName
                next.scale = meta.scale
                publish(next, sheet: sheet)
                return
            }
            params = [:]
        }
        var next = try HermesPetInfo.decode(try await service.request(.petInfo, params))
        guard self.generation == generation else { return }
        if !next.enabled {
            publish(next, sheet: nil)
            return
        }
        if next.spritesheetUnchanged == true, next.slug == info.slug,
            next.spritesheetRevision == info.spritesheetRevision, let sheet
        {
            next.spritesheetBase64 = nil
            publish(next, sheet: sheet)
            return
        }
        let input = next
        let decoded = try await Task.detached(priority: .utility) { try HermesPetSheet.decode(input) }.value
        guard self.generation == generation else { return }
        next.spritesheetBase64 = nil
        publish(next, sheet: decoded)
    }

    private func publish(_ next: HermesPetInfo, sheet: HermesPetSheet?) {
        let changed = info != next
        info = next
        self.sheet = sheet
        stale = false
        notice = nil
        if changed { revision += 1 }
        updatePose()
    }

    func loadGallery() async {
        guard online, !isLoading, let dock else { return }
        await readGallery(HermesPetService(client: dock.controlRPCClient, profile: profile))
    }

    func readGallery(_ service: HermesPetService) async {
        isLoading = true
        galleryNotice = nil
        let generation = generation
        defer { if self.generation == generation { isLoading = false } }
        do {
            let local = try HermesPetGallery.decode(try await service.request(.petGallery, ["localOnly": true]))
            guard self.generation == generation else { return }
            if gallery == nil { gallery = local }
        } catch {
            guard self.generation == generation else { return }
        }
        do {
            let next = try HermesPetGallery.decode(try await service.request(.petGallery))
            guard self.generation == generation else { return }
            gallery = next
            if !stale { notice = nil }
        } catch {
            if self.generation == generation {
                galleryNotice =
                    gallery == nil
                    ? "Pet gallery unavailable. Refresh to retry."
                    : "Online catalog unavailable. Showing cached or installed pets; refresh to retry."
            }
        }
    }

    func thumbnail(_ entry: HermesPetGallery.Entry) async -> NSImage? {
        if let cached = thumbnailCache[entry.slug] { return cached }
        guard online, let dock, !thumbnailsLoading.contains(entry.slug) else { return nil }
        let generation = generation
        thumbnailsLoading.insert(entry.slug)
        defer { if self.generation == generation { thumbnailsLoading.remove(entry.slug) } }
        let service = HermesPetService(client: dock.controlRPCClient, profile: profile)
        guard
            let result = try? await service.request(
                .petThumb, ["slug": entry.slug, "url": entry.spritesheetUrl ?? ""]),
            let uri = result["dataUri"] as? String, uri.hasPrefix("data:image/png;base64,"),
            uri.count <= 2 * 1024 * 1024,
            let data = Data(base64Encoded: String(uri.dropFirst("data:image/png;base64,".count))),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...2048).contains(width), (1...2048).contains(height),
            // Decode once at row size so scrolling never decodes a full sprite sheet on the main thread.
            let cg = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 72,
                ] as CFDictionary),
            self.generation == generation
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if thumbnailCache.count >= 120 { thumbnailCache.removeAll() }
        thumbnailCache[entry.slug] = image
        return image
    }

    func apply(enabled: Bool, slug: String, scale: Double) async {
        guard online, !isApplying, let dock, scale.isFinite, (0.1...3).contains(scale),
            !enabled || gallery?.pets.contains(where: { $0.slug == slug }) == true
        else { return }
        refreshTask?.cancel()
        refreshTask = nil
        self.generation += 1
        isLoading = false
        isApplying = true
        notice = nil
        let generation = generation
        let service = HermesPetService(client: dock.controlRPCClient, profile: profile)
        defer { if self.generation == generation { isApplying = false } }
        var failed = false
        do {
            if enabled {
                _ = try await service.request(.petSelect, ["slug": slug])
                guard self.generation == generation else { return }
                _ = try await service.request(.petScale, ["scale": scale])
            } else {
                _ = try await service.request(.petDisable)
            }
        } catch { failed = true }
        guard self.generation == generation else { return }
        do { try await readInfo(service, generation: generation) } catch { stale = true }
        await loadGallery()
        guard self.generation == generation else { return }
        if failed {
            notice = "Hermes could not apply all companion changes. Reload the current settings before retrying."
        }
    }
}
