import CoreGraphics
import Foundation

/// Tracks the isolated pointer reporters in one displayed Chromium target.
@MainActor
final class HermesBrowserPointerTracker {
    typealias Send = (String, [String: Any], String) async throws -> [String: Any]
    struct Context: Hashable {
        let session: String
        let id: Int
    }
    struct Frame {
        var parent: String?
        var session: String
        var generation = UUID()
    }
    private struct Sample {
        let context: Context
        let frame: String
        let generation: UUID
        let revision: UUID
        let pointer: AgentPointer
    }

    static let script = """
        (() => {
          if (window.__hermPointer) return;
          window.__hermPointer = true;
          const send = (type, x, y) => {
            if (typeof window.hermPointer === 'function') window.hermPointer(JSON.stringify({ type, x, y }));
          };
          let pending = null, pressed = 0;
          addEventListener('pointermove', (e) => {
            if (!e.isTrusted) return;
            const idle = !pending;
            pending = [e.clientX, e.clientY];
            if (idle) requestAnimationFrame(() => { send('move', ...pending); pending = null; });
          }, true);
          addEventListener('pointerdown', (e) => {
            if (!e.isTrusted) return;
            pressed = performance.now(); send('down', e.clientX, e.clientY);
          }, true);
          addEventListener('focusin', (e) => {
            const r = e.target.getBoundingClientRect?.();
            if (!e.isTrusted || performance.now() - pressed < 300 || !r || !r.width || !r.height) return;
            send('focus', r.left + Math.min(r.width / 2, 24), r.top + r.height / 2);
          }, true);
        })();
        """

    private let send: Send
    private let deliver: (AgentPointer) -> Void
    private let invalidatePointer: () -> Void
    private let active: () -> Bool
    private let rootSession: String
    private var sessions: Set<String>
    private var pendingTargets: [String: (session: String, parentSession: String)] = [:]
    private var pendingContexts: [Context: String] = [:]
    private(set) var frames: [String: Frame] = [:]
    private(set) var contexts: [Context: String] = [:]
    private var sourceFrame: String?
    private var pending: [Sample] = []
    private var worker: Task<Void, Never>?
    private var stopped = false
    private var revision = UUID()

    init(
        rootSession: String, send: @escaping Send, active: @escaping () -> Bool,
        deliver: @escaping (AgentPointer) -> Void, invalidatePointer: @escaping () -> Void
    ) {
        self.rootSession = rootSession
        self.sessions = [rootSession]
        self.send = send
        self.active = active
        self.deliver = deliver
        self.invalidatePointer = invalidatePointer
    }

    func stop() {
        stopped = true
        worker?.cancel()
        worker = nil
        pending.removeAll()
        frames.removeAll()
        contexts.removeAll()
        pendingContexts.removeAll()
        pendingTargets.removeAll()
        sessions.removeAll()
    }

    func clearPointer() {
        sourceFrame = nil
        discardPending()
    }

    func discardPending() {
        revision = UUID()
        pending.removeAll()
    }

    func start() async {
        await prepare(session: rootSession)
    }

    private func prepare(session: String) async {
        guard !stopped, sessions.contains(session) else { return }
        do {
            _ = try await send("Page.enable", [:], session)
            _ = try await send("Runtime.addBinding", ["name": "hermPointer", "executionContextName": "herm"], session)
            _ = try await send(
                "Page.addScriptToEvaluateOnNewDocument", ["source": Self.script, "worldName": "herm"], session)
            _ = try await send("Runtime.enable", [:], session)
            let tree = try await send("Page.getFrameTree", [:], session)
            if let root = tree["frameTree"] as? [String: Any] { await install(tree: root, session: session) }
            guard !stopped, sessions.contains(session) else { return }
            _ = try await send(
                "Target.setAutoAttach",
                [
                    "autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true,
                    "filter": [["type": "iframe"], ["exclude": true]],
                ], session)
        } catch {
            // An unsupported iframe must not interrupt the browser itself.
        }
    }

    private func install(tree: [String: Any], session: String) async {
        guard !stopped, sessions.contains(session), let info = tree["frame"] as? [String: Any],
            let id = info["id"] as? String
        else { return }
        let parent = (info["parentId"] as? String) ?? frames[id]?.parent
        if frames[id] == nil { frames[id] = Frame(parent: parent, session: session) }
        if let frame = frames[id], frame.session == session,
            let result = try? await send("Page.createIsolatedWorld", ["frameId": id, "worldName": "herm"], session),
            let context = result["executionContextId"] as? Int, !stopped, sessions.contains(session),
            frames[id]?.generation == frame.generation, frames[id]?.session == session
        {
            contexts[Context(session: session, id: context)] = id
            _ = try? await send("Runtime.evaluate", ["expression": Self.script, "contextId": context], session)
        }
        for child in tree["childFrames"] as? [[String: Any]] ?? [] {
            await install(tree: child, session: session)
        }
    }

