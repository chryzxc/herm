import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Herm

/// Opt-in images of the real views with sample content; no live session or model calls.
@MainActor
struct GenerativeUIVisualReviewTests {
  @Test func renderCurrentImplementation() async throws {
    guard let directory = ProcessInfo.processInfo.environment["HERM_UI_REVIEW_DIR"] else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let savedTheme = DockThemeRuntime.current
    let application = NSApplication.shared
    let savedAppearance = application.appearance
    let savedRevision = DockThemeRuntime.revision
    defer { DockThemeRuntime.current = savedTheme; DockThemeRuntime.revision = savedRevision; application.appearance = savedAppearance }
    DockThemeRuntime.current = .island
    DockThemeRuntime.revision &+= 1
    let suite = "HermVisualReview.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = URL(fileURLWithPath: directory)
    let model = DockModel(sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
      defaults: defaults, initialSessionID: "visual-example", botActivityFileURL: root.appendingPathComponent("bots.json"))
    defer { model.shutdown() }
    model.status = .idle
    let replyState = RichReplyState()
    let native = RichSurface(version: 1, id: "commute", title: "Commute comparison",
      fallback: "Cycling costs the least; the train offers a predictable journey.", kind: .native,
      blocks: [
        RichBlock(type: .text, text: "Cycling is the cheapest option. Take the train when you want a predictable trip without parking."),
        RichBlock(type: .table, columns: ["Option", "Each way", "Daily cost"],
          rows: [["Train", "30 min", "$6"], ["Bike", "25 min", "$0"], ["Drive", "20 min", "$12"]]),
        RichBlock(type: .text, text: "Daily travel cost ($)"),
        RichBlock(type: .chart, style: "bar", points: [RichPoint(label: "Train", value: 6), RichPoint(label: "Bike", value: 0), RichPoint(label: "Drive", value: 12)]),
        RichBlock(type: .form, fields: [
          RichField(id: "option", label: "Which option do you prefer?", type: .choice, options: ["Train", "Bike", "Drive"]),
          RichField(id: "priority", label: "What matters most to you?", type: .text)
        ], submitLabel: "Send my preference")
      ])
    let html = """
    <main><p class="eyebrow">SAVINGS PLANNER</p><h1>A little each month.</h1><p class="muted">Move the slider to explore your yearly savings.</p>
    <section><div class="row"><label for="monthly">Monthly contribution</label><output id="amount">$200</output></div><input id="monthly" type="range" min="25" max="1000" value="200" step="25"></section>
    <section class="result"><p class="muted">After 12 months</p><strong id="year">$2,400</strong><p class="muted">Your contributions, before interest.</p></section>
    <div class="bars" aria-hidden="true"></div></main>
    <style>html,body{margin:0}body{padding:28px;box-sizing:border-box}main{max-width:640px;margin:auto}.eyebrow{font-size:10px;letter-spacing:1.8px;color:var(--herm-secondary)}h1{font-size:24px;letter-spacing:-.6px;font-weight:600;margin:14px 0 8px}.muted{color:var(--herm-secondary);line-height:1.6}.row{display:flex;justify-content:space-between;gap:16px}section{margin-top:28px}input{width:100%;margin:18px 0 0;accent-color:var(--herm-accent)}output{font-variant-numeric:tabular-nums;color:var(--herm-text)}.result{padding-top:18px;border-top:1px solid var(--herm-border)}.result strong{display:block;font-size:40px;letter-spacing:-1.5px;font-weight:500;font-variant-numeric:tabular-nums}.bars{height:72px;display:flex;align-items:flex-end;gap:7px;margin-top:20px}.bars i{flex:1;background:var(--herm-accent);opacity:.7;border-radius:2px 2px 0 0}</style>
    <script>const monthly=document.getElementById('monthly'),amount=document.getElementById('amount'),year=document.getElementById('year'),bars=document.querySelector('.bars');for(let i=1;i<=12;i++){const b=document.createElement('i');b.style.height=(i/12*100)+'%';bars.append(b)}monthly.addEventListener('input',()=>{amount.textContent='$'+Number(monthly.value).toLocaleString();year.textContent='$'+(Number(monthly.value)*12).toLocaleString()});</script>
    """
    let app = RichSurface(version: 1, id: "savings", title: "Explore your savings",
      fallback: "Adjust your monthly contribution to see how much you could save in a year.", kind: .html, html: html)
    func encoded(_ surface: RichSurface) throws -> String {
      "```herm-ui\n" + String(decoding: try JSONEncoder().encode(surface), as: UTF8.self) + "\n```"
    }
    let user = ChatMessage(role: .user, text: "Compare train, bike and driving for my commute. Let me choose an option.")
    let reply = ChatMessage(role: .hermes, text: try encoded(native), modelName: "Hermes")
    let appUser = ChatMessage(role: .user, text: "Make me an interactive savings planner.")
    let appReply = ChatMessage(role: .hermes, text: try encoded(app), modelName: "Hermes")
    model.messages = [user, reply, appUser, appReply]
    let metrics = ConversationWorkspaceMetrics.resolve(isFullscreen: true)
    func row(_ message: ChatMessage) -> some View {
      ConversationMessageRow(message: message, isStreamingMessage: false, streamingText: nil,
        activeBotProfileID: nil, botsByID: [:], avatarImages: [:], botRosterRevision: 0,
        onImagePreview: { _ in }, metrics: metrics)
        .environment(\.richReplyState, replyState)
        .environment(\.richReplyContext, RichReplyContext(model: model, message: message, state: replyState))
    }
    func capture<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) async throws {
      let content = view.frame(width: width, height: height, alignment: .topLeading)
        .background(Color.dockCanvas).environment(\.colorScheme, .dark).dockThemedRoot()
      let host = NSHostingView(rootView: content)
      host.frame = NSRect(x: 0, y: 0, width: width, height: height)
      let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: .darkAqua)
      window.contentView = host; window.orderFrontRegardless()
      defer { window.orderOut(nil) }
      for _ in 0..<7 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)) }
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      let png = try #require(rep.representation(using: .png, properties: [:]))
      try png.write(to: root.appendingPathComponent(name + ".png"))
    }
    try await capture(VStack(spacing: 12) { row(user); row(reply) }.padding(.vertical, 20),
      name: "native-reply", width: 700, height: 760)
    try await capture(VStack(spacing: 12) { row(appUser); row(appReply) }.padding(.vertical, 20),
      name: "interactive-preview", width: 700, height: 300)
    let calls = [
      ActiveToolCall(id: "read", name: "read_file", input: "", context: "Package.swift", startedAt: .now, isComplete: true),
      ActiveToolCall(id: "test", name: "terminal", input: "", context: "swift test", startedAt: .now, isComplete: false)
    ]
    try await capture(TurnActivityView(activity: calls, runningSince: Date().addingTimeInterval(-12), duration: nil).padding(24),
      name: "original-loading", width: 700, height: 180)

    let sources = RichSurface(version: 1, id: "sources", title: "Research sources",
      fallback: "References for isolated interactive previews.", kind: .native, blocks: [
        RichBlock(type: .text, text: "References for the interactive preview's browser restrictions."),
        RichBlock(type: .sources, items: [
          RichItem(title: "MDN · iframe sandbox", url: "https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/iframe#sandbox"),
          RichItem(title: "MDN · Content Security Policy", url: "https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy")
        ])
      ])
    let trend = RichSurface(version: 1, id: "focus-time", title: "Weekly focus time",
      fallback: "Sample focus hours across seven days.", kind: .native, blocks: [
        RichBlock(type: .text, text: "Focus hours per day · sample data"),
        RichBlock(type: .chart, style: "line", points: [
          RichPoint(label: "Mon", value: 3), RichPoint(label: "Tue", value: 4.5),
          RichPoint(label: "Wed", value: 3.5), RichPoint(label: "Thu", value: 6),
          RichPoint(label: "Fri", value: 5), RichPoint(label: "Sat", value: 2), RichPoint(label: "Sun", value: 3)
        ])
      ])
    let controls = RichSurface(version: 1, id: "summary-options", title: "Choose your summary",
      fallback: "Set the number of sessions and the sections to include.", kind: .native, blocks: [
        RichBlock(type: .form, fields: [
          RichField(id: "sessions", label: "Sessions per week", type: .number),
          RichField(id: "sections", label: "Include these sections", type: .multipleChoice,
            options: ["Metrics", "Notes", "Follow-up tasks"]),
          RichField(id: "comparison", label: "Include a weekly comparison", type: .boolean)
        ], submitLabel: "Send my choices")
      ])
    let sourcesMessage = ChatMessage(role: .hermes, text: try encoded(sources))
    let trendMessage = ChatMessage(role: .hermes, text: try encoded(trend))
    let controlsMessage = ChatMessage(role: .hermes, text: try encoded(controls))
    model.messages += [sourcesMessage, trendMessage, controlsMessage]
    let formContext = RichReplyContext(model: model, message: controlsMessage, state: replyState)
    let form = replyState.form(key: "\(formContext.sourceKey):\(controls.id):\(formContext.revision):0")
    form.values = ["sessions": ["3"], "sections": ["Metrics", "Notes"], "comparison": ["Yes"]]
    try await capture(VStack(spacing: 20) { row(sourcesMessage); row(trendMessage) }.padding(.vertical, 20),
      name: "sources-and-line-chart", width: 700, height: 560)
    try await capture(row(controlsMessage).padding(.vertical, 20),
      name: "other-form-controls", width: 700, height: 470)
    // Capture the real sandboxed document after the native Open action would create its host.
    let state = GeneratedHTMLLoadState()
    let coordinator = GeneratedHTMLWebView.Coordinator(html: html, state: state)
    let web = coordinator.makeWebView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 470), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = web; window.orderFrontRegardless()
    defer { GeneratedHTMLWebView.dismantleNSView(web, coordinator: coordinator); window.orderOut(nil) }
    application.appearance = NSAppearance(named: .darkAqua)
    coordinator.load()
    for _ in 0..<50 { try await Task.sleep(for: .milliseconds(100)); if !state.loading { break } }
    #expect(state.error == nil)
    try await Task.sleep(for: .milliseconds(300))
    let bitmap = try await web.takeSnapshot(configuration: nil)
    let tiff = try #require(bitmap.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: root.appendingPathComponent("interactive-open.png"))

    let gallery = RichSurface(version: 1, id: "gallery", title: "Generated previews",
      fallback: "Two example previews created for this review.", kind: .native, blocks: [
        RichBlock(type: .text, text: "Here are the two visual previews from this review."),
        RichBlock(type: .gallery, items: [
          RichItem(title: "Commute comparison", url: "data:image/png;base64," + (try Data(contentsOf: root.appendingPathComponent("native-reply.png"))).base64EncodedString()),
          RichItem(title: "Savings planner", url: "data:image/png;base64," + (try Data(contentsOf: root.appendingPathComponent("interactive-open.png"))).base64EncodedString())
        ])
      ])
    #expect(gallery.validate())
    let galleryMessage = ChatMessage(role: .hermes, text: try encoded(gallery))
    model.messages.append(galleryMessage)
    try await capture(row(galleryMessage).padding(.vertical, 20),
      name: "image-gallery", width: 700, height: 360)

  }
}
