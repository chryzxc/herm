import AppKit
import SwiftUI
import Testing

@testable import Herm

/// Env-gated renders of generated surfaces in chat and in the hands-free voice glance.
@MainActor
struct GenerativeUIRenderTests {
    static let memory =
        "Here it is.\n```herm-ui\n"
        + #"{"version":2,"id":"mem","title":"Mac memory snapshot","fallback":"54% free of 24 GiB","kind":"native","metadata":{"source":"vm_stat","observedAt":"Nov 19, 1:25 PM"},"#
        + #""datasets":[{"id":"m","columns":[{"id":"k","title":"Kind","type":"text"},{"id":"v","title":"Share","type":"number","unit":"%"}],"rows":[{"id":"a","values":["App","28"]},{"id":"w","values":["Wired","12"]},{"id":"c","values":["Compressed","6"]},{"id":"f","values":["Free","54"]}]}],"#
        + #""blocks":[{"id":"totals","type":"metrics","payload":{"items":[{"id":"phys","label":"Physical memory","value":"24","unit":"GiB"},{"id":"free","label":"Free","value":"54","unit":"%","comparison":"System-wide"},{"id":"swap","label":"Swap used","value":"0","unit":"MB"}]}},"#
        + #"{"id":"chart","type":"chart","payload":{"dataset":"m","label":"k","series":["v"],"style":"bar"}},"#
        + #"{"id":"table","type":"table","payload":{"dataset":"m"}},"#
        + #"{"type":"text","text":"Physical memory: 24 GiB. Checked November 19 at 1:25 p.m."}]}"#
        + "\n```"
    static let plan =
        "```herm-ui\n"
        + #"{"version":2,"id":"plan","title":"Release plan","fallback":"Plan","kind":"native","blocks":["#
        + #"{"id":"opts","type":"comparison","payload":{"criteria":["Cost","Speed"],"options":[{"id":"a","title":"Hosted","values":["$12/mo","Fast"],"detail":"Managed"},{"id":"b","title":"Self-hosted","values":["$4/mo","Medium"]}]}},"#
        + #"{"id":"tl","type":"timeline","payload":{"items":[{"id":"1","title":"Freeze","date":"2026-11-20"},{"id":"2","title":"QA pass","date":"2026-11-22","dependencies":["1"]},{"id":"3","title":"Ship","date":"2026-11-24"}]}},"#
        + #"{"id":"wf","type":"workflow","payload":{"items":[{"id":"b","title":"Build","status":"passed","evidence":"exit 0"},{"id":"t","title":"Tests","status":"failed","evidence":"3 failures"},{"id":"r","title":"Review","status":"proposed","detail":"Inspect the diff."}]}},"#
        + #"{"id":"f","type":"findings","payload":{"items":[{"id":"x","title":"Missing failure coverage","severity":"warning","detail":"Only success is tested.","location":"Tests/A.swift","recommendation":"Cover an unavailable response."}]}},"#
        + #"{"id":"code","type":"code","payload":{"language":"sh","filename":"Check","code":"swift test --filter A"}}]}"#
        + "\n```"

