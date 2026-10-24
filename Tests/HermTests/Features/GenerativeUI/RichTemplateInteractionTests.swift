import AppKit
import SwiftUI
import Testing
import WebKit

@testable import Herm

@MainActor
struct RichTemplateInteractionTests {
    @Test func nativeSamplesRenderWithTheirRequiredSessionAndRecordContext() async throws {
        let previousTheme = DockThemeRuntime.current
        let previousRevision = DockThemeRuntime.revision
        DockThemeRuntime.current = .slate
        DockThemeRuntime.revision &+= 1
        defer {
            DockThemeRuntime.current = previousTheme
            DockThemeRuntime.revision = previousRevision
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "RichTemplateLayout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"), defaults: defaults,
            initialSessionID: "template-owner", botActivityFileURL: root.appendingPathComponent("bots.json"))
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        model.status = .idle
        let replyState = RichReplyState()
        let router = RichHostActionRouter(
            scope: .init(profileID: nil, resourceID: "template-owner"),
            features: RichRecordTarget.Kind.allCases.map { kind in
                .init(kind: kind, ids: { ["loaded-" + kind.rawValue] }) { id in
                    guard id == "loaded-" + kind.rawValue else { return nil }
                    return .init(title: "Supplied \(kind.rawValue)", detail: "Test fixture record", open: {})
                }
            })
        let directory = ProcessInfo.processInfo.environment["HERM_TEMPLATE_REVIEW_DIR"]
        if let directory {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        for sample in try RichTemplateFixtures.samples() {
            let surface = try JSONDecoder().decode(RichSurface.self, from: Data(sample.source.utf8))
            guard surface.kind == .native else { continue }
            let message = ChatMessage(role: .hermes, text: "```herm-ui\n" + sample.source + "\n```")
            model.messages = [message]
            let context = RichReplyContext(model: model, message: message, state: replyState)
            #expect(context.isCurrent)
            for width: CGFloat in [320, 640, 1000] {
                let view = RichSurfaceView(surface: surface, source: sample.source)
                    .environment(\.richReplyState, replyState).environment(\.richReplyContext, context)
                    .environment(\.richHostActionRouter, router).dockThemedRoot().padding(16).frame(width: width)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                host.layoutSubtreeIfNeeded()
                #expect(
                    host.fittingSize.height.isFinite && host.fittingSize.height > 0,
                    "Invalid layout: \(sample.id) at \(width)")
                if let directory {
                    host.frame.size.height = min(1600, max(180, host.fittingSize.height))
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    window.orderFrontRegardless()
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent("\(sample.id)-\(Int(width)).png"))
                    window.orderOut(nil)
                }
            }
        }
    }

    @Test func offlineCalculatorRecalculatesForEveryInput() async throws {
        let checks = """
            const input=(id,value)=>{const el=document.getElementById(id);el.value=String(value);el.dispatchEvent(new Event('input',{bubbles:true}))};
            const formatted=value=>value.toLocaleString(undefined,{maximumFractionDigits:2});
            const result=document.getElementById('result');
            input('balance',100);input('monthly',50);input('rate',0);input('years',1);
            const zeroRate=result.textContent===formatted(700);
            input('monthly',0);input('rate',12);
            const interest=result.textContent===formatted(100*1.01**12);
            input('years',0);
            const zeroYears=result.textContent===formatted(100);
            input('balance',-10);
            const negativeBalance=result.textContent===formatted(0);
            input('balance',1000);input('monthly',200);input('rate',4);input('years',10);
            return {zeroRate,interest,zeroYears,negativeBalance};
            """
        let result = try await runHTMLRecipe("calculations", checks: checks)
        for key in ["zeroRate", "interest", "zeroYears", "negativeBalance"] {
            #expect(result[key] as? Bool == true, "Calculator interaction failed: \(key)")
        }
    }

    @Test func offlineQuizScoresExplainsAndResets() async throws {
        let checks = """
            const get=id=>document.getElementById(id);
            get('stack').click();
            const wrongAnswer=get('score').textContent==='0 / 1' && get('feedback').textContent.includes('first in, first out');
            get('queue').click();
            const preventsRepeat=get('score').textContent==='0 / 1' && get('queue').disabled && get('stack').disabled;
            get('reset').click();
            const resets=get('score').textContent==='0 / 0' && get('feedback').textContent==='' && !get('queue').disabled && !get('stack').disabled;
            get('queue').click();
            const correctAnswer=get('score').textContent==='1 / 1' && get('feedback').textContent.length>0;
            return {wrongAnswer,preventsRepeat,resets,correctAnswer};
            """
        let result = try await runHTMLRecipe("learning", checks: checks)
        for key in ["wrongAnswer", "preventsRepeat", "resets", "correctAnswer"] {
            #expect(result[key] as? Bool == true, "Quiz interaction failed: \(key)")
        }
    }

    @Test func documentedCalculatorRecalculatesWithoutAnotherClick() async throws {
        let sample = try #require(RichTemplateFixtures.samples().first { $0.id == "docs-calculator" })
        let surface = try JSONDecoder().decode(RichSurface.self, from: Data(sample.source.utf8))
        let html = try #require(surface.html)
        let checks = """
            const input=document.getElementById('n'),answer=document.getElementById('answer');
            const initial=answer.textContent==='16';
            input.value='5';input.dispatchEvent(new Event('input',{bubbles:true}));
            const recalculates=answer.textContent==='25';
            input.value='0';input.dispatchEvent(new Event('input',{bubbles:true}));
            return {initial,recalculates,zero:answer.textContent==='0'};
            """
        let result = try await runHTML(html, id: "documented-calculator", checks: checks)
        for key in ["initial", "recalculates", "zero"] {
            #expect(result[key] as? Bool == true, "Documented calculator interaction failed: \(key)")
        }
    }

    private func runHTMLRecipe(_ id: String, checks: String) async throws -> [String: Any] {
        let recipe = try #require(RichGenerationRecipes.all.first { $0.id == id })
        let surface = try JSONDecoder().decode(
            RichSurface.self, from: Data(RichGenerationRecipes.fixture(for: recipe).utf8))
        #expect(surface.validate())
        let html = try #require(surface.html)
        return try await runHTML(html, id: id, checks: checks)
    }

    private func runHTML(_ html: String, id: String, checks: String) async throws -> [String: Any] {
        // Test-only observers inspect the real offline document; production gains no bridge or exception.
        let prelude =
            "<script>window.__templateErrors=[];addEventListener('error',event=>window.__templateErrors.push(event.message));</script>"
        let runner = """
            <script>(()=>{let result;try{result=(()=>{\(checks)})()}catch(error){result={failure:String(error)}}result.errors=window.__templateErrors;parent.postMessage({richTemplateResult:result},'*')})();</script>
            """
        let state = GeneratedHTMLLoadState()
        let coordinator = GeneratedHTMLWebView.Coordinator(html: prelude + html + runner, state: state)
        let web = coordinator.makeWebView()
        web.configuration.userContentController.addUserScript(
            WKUserScript(
                source:
                    "window.__richTemplateResult=null;addEventListener('message',event=>{if(event.data?.richTemplateResult)window.__richTemplateResult=event.data.richTemplateResult});",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        defer {
            GeneratedHTMLWebView.dismantleNSView(web, coordinator: coordinator)
            window.orderOut(nil)
        }
        coordinator.load()
        var result: [String: Any]?
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            result = try? await web.evaluateJavaScript("window.__richTemplateResult") as? [String: Any]
            if result != nil || state.error != nil { break }
        }
        #expect(state.error == nil)
        let values = try #require(result, "Recipe did not execute in WebKit: \(id)")
        #expect(values["failure"] == nil)
        #expect((values["errors"] as? [String]) == [])
        if let directory = ProcessInfo.processInfo.environment["HERM_TEMPLATE_REVIEW_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let snapshot = try await web.takeSnapshot(configuration: nil)
            let bitmap = try #require(snapshot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("recipe-\(id)-interactive.png"))
        }
        return values
    }
}