    func receive(_ method: String, params: [String: Any], session: String?) {
        guard !stopped, let session, sessions.contains(session) else { return }
        switch method {
        case "Target.attachedToTarget":
            guard let child = params["sessionId"] as? String,
                let info = params["targetInfo"] as? [String: Any], info["type"] as? String == "iframe",
                let id = info["targetId"] as? String
            else { return }
            let parent = (info["parentFrameId"] as? String) ?? frames[id]?.parent
            guard let parent else {
                pendingTargets[id] = (child, session)
                return
            }
            attach(frame: id, parent: parent, session: child)
        case "Target.detachedFromTarget":
            guard let child = params["sessionId"] as? String else { return }
            pendingTargets = pendingTargets.filter { $0.value.session != child }
            guard sessions.remove(child) != nil else { return }
            let detached = frames.filter { $0.value.session == child }.map(\.key)
            for id in detached {
                invalidate(frame: id)
                var ancestor = frames[id]?.parent
                var seen: Set<String> = []
                while let parentID = ancestor, seen.insert(parentID).inserted,
                    frames[parentID]?.session == child
                {
                    ancestor = frames[parentID]?.parent
                }
                if let ancestor, let parent = frames[ancestor], sessions.contains(parent.session) {
                    frames[id]?.session = parent.session
                } else {
                    remove(frame: id)
                }
            }
            contexts = contexts.filter { $0.key.session != child }
            pendingContexts = pendingContexts.filter { $0.key.session != child }
        case "Page.frameAttached":
            guard let id = params["frameId"] as? String, let parent = params["parentFrameId"] as? String else { return }
            if frames[id] == nil {
                frames[id] = Frame(parent: parent, session: session)
            } else {
                frames[id]?.parent = parent
            }
            if let target = pendingTargets.removeValue(forKey: id), target.parentSession == session {
                attach(frame: id, parent: parent, session: target.session)
            } else {
                adoptContexts(frame: id, session: session)
            }
        case "Page.frameNavigated":
            guard let info = params["frame"] as? [String: Any], let id = info["id"] as? String else { return }
            let parent = (info["parentId"] as? String) ?? frames[id]?.parent
            if frames[id] != nil { invalidate(frame: id) }
            frames[id] = Frame(parent: parent, session: session)
            adoptContexts(frame: id, session: session)
        case "Page.frameDetached":
            guard params["reason"] as? String != "swap", let id = params["frameId"] as? String else { return }
            remove(frame: id)
        case "Runtime.executionContextCreated":
            guard let info = params["context"] as? [String: Any], info["name"] as? String == "herm",
                let id = info["id"] as? Int, let aux = info["auxData"] as? [String: Any],
                let frame = aux["frameId"] as? String
            else { return }
            let context = Context(session: session, id: id)
            if frames[frame]?.session == session {
                contexts[context] = frame
            } else if frames[frame] == nil {
                pendingContexts[context] = frame
            }
        case "Runtime.executionContextDestroyed":
            guard let id = params["executionContextId"] as? Int else { return }
            let context = Context(session: session, id: id)
            pendingContexts.removeValue(forKey: context)
            guard let frame = contexts.removeValue(forKey: context) else { return }
            if sourceFrame == frame {
                sourceFrame = nil
                invalidatePointer()
            }
        case "Runtime.executionContextsCleared":
            let removed = Set(contexts.filter { $0.key.session == session }.map(\.value))
            contexts = contexts.filter { $0.key.session != session }
            pendingContexts = pendingContexts.filter { $0.key.session != session }
            if let sourceFrame, removed.contains(sourceFrame) {
                self.sourceFrame = nil
                invalidatePointer()
            }
        case "Runtime.bindingCalled":
            guard active(), params["name"] as? String == "hermPointer",
                let id = params["executionContextId"] as? Int, let payload = params["payload"] as? String,
                let pointer = AgentPointer(json: payload)
            else { return }
            enqueue(pointer, context: Context(session: session, id: id))
        default: break
        }
    }

    private func attach(frame: String, parent: String, session: String) {
        if frames[frame] != nil { invalidate(frame: frame) }
        pendingContexts = pendingContexts.filter { $0.value != frame || $0.key.session == session }
        frames[frame] = Frame(parent: parent, session: session)
        sessions.insert(session)
        adoptContexts(frame: frame, session: session)
        Task { [weak self] in await self?.prepare(session: session) }
    }

    private func adoptContexts(frame: String, session: String) {
        let ready = pendingContexts.filter { $0.key.session == session && $0.value == frame }
        for (context, frame) in ready {
            contexts[context] = frame
            pendingContexts.removeValue(forKey: context)
        }
    }

    private func invalidate(frame: String) {
        revision = UUID()
        frames[frame]?.generation = UUID()
        contexts = contexts.filter { $0.value != frame }
        if let sourceFrame, isDescendant(sourceFrame, of: frame) {
            self.sourceFrame = nil
            invalidatePointer()
        }
    }

