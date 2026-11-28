import CoreGraphics
import Foundation
import ImageIO
import os

/// Minimal Chrome DevTools Protocol client: JSON over a websocket, flat sessions.
@MainActor
final class CDPConnection {
    struct Frame: Sendable { let image: CGImage }

    private let task: URLSessionWebSocketTask
    private let writer: Writer
    private let frameSession = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// CDP results are plain JSON values, only touched on the main actor.
    private struct Reply: @unchecked Sendable { let value: [String: Any] }
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    var onEvent: ((String, [String: Any], String?) -> Void)?
    var onClose: (() -> Void)?

    init(url: URL) {
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        writer = Writer { text, completion in
            task.send(.string(text), completionHandler: completion)
        }
        // Screencast frames and screenshots are base64 images, well past the 1 MB default.
        task.maximumMessageSize = 64 << 20
        task.resume()
        receiveNext()
    }

    func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            pending[write(method, params, session: session)] = continuation
        }.value
    }

    func fire(_ method: String, _ params: [String: Any] = [:], session: String? = nil) {
        write(method, params, session: session)
    }

    func close() {
        frameSession.withLock { $0 = nil }
        onEvent = nil
        onClose = nil
        task.cancel(with: .goingAway, reason: nil)
        failPending(CancellationError())
    }

    @discardableResult
    private func write(_ method: String, _ params: [String: Any], session: String?) -> Int {
        if method == "Page.startScreencast" {
            frameSession.withLock { $0 = session }
        } else if method == "Page.stopScreencast" {
            frameSession.withLock { if $0 == session { $0 = nil } }
        }
        return writer.write(method, params, session: session) { [weak self] id, error in
            guard let error else { return }
            Task { @MainActor in self?.pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    private func receiveNext() {
        task.receive { [weak self, frameSession, writer] result in
            switch result {
            case .failure:
                Task { @MainActor in
                    guard let self else { return }
                    self.failPending(URLError(.networkConnectionLost))
                    self.onClose?()
                }
            case .success(let message):
                let object = Self.decode(message, writer: writer) { session in frameSession.withLock { $0 == session } }
                Task { @MainActor in
                    guard let self else { return }
                    if let object { self.dispatch(object) }
                    self.receiveNext()
                }
            }
        }
    }

    nonisolated static func decode(
        _ message: URLSessionWebSocketTask.Message, writer: Writer? = nil, wantsFrame: (String) -> Bool
    ) -> [String: Any]? {
        let data: Data? =
            switch message {
            case .string(let text): text.data(using: .utf8)
            case .data(let data): data
            @unknown default: nil
            }
        guard let data, var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if object["method"] as? String == "Page.screencastFrame",
            var params = object["params"] as? [String: Any]
        {
            let session = object["sessionId"] as? String
            // Free Chromium's capture slot even when this raster is stale or unusable.
            if let session, let frame = params["sessionId"] as? Int {
                writer?.write("Page.screencastFrameAck", ["sessionId": frame], session: session)
            }
            // Decode on the socket callback, before handing the frame to the main actor.
            let payload = params.removeValue(forKey: "data") as? String
            if let session, wantsFrame(session) {
                params["decodedFrame"] = payload.flatMap(decodeFrame).map { Frame(image: $0) }
            }
            object["params"] = params
        }
        return object
    }

    nonisolated static func decodeFrame(_ base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func dispatch(_ object: [String: Any]) {
        if let id = object["id"] as? Int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(
                    throwing: NSError(
                        domain: "Herm.CDP", code: error["code"] as? Int ?? 0,
                        userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "CDP error"]))
            } else {
                continuation.resume(returning: Reply(value: object["result"] as? [String: Any] ?? [:]))
            }
        } else if let method = object["method"] as? String {
            onEvent?(method, object["params"] as? [String: Any] ?? [:], object["sessionId"] as? String)
        }
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    struct Writer: Sendable {
        typealias Enqueue = @Sendable (String, @escaping @Sendable (Error?) -> Void) -> Void

        private let enqueue: Enqueue
        private let nextID = OSAllocatedUnfairLock(initialState: 0)

        init(enqueue: @escaping Enqueue) {
            self.enqueue = enqueue
        }

        @discardableResult
        func write(
            _ method: String, _ params: [String: Any] = [:], session: String? = nil,
            completion: (@Sendable (Int, Error?) -> Void)? = nil
        ) -> Int {
            // Serialize IDs and enqueue order. The caller's JSON stays on its own thread.
            nextID.withLockUnchecked { nextID in
                nextID += 1
                let id = nextID
                var message: [String: Any] = ["id": id, "method": method, "params": params]
                if let session { message["sessionId"] = session }
                guard let data = try? JSONSerialization.data(withJSONObject: message),
                    let text = String(data: data, encoding: .utf8)
                else { return id }
                enqueue(text) { error in completion?(id, error) }
                return id
            }
        }
    }
}
