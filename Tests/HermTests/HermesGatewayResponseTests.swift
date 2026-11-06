import Foundation
import Testing

@testable import Herm

@MainActor
struct HermesGatewayResponseTests {
    private func frame(_ text: String) throws -> HermesGatewayResponse {
        try #require(HermesGatewayResponse.decode(.string(text)))
    }

    @Test func largeTranscriptPreservesNestedJSONValues() async throws {
        let messages = (0..<2000).map { index in
            ["index": index, "text": "message \(index) — 世界", "nested": ["values": [true, 3.25, NSNull()]]]
                as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "result": ["messages": messages]])
        let decoded = try frame(String(decoding: data, as: UTF8.self))
        let gateway = HermesGateway()
        let response: HermesGatewayResponse = try await withCheckedThrowingContinuation { continuation in
            gateway.pending[1] = continuation
            gateway.handle(decoded)
        }
        let actual = try #require(response.object["messages"] as? [[String: Any]])
        #expect(actual.count == messages.count)
        #expect(NSDictionary(dictionary: actual[1999]).isEqual(to: messages[1999]))
        #expect(gateway.pending.isEmpty)
    }

    @Test(arguments: ["{}", "{\"result\":null}", "{\"result\":[]}", "{\"result\":42}"])
    func nonObjectResultsRemainEmpty(_ fields: String) async throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(fields.utf8)) as? [String: Any])
        object["id"] = 1
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try frame(String(decoding: data, as: UTF8.self))
        let gateway = HermesGateway()
        let response: HermesGatewayResponse = try await withCheckedThrowingContinuation { continuation in
            gateway.pending[1] = continuation
            gateway.handle(decoded)
        }
        #expect(response.object.isEmpty)
    }

    @Test func errorsKeepHermesDomainCodeAndMessageAndCancelDeadline() async throws {
        let gateway = HermesGateway()
        let deadline = Task<Void, Never> {}
        let decoded = try frame(
            #"{"id":1,"error":{"code":4007,"message":"Request refused"},"result":{"ignored":true}}"#)
        do {
            let _: HermesGatewayResponse = try await withCheckedThrowingContinuation { continuation in
                gateway.pending[1] = continuation
                gateway.timeoutTasks[1] = deadline
                gateway.handle(decoded)
            }
            Issue.record("Expected RPC error")
        } catch {
            let error = error as NSError
            #expect(error.domain == "Hermes")
            #expect(error.code == 1)
            #expect(error.userInfo["HermesRPCCode"] as? Int == 4007)
            #expect(error.localizedDescription == "Request refused")
        }
        #expect(deadline.isCancelled)
        #expect(gateway.pending.isEmpty)
        #expect(gateway.timeoutTasks.isEmpty)
    }

    @Test func unknownDuplicateAndInterleavedIDsDoNotCompleteAnotherRequest() async throws {
        let gateway = HermesGateway()
        let first = try frame(#"{"id":1,"result":{"value":"first"}}"#)
        let second = try frame(#"{"id":2.0,"result":{"value":"second"}}"#)
        let unknown = try frame(#"{"id":99,"result":{"value":"unknown"}}"#)
        let deadline = Task<Void, Never> {}
        let response: HermesGatewayResponse = try await withCheckedThrowingContinuation { continuation in
            gateway.pending[2] = continuation
            gateway.timeoutTasks[2] = deadline
            gateway.handle(unknown)
            gateway.handle(first)
            #expect(gateway.pending.count == 1)
            gateway.handle(second)
            gateway.handle(second)
            gateway.handle(first)
        }
        #expect(response.object["value"] as? String == "second")
        #expect(gateway.pending.isEmpty)
        #expect(gateway.timeoutTasks.isEmpty)
        #expect(deadline.isCancelled)
    }

    @Test func twoPendingRequestsReceiveReversedRepliesAndCancelBothDeadlines() async throws {
        let gateway = HermesGateway()
        let first = try frame(#"{"id":1,"result":{"value":"first"}}"#)
        let second = try frame(#"{"id":2.0,"result":{"value":"second"}}"#)
        let unknown = try frame(#"{"id":99,"result":{"value":"unknown"}}"#)
        let firstDeadline = Task<Void, Never> {}
        let secondDeadline = Task<Void, Never> {}
        var secondRequest: Task<HermesGatewayResponse, Error>?

        let firstResponse: HermesGatewayResponse = try await withCheckedThrowingContinuation { continuation in
            gateway.pending[1] = continuation
            gateway.timeoutTasks[1] = firstDeadline
            // Start the second installation only after the first is registered.
            secondRequest = Task { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    gateway.pending[2] = continuation
                    gateway.timeoutTasks[2] = secondDeadline
                    #expect(Set(gateway.pending.keys) == [1, 2])
                    #expect(Set(gateway.timeoutTasks.keys) == [1, 2])
                    gateway.handle(unknown)
                    #expect(gateway.pending.count == 2)
                    #expect(gateway.timeoutTasks.count == 2)
                    #expect(!firstDeadline.isCancelled)
                    #expect(!secondDeadline.isCancelled)

                    gateway.handle(second)
                    gateway.handle(unknown)
                    gateway.handle(second)
                    #expect(Set(gateway.pending.keys) == [1])
                    #expect(Set(gateway.timeoutTasks.keys) == [1])
                    #expect(!firstDeadline.isCancelled)
                    #expect(secondDeadline.isCancelled)

                    gateway.handle(first)
                    gateway.handle(second)
                    gateway.handle(unknown)
                    gateway.handle(first)
                }
            }
        }
        let secondResponse = try await #require(secondRequest).value
        #expect(firstResponse.object["value"] as? String == "first")
        #expect(secondResponse.object["value"] as? String == "second")
        #expect(firstDeadline.isCancelled)
        #expect(secondDeadline.isCancelled)
        #expect(gateway.pending.isEmpty)
        #expect(gateway.timeoutTasks.isEmpty)
    }

    @Test func closeDrainsPendingResponsesAndDeadlines() async throws {
        let gateway = HermesGateway()
        let deadline = Task<Void, Never> {}
        do {
            let _: HermesGatewayResponse = try await withCheckedThrowingContinuation { continuation in
                gateway.pending[1] = continuation
                gateway.timeoutTasks[1] = deadline
                gateway.close()
            }
            Issue.record("Expected disconnect")
        } catch {
            #expect(error is HermesGateway.GatewayError)
            #expect(error.localizedDescription == "The connection to Hermes was lost.")
        }
        gateway.handle(try frame(#"{"id":1,"result":{"late":true}}"#))
        #expect(gateway.pending.isEmpty)
        #expect(gateway.timeoutTasks.isEmpty)
        #expect(deadline.isCancelled)
    }

    @Test func receiveRoutingPreservesEventsAndServerRequestsAndSuppressesTerminalOutput() throws {
        let gateway = HermesGateway()
        var types: [String] = []
        gateway.onEvent = { type, _ in types.append(type) }
        for text in [
            #"{"method":"event","params":{"type":"message.complete"}}"#,
            #"{"method":"event","params":{"type":"agent.terminal.output"}}"#,
            #"{"id":"srq-1","method":"clarify","params":{"question":"Which?"}}"#,
            #"{"id":"srq-2","method":"approval","params":{}}"#,
        ] {
            gateway.handle(try frame(text))
        }
        #expect(types == ["message.complete", "clarify.request", "approval.request"])
    }

    @Test func largeTranscriptDeliveryDecodesOnceWithoutResultSerialization() async throws {
        let messages = (0..<2000).map { index in
            [
                "index": index, "text": "message \(index) — 世界",
                "nested": ["values": [true, 3.25, NSNull()]],
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "result": ["messages": messages]])
        let gateway = HermesGateway()
        ResponseCodecProbe.reset()
        let response: HermesGatewayResponse = try await withCheckedThrowingContinuation { continuation in
            gateway.pending[1] = continuation
            Task {
                await gateway.receive(
                    .string(String(decoding: data, as: UTF8.self)),
                    jsonSerialization: ResponseCodecProbe.self)
            }
        }
        let actual = try #require(response.object["messages"] as? [[String: Any]])
        #expect(NSArray(array: actual).isEqual(to: messages))
        let work = ResponseCodecProbe.snapshot()
        #expect(work.decoded.filter { $0 == data }.count == 1)
        #expect(work.decoded.filter { $0 != data }.isEmpty)
        #expect(work.encodes == 0)
        #expect(gateway.pending.isEmpty)
    }

    @Test func malformedAndBinaryFramesAreRejected() {
        #expect(HermesGatewayResponse.decode(.string("not JSON")) == nil)
        #expect(HermesGatewayResponse.decode(.string("[]")) == nil)
        #expect(HermesGatewayResponse.decode(.data(Data("{}".utf8))) == nil)
    }
}

/// Observe actual Foundation codec calls, including calls off the main actor.
private final class ResponseCodecProbe: JSONSerialization, @unchecked Sendable {
    private final class Work: @unchecked Sendable {
        let lock = NSLock()
        var decoded: [Data] = []
        var encodes = 0
    }
    private static let work = Work()

    static func reset() {
        work.lock.withLock {
            work.decoded = []
            work.encodes = 0
        }
    }

    static func snapshot() -> (decoded: [Data], encodes: Int) {
        work.lock.withLock { (work.decoded, work.encodes) }
    }

    override class func jsonObject(with data: Data, options opt: ReadingOptions = []) throws -> Any {
        work.lock.withLock { work.decoded.append(data) }
        return try super.jsonObject(with: data, options: opt)
    }

    override class func data(withJSONObject obj: Any, options opt: WritingOptions = []) throws -> Data {
        work.lock.withLock { work.encodes += 1 }
        return try super.data(withJSONObject: obj, options: opt)
    }
}