    private func isDescendant(_ frame: String, of ancestor: String) -> Bool {
        var current: String? = frame
        var seen: Set<String> = []
        while let id = current, seen.insert(id).inserted {
            if id == ancestor { return true }
            current = frames[id]?.parent
        }
        return false
    }

    private func remove(frame: String) {
        let removed = Set(frames.keys.filter { isDescendant($0, of: frame) }).union([frame])
        invalidate(frame: frame)
        for id in removed { frames.removeValue(forKey: id) }
        contexts = contexts.filter { !removed.contains($0.value) }
        pendingContexts = pendingContexts.filter { !removed.contains($0.value) }
        pendingTargets = pendingTargets.filter { !removed.contains($0.key) }
    }

    private func enqueue(_ pointer: AgentPointer, context: Context) {
        guard let frame = contexts[context], let generation = frames[frame]?.generation else { return }
        let sample = Sample(
            context: context, frame: frame, generation: generation, revision: revision, pointer: pointer)
        if pointer.kind == .move, pending.last?.pointer.kind == .move {
            pending[pending.count - 1] = sample
        } else {
            pending.append(sample)
        }
        if pending.count > 64 {
            if let move = pending.firstIndex(where: { $0.pointer.kind == .move }) {
                pending.remove(at: move)
            } else {
                pending.removeFirst()
            }
        }
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer { worker = nil }
        while !stopped, !Task.isCancelled, !pending.isEmpty {
            let sample = pending.removeFirst()
            guard active(), contexts[sample.context] == sample.frame,
                frames[sample.frame]?.generation == sample.generation, sample.revision == revision,
                let point = await resolve(sample.pointer.point, frame: sample.frame),
                !stopped, active(), contexts[sample.context] == sample.frame,
                frames[sample.frame]?.generation == sample.generation, sample.revision == revision
            else { continue }
            sourceFrame = sample.frame
            deliver(AgentPointer(kind: sample.pointer.kind, point: point))
        }
    }

    private func resolve(_ point: CGPoint, frame: String) async -> CGPoint? {
        var point = point
        var current = frame
        var seen: Set<String> = []
        while let child = frames[current], let parentID = child.parent {
            guard seen.insert(current).inserted, let parent = frames[parentID],
                let geometry = await frameGeometry(frame: current, parent: parentID, parentSession: parent.session)
            else { return nil }
            point = CGPoint(x: geometry.x + point.x * geometry.scaleX, y: geometry.y + point.y * geometry.scaleY)
            guard point.x.isFinite, point.y.isFinite else { return nil }
            current = parentID
        }
        return frames[current]?.session == rootSession ? point : nil
    }

    struct Geometry {
        let x: CGFloat, y: CGFloat, scaleX: CGFloat, scaleY: CGFloat
        init?(value: [String: Any]) {
            guard let x = value["x"] as? Double, let y = value["y"] as? Double,
                let scaleX = value["sx"] as? Double, let scaleY = value["sy"] as? Double,
                [x, y, scaleX, scaleY].allSatisfy(\.isFinite), scaleX > 0, scaleY > 0
            else { return nil }
            self.x = x
            self.y = y
            self.scaleX = scaleX
            self.scaleY = scaleY
        }
    }

    private func frameGeometry(frame: String, parent: String, parentSession: String) async -> Geometry? {
        guard let context = contexts.first(where: { $0.key.session == parentSession && $0.value == parent })?.key.id,
            let owner = try? await send("DOM.getFrameOwner", ["frameId": frame], parentSession),
            let backendID = owner["backendNodeId"] as? Int,
            let node = try? await send(
                "DOM.resolveNode", ["backendNodeId": backendID, "executionContextId": context], parentSession),
            let object = node["object"] as? [String: Any], let objectID = object["objectId"] as? String
        else { return nil }
        let function = """
            function() {
              // shortcut: rotated or mirrored frames are skipped, use content quads when support is needed.
              for (let el = this; el; el = el.parentElement) {
                const t = getComputedStyle(el).transform;
                if (t !== 'none') { const m = new DOMMatrixReadOnly(t); if (!m.is2D || m.b || m.c || m.a <= 0 || m.d <= 0) return null; }
              }
              const r = this.getBoundingClientRect();
              if (!this.offsetWidth || !this.offsetHeight) return null;
              const sx = r.width / this.offsetWidth, sy = r.height / this.offsetHeight;
              return {x: r.left + this.clientLeft * sx, y: r.top + this.clientTop * sy, sx, sy};
            }
            """
        let result = try? await send(
            "Runtime.callFunctionOn", ["objectId": objectID, "functionDeclaration": function, "returnByValue": true],
            parentSession)
        _ = try? await send("Runtime.releaseObject", ["objectId": objectID], parentSession)
        guard let remote = result?["result"] as? [String: Any], let value = remote["value"] as? [String: Any] else {
            return nil
        }
        return Geometry(value: value)
    }
}
