import Foundation
import Testing

@testable import Herm

struct DeliveryQuestionLoadingTests {
    @Test func backgroundReadPreservesOrderAndSkipsMalformedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["b", "a"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "task_id": name, "session_id": "session-\(name)", "profile": "bot",
                "questions": [["question": "Choose \(name)", "choices": ["Yes", "No"]]],
            ])
            try data.write(to: directory.appendingPathComponent("\(name).json"))
        }
        try Data("broken".utf8).write(to: directory.appendingPathComponent("bad.json"))
        let questions = await EdgeDeliveryQuestion.loadOffMain(from: directory)
        #expect(questions.map(\.taskID) == ["a", "b"])
        #expect(questions.map(\.profileID) == ["bot", "bot"])
        #expect(questions.allSatisfy { $0.choices == ["Yes", "No"] })
        #expect(try await questions[0].removeIfCurrent())
        #expect(!FileManager.default.fileExists(atPath: questions[0].file.path))

        let replacement = try JSONSerialization.data(withJSONObject: [
            "task_id": "b", "session_id": "session-b", "profile": "bot",
            "questions": [["question": "A newer question", "choices": ["Continue"]]],
        ])
        try replacement.write(to: questions[1].file)
        #expect(try await !questions[1].removeIfCurrent())
        #expect(FileManager.default.fileExists(atPath: questions[1].file.path))
    }
}