    @Test func renderGeneratedSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_GENUI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let savedTheme = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
        }
        for (raw, dark) in [("glass", true), ("clean", false)] {
            DockThemeRuntime.current = try #require(DockThemeID(rawValue: raw))
            DockThemeRuntime.revision &+= 1
            for (name, text) in [("memory", Self.memory), ("plan", Self.plan)] {
                let chat = GenerativeUIIntegration.renderReply(text, enabled: true) { Text(text) }
                    .padding(16).background(Color.dockCanvas)
                try await capture(chat, dark: dark, root: root, name: "chat-\(name)-\(raw)", width: 600)
            }
        }
        DockThemeRuntime.current = try #require(DockThemeID(rawValue: "glass"))
        DockThemeRuntime.revision &+= 1
        for (name, text) in [("memory", Self.memory), ("plan", Self.plan)] {
            let glance = GenerativeUIIntegration.renderReply(text, enabled: true, visualsOnly: true) { EmptyView() }
                .environment(\.richGlance, true).dockThemedRoot(surface: .cameraNotch)
                .padding(20).background(Color.black.opacity(0.85))
            try await capture(glance, dark: true, root: root, name: "glance-\(name)", width: 640)
        }
    }

    @Test func renderVoicePreviewControlsAtPanelWidths() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_GENUI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let savedTheme = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
        }
        let model = DockModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, loadArchives: false)
        defer { model.shutdown() }
        let table = try #require(
            VoicePassiveVisual.table(
                title: "Tomorrow’s agenda", columns: ["Time", "Event"],
                rows: (8...21).map { ["\($0):00", $0 == 15 ? "Sprint review and follow-ups" : "Time block"] }))
        let comparison = """
            ```herm-ui
            {"version":2,"id":"routes","title":"Travel options","fallback":"Four routes","kind":"native","blocks":[
            {"type":"comparison","id":"options","payload":{"criteria":["Typical fare","Travel time"],"options":[
            {"id":"a","title":"Direct regional train","values":["$30 per person","55 minutes"]},
            {"id":"b","title":"Express airport shuttle","values":["$42 per person","40 minutes"]},
            {"id":"c","title":"Shared neighborhood van","values":["$24 per person","70 minutes"]},
            {"id":"d","title":"Airport waterfront ferry","values":["$18 per person","90 minutes"]}]}}]}
            ```
            """
        let generated = ChatMessage(role: .hermes, text: comparison)
        let agenda = ChatMessage(role: .hermes, text: table)
        for (theme, dark, width) in [(DockThemeID.island, true, 600.0), (.clean, false, 372.0)] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for (name, message, position) in [
                ("agenda", agenda, RichVoicePreview.Position(page: 1, row: 7)),
                ("comparison", generated, RichVoicePreview.Position(option: 3)),
            ] {
                model.voiceStage.previewNavigation = .init(messageID: message.id)
                let card = VoiceGenerativeCard(
                    model: model, message: message, maxWidth: width - 36, floating: false, maxHeight: 360
                )
                .padding(18).background(Color.dockCanvas)
                try await capture(card, dark: dark, root: root, name: "voice-\(name)-\(Int(width))", width: width) {
                    model.voiceStage.previewNavigation = .init(messageID: message.id, position: position)
                }
            }
        }
    }

    @Test(arguments: [4, 48])
    func voiceCodeScrollsAtNotchWidth(lineCount: Int) async throws {
        let key = GenerativeUIIntegration.preferenceKey
        let savedPreference = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(savedPreference, forKey: key) }
        let model = DockModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, loadArchives: false)
        defer { model.shutdown() }
        let line = "FEATURE_FLAGS=" + String(repeating: "sample-flag,", count: 20)
        let code = (1...lineCount).map { "\($0) \(line)" }.joined(separator: "\n")
        let surface = RichSurface(
            version: 2, id: "scroll-preview", title: "Configuration example", fallback: "Example settings",
            kind: .native,
            blocks: [
                RichBlock(
                    type: .code, id: "file",
                    payload: .code(
                        .init(
                            code: code, language: "dotenv", filename: "settings.example")))
            ])
        let message = ChatMessage(
            role: .hermes,
            text: "~~~herm-ui\n" + String(decoding: try JSONEncoder().encode(surface), as: UTF8.self) + "\n~~~")
        let host = EdgeDockHostingView(
            rootView: VoiceGenerativeCard(
                model: model, message: message, maxWidth: 372, floating: false, maxHeight: 240
            )
            .frame(width: 372)
            .dockThemedRoot(surface: .cameraNotch))
        host.sizingOptions = []
        let frame = NSRect(x: 0, y: 0, width: 372, height: 240)
        host.frame = frame
        let window = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }

        func scrollViews(in view: NSView) -> [NSScrollView] {
            [view as? NSScrollView].compactMap { $0 } + view.subviews.flatMap { scrollViews(in: $0) }
        }
        let vertical = try #require(scrollViews(in: host).first)
        let horizontal = try #require(scrollViews(in: vertical).dropFirst().first)
        #expect(horizontal.documentVisibleRect.width < (horizontal.documentView?.frame.width ?? 0))
        let overflowsVertically = (vertical.documentView?.frame.height ?? 0) > vertical.documentVisibleRect.height + 1
        #expect(overflowsVertically == (lineCount > 4))

        let visibleCode = horizontal.convert(horizontal.bounds, to: vertical).intersection(vertical.bounds)
        let point = vertical.convert(NSPoint(x: visibleCode.midX, y: visibleCode.midY), to: host.superview)
        let target = try #require(host.hitTest(point))
        func wheel(vertical: Int32, horizontal: Int32) throws -> NSEvent {
            try #require(
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal,
                    wheel3: 0
                ).flatMap(NSEvent.init(cgEvent:)))
        }
        let x = horizontal.documentVisibleRect.minX
        target.scrollWheel(with: try wheel(vertical: 0, horizontal: -80))
        try await Task.sleep(for: .milliseconds(120))
        #expect(abs(horizontal.documentVisibleRect.minX - x) > 1)

        if lineCount > 4 {
            let y = vertical.documentVisibleRect.minY
            target.scrollWheel(with: try wheel(vertical: -80, horizontal: 0))
            try await Task.sleep(for: .milliseconds(120))
            #expect(abs(vertical.documentVisibleRect.minY - y) > 1)
        }
    }

    @Test func aTitleOnlyActivityPillCentersItsTextAgainstTheIcon() throws {
        let savedTheme = DockThemeRuntime.current
        DockThemeRuntime.current = .island
        DockThemeRuntime.revision &+= 1
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
        }
        let pill = VoicePillQueue.Pill(
            id: "tool", icon: .wrench, title: "Reference updated", isRunning: false, tone: .success,
            slot: 0, expiresAt: .distantFuture)
        let renderer = ImageRenderer(
            content: VoicePillCard(pill: pill, maxWidth: 208)
                .background(Color.dockCanvas)
                .dockThemedRoot(surface: .cameraNotch)
                .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try #require(renderer.nsImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
        let icon = try #require(
            inkCenter(image, within: 36..<70) { color in
                color.greenComponent > 0.40 && color.greenComponent - color.redComponent > 0.16
            })
        let title = try #require(
            inkCenter(image, within: 102..<380) { color in
                min(color.redComponent, color.greenComponent, color.blueComponent) > 0.70
            })
        #expect(abs(title - icon) <= 2.5, "Pill title and icon vertical centers were \(title) and \(icon) points")
    }

    private func inkCenter(
        _ image: NSBitmapImageRep, within columns: Range<Int>, matching: (NSColor) -> Bool
    ) -> Double? {
        let rows = (0..<image.pixelsHigh).filter { y in
            columns.contains { x in
                guard x < image.pixelsWide, let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { return false }
                return matching(color)
            }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return Double(first + last) / 4  // Average the edges and convert 2x pixels to points.
    }

    @Test func renderVoiceMediaAndCenteredActivityPills() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_GENUI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("voice-media-fixture.png")
        let fixture = NSImage(size: NSSize(width: 400, height: 210), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 165, y: 70, width: 70, height: 70)).fill()
            return true
        }
        let imageBytes = try #require(fixture.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: imageBytes)?.representation(using: .png, properties: [:]))
        try png.write(to: url)

        let model = DockModel()
        let savedTheme = DockThemeRuntime.current
        DockThemeRuntime.current = .island
        DockThemeRuntime.revision &+= 1
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
            model.shutdown()
        }
        let text = "Here is the preview.\nMEDIA: \"\(url.path)\"\nMEDIA:https://example.com/video.mp4"
        let message = ChatMessage(role: .hermes, text: text)
        let card = VoiceGenerativeCard(model: model, message: message, maxWidth: 336, floating: false, maxHeight: 440)
            .padding(18).background(Color.dockCanvas)
        try await capture(card, dark: true, root: root, name: "voice-media", width: 372)

        let report = root.appendingPathComponent("media-report.txt")
        try "A plain-text delivery.".write(to: report, atomically: true, encoding: .utf8)
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let movie = repository.appendingPathComponent("docs/media/genui-demo.mp4")
        try #require(FileManager.default.fileExists(atPath: movie.path))
        let moviePoster = try #require(await ChatVideoPreview.poster(at: movie))
        #expect(moviePoster.width > 0 && moviePoster.height > 0)
        let surface = RichSurface(
            version: 1, id: "test-photo", title: "Mixed media", fallback: "A sample photo and attachments",
            kind: .native,
            blocks: [
                RichBlock(
                    type: .gallery,
                    items: [
                        RichItem(title: "Sample photo", url: "data:image/png;base64," + png.base64EncodedString())
                    ])
            ])
        let mixed = ChatMessage(
            role: .hermes,
            text: "~~~herm-ui\n" + String(decoding: try JSONEncoder().encode(surface), as: UTF8.self)
                + "\n~~~\nMEDIA: \"\(movie.path)\"\nMEDIA: \"\(report.path)\"")
        let row = ConversationMessageRow(
            message: mixed, isStreamingMessage: false, streamingText: nil,
            activeBotProfileID: nil, botsByID: [:], avatarImages: [:], botRosterRevision: 0,
            onImagePreview: { _ in }, metrics: ConversationWorkspaceMetrics.resolve(isFullscreen: true)
        )
        .generativeUIMessage(model: model, message: mixed)
        .padding(16).background(Color.dockCanvas)
        try await capture(row, dark: true, root: root, name: "mixed-chat-media", width: 680)
        let mixedVoice = VoiceGenerativeCard(
            model: model, message: mixed, maxWidth: 516, floating: false, maxHeight: 560
        )
        .padding(18).background(Color.dockCanvas)
        try await capture(mixedVoice, dark: true, root: root, name: "mixed-voice-media", width: 552)

        let titleOnly = VoicePillQueue.Pill(
            id: "tool", icon: .wrench, title: "Reference updated", isRunning: false, tone: .success,
            slot: 0, expiresAt: .distantFuture)
        var titledDetail = titleOnly
        titledDetail.detail = "Two sources checked"
        let pills = VStack(alignment: .leading, spacing: DockSpacing.group) {
            VoicePillCard(pill: titleOnly, maxWidth: 208)
            VoicePillCard(pill: titledDetail, maxWidth: 208)
        }
        .padding(18).background(Color.dockCanvas)
        try await capture(pills, dark: true, root: root, name: "voice-activity-pills", width: 244)
    }

    private func capture<V: View>(
        _ view: V, dark: Bool, root: URL, name: String, width: CGFloat, update: (() -> Void)? = nil
    ) async throws {
        let host = NSHostingView(
            rootView: view.frame(width: width, alignment: .topLeading).dockThemedRoot()
                .fixedSize(horizontal: false, vertical: true))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: max(host.fittingSize.height, 100))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for index in 0..<5 {
            if index == 3 { update?() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        host.frame.size.height = max(host.fittingSize.height, 100)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent(name + ".png"))
    }
}
