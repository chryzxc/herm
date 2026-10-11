import AppKit
import SwiftUI

struct HermesPetView: View {
    @ObservedObject var pet: HermesPetModel
    var mirrored = false
    var poseOverride: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let sheet = pet.sheet, pet.visible {
                HermesPetSprite(sheet: sheet, pose: poseOverride ?? pet.pose, animates: !reduceMotion && pet.online && !pet.stale)
                    .aspectRatio(CGFloat(sheet.info.frameW ?? 1) / CGFloat(sheet.info.frameH ?? 1), contentMode: .fit)
                    .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                    .opacity(pet.online && !pet.stale ? 1 : 0.45)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct HermesPetSprite: NSViewRepresentable {
    let sheet: HermesPetSheet
    let pose: String
    let animates: Bool
    func makeNSView(context: Context) -> HermesPetSpriteView { HermesPetSpriteView() }
    func updateNSView(_ view: HermesPetSpriteView, context: Context) { view.configure(sheet, pose: pose, animates: animates) }
    static func dismantleNSView(_ view: HermesPetSpriteView, coordinator: ()) { view.stop() }
}

final class HermesPetSpriteView: NSView {
    private let sprite = CALayer()
    private var sheet: HermesPetSheet?
    private var pose = "idle"
    private var animates = false
    private var frameIndex = 0
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        sprite.contentsGravity = .resize
        layer?.addSublayer(sprite)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); sprite.frame = bounds }
    override func viewDidHide() { super.viewDidHide(); schedule() }
    override func viewDidUnhide() { super.viewDidUnhide(); schedule() }

    func configure(_ sheet: HermesPetSheet, pose: String, animates: Bool) {
        let changed = self.sheet?.image !== sheet.image || self.pose != pose || self.animates != animates
        self.sheet = sheet; self.pose = pose; self.animates = animates
        if changed { frameIndex = 0; drawFrame(); schedule() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        }
        schedule()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard animates, !isHiddenOrHasHiddenAncestor, window?.occlusionState.contains(.visible) == true, let sheet else { return }
        let count = sheet.info.frame(for: pose).count
        guard count > 1 else { return }
        let interval = max(0.016, Double(sheet.info.loopMs ?? 1100) / 1000 / Double(count))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.advanceFrame()
            }
        }
    }

    func advanceFrame() {
        guard let sheet else { return }
        frameIndex = (frameIndex + 1) % sheet.info.frame(for: pose).count
        drawFrame()
    }

    private func drawFrame() {
        guard let sheet else { return }
        let info = sheet.info
        let selected = info.frame(for: pose)
        let w = CGFloat(info.frameW ?? 1) / CGFloat(sheet.image.width)
        let h = CGFloat(info.frameH ?? 1) / CGFloat(sheet.image.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sprite.contents = sheet.image
        // Hermes rows are top-down; CALayer's normalized crop is bottom-up.
        // Using the row directly selects unrelated rows and their blank padding.
        sprite.contentsRect = CGRect(x: CGFloat(frameIndex % selected.count) * w,
                                     y: 1 - CGFloat(selected.row + 1) * h, width: w, height: h)
        CATransaction.commit()
    }
}

