import AppKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import Testing
@testable import Herm

struct HermesPetTests {
    @MainActor @Test func floatingPetHonorsSavedScaleAndScreenBounds() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        var info = HermesPetInfo(enabled: true, frameW: 192, frameH: 208, scale: 1)
        #expect(HermesPetWindow.spriteSize(info: info, screen: screen) == CGSize(width: 192, height: 208))
        info.scale = 3
        let size = HermesPetWindow.spriteSize(info: info, screen: screen)
        #expect(size == CGSize(width: 576, height: 624))
        #expect(HermesPetWindow.clamped(NSPoint(x: 1400, y: 800), to: screen, size: size) == NSPoint(x: 864, y: 276))
    }

    @Test func notchAnnouncementsUseCentralPetReactions() {
        #expect(HermesPetReaction.announcement(activity: .init(), quota: true) == .quota)
        #expect(HermesPetReaction.announcement(activity: .init(status: .needsApproval), quota: false) == .attention)
        #expect(HermesPetReaction.announcement(activity: .init(status: .working), quota: false) == .working)
        #expect(HermesPetReaction.announcement(activity: .init(responseCompleted: true), quota: false) == .update)
        #expect(HermesPetReaction.announcement(activity: .init(), quota: false) == .update)
        #expect(Set(HermesPetReaction.allCases.map(\.pose)).isSubset(of: Set(["idle", "run", "review", "waiting", "wave", "failed", "jump"])))
    }

    @MainActor @Test func remoteCatalogFailureRetainsInstalledPets() async {
        let client = PetRecordingClient()
        client.localGalleryOnly = true
        client.result = ["enabled": true, "active": "nukey", "pets": [
            ["slug": "nukey", "displayName": "Nukey", "installed": true]
        ]]
        let pet = HermesPetModel()
        await pet.readGallery(HermesPetService(client: client, profile: "default"))
        #expect(pet.gallery?.pets.first?.slug == "nukey")
        #expect(pet.galleryNotice?.contains("Online catalog unavailable") == true)
        #expect(!pet.isLoading)
    }

    @Test func downloadedPublicCatalogRemainsSelectable() throws {
        guard let path = ProcessInfo.processInfo.environment["HERM_PET_MANIFEST"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(manifest["pets"] as? [[String: Any]])
        let rows = entries.map { entry in
            var row = entry; row["installed"] = false; return row
        }
        let gallery = try HermesPetGallery.decode(["enabled": true, "active": "nukey", "pets": rows])
        #expect(gallery.pets.count > 4000)
        #expect(!gallery.matches("").isEmpty)
    }
    @Test func invalidCommunityLabelDoesNotHideOtherPets() throws {
        let gallery = try HermesPetGallery.decode(["enabled": true, "active": "nukey", "pets": [
            ["slug": "nukey", "displayName": "Nukey", "installed": true],
            ["slug": "bad", "displayName": "Name\u{200C}", "installed": false],
            ["slug": "cat", "displayName": "Cat", "installed": false]
        ]])
        #expect(gallery.pets.map(\.slug) == ["nukey", "cat"])
    }

    @MainActor @Test func roamingCrossesTheDisplayInsteadOfPacingNearHome() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let target = HermesPetWindow.strollTarget(from: NSPoint(x: 1396, y: 400), screen: screen, fraction: 1)
        #expect(target.x == 0)
        #expect(target.y == 8)
        let next = HermesPetWindow.strollTarget(from: target, screen: screen, fraction: 0)
        #expect(next.x > 600)
        #expect(next.x < screen.maxX - 44)
    }

    @MainActor @Test func roamingStaysOnItsHomeDisplay() {
        let screen = NSRect(x: -1200, y: 60, width: 1200, height: 800)
        #expect(HermesPetWindow.clamped(NSPoint(x: 100, y: -200), to: screen) == NSPoint(x: -44, y: 60))
        #expect(HermesPetWindow.clamped(NSPoint(x: -1400, y: 1000), to: screen) == NSPoint(x: -1200, y: 816))
        #expect(HermesPetWindow.clamped(NSPoint(x: -500, y: 300), to: screen) == NSPoint(x: -500, y: 300))
    }
    @MainActor @Test func livePoseResumesAfterInteraction() {
        #expect(HermesPetModel.activityPose(online: true, attention: false, working: true, tool: true, reasoning: false, beat: "jump") == "jump")
        #expect(HermesPetModel.activityPose(online: true, attention: false, working: true, tool: true, reasoning: false, beat: nil) == "run")
        #expect(HermesPetModel.activityPose(online: true, attention: true, working: true, tool: true, reasoning: false, beat: nil) == "waiting")
        #expect(HermesPetModel.activityPose(online: true, attention: false, working: false, tool: false, reasoning: false, beat: "failed") == "failed")
    }

    @MainActor @Test func petHoverDoesNotOpenNotch() {
        let host = EdgeDockHostingView(rootView: Text("Test"))
        host.frame = CGRect(x: 0, y: 0, width: 44, height: 120)
        host.bottomHoverExclusion = EdgeNotchState.petFootprint
        let petY: CGFloat = host.isFlipped ? 100 : 20
        let notchY: CGFloat = host.isFlipped ? 20 : 100
        #expect(!host.notchHoverContains(NSPoint(x: 22, y: petY)))
        #expect(host.notchHoverContains(NSPoint(x: 22, y: notchY)))
        host.bottomHoverExclusion = 0
        #expect(host.notchHoverContains(NSPoint(x: 22, y: petY)))
    }

    @MainActor @Test func spriteRemainsVisibleAcrossFramesAndLayoutUpdates() throws {
        // Two opaque frames in the top row, transparent padding below.
        // A vertically inverted crop disappears even though the requested row is populated.
        let source = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 16, width: 32, height: 16))
        let sheet = HermesPetSheet(image: try #require(source.makeImage()), info: HermesPetInfo(
            enabled: true, frameW: 16, frameH: 16, framesPerState: 2, loopMs: 1100, stateRows: ["idle", "wave"]))
        let view = HermesPetSpriteView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.configure(sheet, pose: "idle", animates: false)
        view.layoutSubtreeIfNeeded()
        let layer = try #require(view.layer?.sublayers?.first)
        for _ in 0..<12 {
            view.advanceFrame()
            view.configure(sheet, pose: "idle", animates: false)
            view.layout()
            let context = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
                bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            layer.render(in: context)
            let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            #expect(pixel[(20 * 40 + 20) * 4 + 3] == 255)
        }
    }

    @Test func disabledAndAdditiveContracts() throws {
        #expect(try !HermesPetInfo.decode(["enabled": false]).enabled)
        let info = try HermesPetInfo.decode(["enabled": true, "slug": "cat", "displayName": "Cat", "scale": 0.33, "future": true])
        #expect(info.slug == "cat")
        #expect(throws: (any Error).self) { try HermesPetInfo.decode(["enabled": true, "scale": 10]) }
        #expect(throws: (any Error).self) { try HermesPetInfo.decode(["enabled": true, "displayName": "bad\nname"]) }
    }

    @Test func spriteAliasesAndRaggedRows() {
        var info = HermesPetInfo(enabled: true, framesPerState: 6, framesByState: ["run": 4], stateRows: HermesPetInfo.defaultRows)
        #expect(info.frame(for: "run").row == 7)
        #expect(info.frame(for: "run").count == 4)
        #expect(info.frame(for: "wave").row == 3)
        info.framesByRow = ["running": 0, "idle": 2]
        #expect(info.frame(for: "run").row == 0)
        #expect(info.frame(for: "run").count == 2)
        info.stateRows = ["idle", "wave", "run", "failed", "review", "jump", "extra1", "extra2"]
        #expect(info.frame(for: "wave").row == 1)
        #expect(info.frame(for: "waiting").row == 0)
    }

    @Test func galleryRankingSearchAndDuplicateRejection() throws {
        let raw: [String: Any] = ["enabled": true, "active": "cat", "pets": [
            ["slug": "dog", "displayName": "Dog", "installed": false],
            ["slug": "fox", "displayName": "Fox", "installed": true],
            ["slug": "cat", "displayName": "Cat", "installed": true]
        ]]
        let gallery = try HermesPetGallery.decode(raw)
        #expect(gallery.matches("").map(\.slug) == ["cat", "fox", "dog"])
        #expect(gallery.matches("FOX").map(\.slug) == ["fox"])
        let duplicate: [String: Any] = ["enabled": false, "active": "", "pets": [
            ["slug": "cat", "displayName": "Cat", "installed": true],
            ["slug": "cat", "displayName": "Cat", "installed": true]
        ]]
        #expect(throws: (any Error).self) { try HermesPetGallery.decode(duplicate) }
    }

    @MainActor @Test func companionReactsLocallyAndReturnsToIdle() async throws {
        let client = PetRecordingClient(); client.result = try Self.atlas()
        let pet = HermesPetModel()
        try await pet.readInfo(HermesPetService(client: client, profile: nil), generation: 0)
        #expect(pet.pose == "idle")
        pet.greet()
        #expect(pet.pose == (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "idle" : "wave"))
        pet.pet()
        #expect(pet.pose == (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "idle" : "jump"))
        // Repeated hover does not interrupt an explicit petting reaction.
        pet.greet()
        #expect(pet.pose == (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "idle" : "jump"))
        try await Task.sleep(for: .milliseconds(1800))
        // The full suite can occupy the main actor past both timer deadlines;
        // let the reaction task resume rather than depending on wake-up order.
        for _ in 0..<100 {
            if pet.pose == "idle" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pet.pose == "idle")
        #expect(client.method == "pet.info")
    }

    @Test func rejectsInvalidImageBeforeRendering() {
        #expect(throws: (any Error).self) { try HermesPetSheet.decode(HermesPetInfo(enabled: true, mime: "text/html", spritesheetBase64: "PHNjcmlwdD4=")) }
    }

    static func atlas() throws -> [String: Any] {
        let context = try #require(CGContext(data: nil, width: 16, height: 18, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 18))
        let image = try #require(context.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return ["enabled": true, "slug": "test-pet", "displayName": "Test companion", "mime": "image/png",
                "spritesheetBase64": (bytes as Data).base64EncodedString(), "spritesheetRevision": "revision-1",
                "frameW": 2, "frameH": 2, "framesPerState": 6, "loopMs": 1100,
                "framesByRow": ["running-right": 8], "stateRows": HermesPetInfo.defaultRows, "scale": 0.33]
    }

    @Test func validatesAtlasGeometryAgainstActualImage() throws {
        let raw = try Self.atlas()
        let sheet = try HermesPetSheet.decode(HermesPetInfo.decode(raw))
        #expect(sheet.image.width == 16)
        #expect(sheet.info.spritesheetBase64 == nil)
        var invalid = raw
        invalid["frameW"] = 200
        #expect(throws: (any Error).self) { try HermesPetSheet.decode(HermesPetInfo.decode(invalid)) }
        invalid = raw; invalid["framesByRow"] = ["idle": 100]
        #expect(throws: (any Error).self) { try HermesPetSheet.decode(HermesPetInfo.decode(invalid)) }
    }

    @MainActor @Test func unchangedMetadataReusesImageAndDisableClearsIt() async throws {
        let client = PetRecordingClient()
        client.result = try Self.atlas()
        let service = HermesPetService(client: client, profile: "work")
        let model = HermesPetModel()
        try await model.readInfo(service, generation: 0)
        let image = try #require(model.sheet?.image)
        client.result = ["enabled": true, "slug": "test-pet", "displayName": "Renamed", "scale": 0.5, "spritesheetRevision": "revision-1"]
        try await model.readInfo(service, generation: 0)
        #expect(client.method == "pet.info.meta")
        #expect(model.sheet?.image === image)
        #expect(model.info.displayName == "Renamed")
        #expect(model.info.scale == 0.5)
        client.result = ["enabled": false]
        try await model.readInfo(service, generation: 0)
        #expect(!model.visible)
        #expect(model.sheet == nil)
    }

    @MainActor @Test func obsoleteProfileResponseDoesNotPublish() async throws {
        let client = PetRecordingClient()
        client.result = try Self.atlas()
        let model = HermesPetModel()
        try await model.readInfo(HermesPetService(client: client, profile: "old"), generation: -1)
        #expect(model.sheet == nil)
        #expect(!model.info.enabled)
    }

    @MainActor @Test func petFitsBelowTheCollapsedNotch() {
        let state = EdgeNotchState()
        #expect(state.railHeight == 96)
        state.hasPet = true
        #expect(state.railHeight == 96)
        #expect(state.panelHeight == 144)
        #expect(state.railWidth == 56)
        state.expanded = true
        #expect(state.railHeight == 136)
        #expect(state.panelHeight == 408)
    }

    @MainActor @Test func profileResetRetainsRecoverableDraftWithoutChangingPreviewTab() {
        let state = EdgeNotchState()
        state.showsQuota = true; state.quickDraft = "Previous profile draft"
        state.composing = true; state.quickSending = true
        state.resetQuickComposition()
        #expect(state.quickDraft == "Previous profile draft")
        state.quickSending = false
        state.resetQuickComposition()
        #expect(state.quickDraft.isEmpty)
        #expect(!state.composing)
        #expect(state.showsQuota)
        state.selectQuickTarget(nil)
        #expect(state.quickDraft == "Previous profile draft")
        #expect(state.recoverableDrafts.count == 1)
    }

    @MainActor @Test func everyPetRequestCarriesItsProfileAndExactParameters() async throws {
        let client = PetRecordingClient()
        let service = HermesPetService(client: client, profile: "work")
        for method: HermesFeatureIDs.ID in [.petInfo, .petInfoMeta, .petGallery, .petThumb, .petSelect, .petDisable, .petScale] {
            _ = try await service.request(method, ["slug": "cat", "scale": 0.4, "knownRevision": "r1"])
            #expect(client.method == method.rawValue)
            #expect(client.params["profile"] as? String == "work")
            #expect(client.params["knownRevision"] as? String == "r1")
            #expect(client.params["scale"] as? Double == 0.4)
        }
        client.result = ["ok": false]
        await #expect(throws: (any Error).self) { _ = try await service.request(.petSelect, ["slug": "cat"]) }
    }

    /// Opt-in visual check with the user's installed atlas; never calls or mutates Hermes.
    @MainActor @Test func renderPetNotch() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_PET_SNAPSHOT_DIR"],
              let path = ProcessInfo.processInfo.environment["HERM_PET_SHEET"] else { return }
        var raw = try Self.atlas()
        raw["spritesheetBase64"] = try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()
        raw["mime"] = "image/webp"; raw["frameW"] = 192; raw["frameH"] = 208
        raw["framesByRow"] = [String: Int]()
        let control = ControlCenterModel()
        let client = PetRecordingClient(); client.result = raw
        try await control.pet.readInfo(HermesPetService(client: client, profile: nil), generation: 0)
        for name in ["rail-left", "rail-right", "preview", "quota"] {
            let state = EdgeNotchState()
            state.hasPet = control.pet.visible
            state.side = name == "rail-left" ? .left : .right
            state.expanded = name == "preview" || name == "quota"
            state.showsQuota = name == "quota"
            let size = CGSize(width: state.expanded ? EdgeNotchState.expandedSize.width : state.railWidth, height: state.panelHeight)
            let view = EdgeNotchView(state: state, controlCenter: control, openDock: {}).frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}

@MainActor
private final class PetRecordingClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var method = ""
    var params: [String: Any] = [:]
    var result: [String: Any] = ["ok": true]
    var localGalleryOnly = false
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        self.method = method; self.params = params
        if localGalleryOnly && params["localOnly"] as? Bool != true { throw HermesPetError.invalidResponse }
        return result
    }
}