/// The child observes only pet state; transcript updates do not drive its animation.
struct HermesNotchPetButton: View {
    @ObservedObject var pet: HermesPetModel
    var mirrored = false
    var poseOverride: String? = nil
    var spriteSize = CGSize(width: 36, height: 40)
    var body: some View {
        if pet.visible {
            Button(action: pet.pet) {
                HermesPetView(pet: pet, mirrored: mirrored, poseOverride: poseOverride).frame(width: spriteSize.width, height: spriteSize.height)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .onHover { inside in if inside { pet.greet() } }
            .help("Pet \(pet.info.displayName ?? "your companion")")
            .accessibilityLabel("Pet \(pet.info.displayName ?? "your companion")")
        }
    }
}

struct HermesPetSettingsView: View {
    @ObservedObject var pet: HermesPetModel
    @State private var enabled = false
    @State private var slug = ""
    @State private var scale = 0.33
    @State private var query = ""
    @State private var dirty = false
    @State private var changedElsewhere = false
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Hermes companion").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Refresh") { pet.refresh(); Task { await pet.loadGallery() } }
                    .buttonStyle(.dockPress).disabled(pet.isLoading || !pet.online)
            }
            HStack(spacing: 12) {
                HermesPetView(pet: pet).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pet.info.displayName ?? "Choose a companion").font(.system(size: 12, weight: .semibold))
                    Text(pet.profileLabel).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { enabled }, set: { enabled = $0; dirty = true }))
                    .toggleStyle(.switch).controlSize(.small).fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Select a pet").font(.system(size: 12, weight: .semibold))
                TextField("Search pets", text: $query).textFieldStyle(.dockGlass)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if let gallery = pet.gallery {
                            let matches = gallery.matches(query)
                            ForEach(Array(matches.prefix(60))) { entry in
                                Button {
                                    slug = entry.slug; enabled = true; dirty = true
                                } label: {
                                    HermesPetGalleryRow(pet: pet, entry: entry, selected: slug == entry.slug)
                                }.buttonStyle(.dockHover)
                                    .accessibilityLabel("Select \(entry.displayName)")
                                    .accessibilityAddTraits(slug == entry.slug ? .isSelected : [])
                            }
                            if matches.isEmpty { Text("No companions found").font(.system(size: 12)) }
                        } else {
                            Text(pet.isLoading ? "Loading companions…" : "Gallery unavailable. Refresh to retry.").font(.system(size: 12))
                        }
                    }
                }.frame(height: 220)
                Text("Select a pet, then choose Apply to Hermes. Up to 60 matches shown; search to find more.")
                    .font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
            }
            HStack {
                Text("Pet size").font(.system(size: 12))
                Slider(value: Binding(get: { scale }, set: { scale = $0; dirty = true }), in: 0.1...3, step: 0.05)
                Text("\(Int(scale * 100))%").font(.system(size: 12).monospacedDigit()).frame(width: 44)
            }
            Text("Choose Apply to Hermes to save selection and size. Size scales the floating pet in Herm and is shared with Hermes Desktop and the TUI.")
                .font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
            Text("Only in Herm. Drag the pet away from the notch to let it roam; drag it back (or call it home from the notch menu) to attach it again. Reduce Motion keeps a free pet in place.")
                .font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
            HStack {
                Text(changedElsewhere ? "Changed in Hermes. Reload or apply your choices." : pet.galleryNotice ?? pet.notice ?? (pet.online ? "" : "Hermes is offline"))
                    .font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
                Spacer()
                if changedElsewhere { Button("Reload", action: reload).buttonStyle(.dockPress) }
            }.frame(minHeight: 30)
            Button(pet.isApplying ? "Applying…" : "Apply to Hermes") { confirming = true }
                .buttonStyle(.dockPrimary)
                .disabled(!dirty || pet.isApplying || !pet.online || (enabled && pet.gallery?.pets.contains(where: { $0.slug == slug }) != true))
        }
        .foregroundStyle(Color.dockPrimaryText)
        .disabled(pet.isApplying)
        .task { await pet.loadGallery(); if !dirty { reload() } }
        .onChange(of: pet.online) { _, connected in if connected { Task { await pet.loadGallery() } } }
        .onChange(of: pet.revision) { _, _ in if dirty { changedElsewhere = true } else { reload() } }
        .onChange(of: pet.profile) { _, _ in dirty = false; query = ""; reload(); Task { await pet.loadGallery() } }
        .confirmationDialog("Apply companion changes to \(pet.profileLabel)?", isPresented: $confirming) {
            Button("Apply to Hermes") {
                Task { await pet.apply(enabled: enabled, slug: slug, scale: scale); reload() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes the companion in Hermes Desktop and the TUI too. A companion that is not installed may be downloaded by Hermes.")
        }
    }

    private func reload() {
        enabled = pet.info.enabled
        slug = pet.info.slug ?? pet.gallery?.active ?? ""
        scale = pet.info.scale ?? 0.33
        dirty = false; changedElsewhere = false
    }
}

private struct HermesPetGalleryRow: View {
    let pet: HermesPetModel
    let entry: HermesPetGallery.Entry
    let selected: Bool
    @State private var thumbnail: NSImage?
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else { Text(String(entry.displayName.prefix(1))).font(.system(size: 12, weight: .semibold)) }
            }.frame(width: 36, height: 36)
            Text(entry.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer()
            Text(selected ? "Selected" : entry.installed ? "Installed" : "Download").font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
        }.padding(6).background(selected ? Color.dockAccentMuted : Color.clear)
            .contentShape(Rectangle())
            .task(id: entry.slug) { thumbnail = await pet.thumbnail(entry) }
    }
}
