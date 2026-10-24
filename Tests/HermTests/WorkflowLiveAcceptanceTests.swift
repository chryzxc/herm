import AppKit
import Foundation
import PDFKit
import Testing

@testable import Herm

/// Opt-in only: creates test resources, never submits a model turn or changes integrations.
@MainActor
struct WorkflowLiveAcceptanceTests {
    private struct Check: Codable {
        let operation: String
        let passed: Bool
        let milliseconds: Double
        let errorDomain: String?
        let errorCode: Int?
        var unsupportedReason: String? = nil
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERM_RUN_LIVE_ACCEPTANCE"] == "1"))
    func scopedRuntimeAndCaptureContracts() async throws {
        let environment = ProcessInfo.processInfo.environment
        let profile = try #require(environment["HERM_ACCEPTANCE_PROFILE"])
        // Require a dedicated profile and matching process home before spawning anything.
        let expectedHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/profiles/\(profile)").standardizedFileURL
        guard profile.hasPrefix("herm-acceptance-"),
            profile.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
            environment["HERMES_HOME"].map({ URL(fileURLWithPath: $0).standardizedFileURL })
                == expectedHome,
            FileManager.default.fileExists(atPath: expectedHome.path)
        else { throw AcceptanceError.invalidProfile }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermWorkflowAcceptance/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var checks: [Check] = []
        var resources: [String: String] = ["profile": profile, "directory": directory.path]
        defer {
            let report = directory.appendingPathComponent("report.json")
            if let data = try? JSONEncoder().encode(Report(resources: resources, checks: checks)) {
                try? data.write(to: report, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: report.path)
            }
            print("Herm live acceptance report: \(report.path)")
        }
        // Explicit local settings prevent a user's remote/cloud preference from becoming the test target.
        let gateway = HermesGateway(
            workingDirectory: directory, connectionSettings: GatewayConnectionSettings())
        defer { gateway.close() }
        let control = HermesControlRPC(client: gateway)
        let service = control.workflow(profileID: profile)
        func check(_ operation: String, _ work: () async throws -> Void) async throws {
            let started = ContinuousClock.now
            do {
                try await work()
                checks.append(
                    Check(
                        operation: operation, passed: true,
                        milliseconds: Self.milliseconds(started.duration(to: .now)),
                        errorDomain: nil, errorCode: nil))
            } catch {
                if case AcceptanceError.unsupported(let reason) = error {
                    checks.append(
                        Check(
                            operation: operation, passed: false,
                            milliseconds: Self.milliseconds(started.duration(to: .now)),
                            errorDomain: nil, errorCode: nil, unsupportedReason: reason))
                    return
                }
                let error = error as NSError
                checks.append(
                    Check(
                        operation: operation, passed: false,
                        milliseconds: Self.milliseconds(started.duration(to: .now)),
                        errorDomain: error.domain, errorCode: error.code))
                throw AcceptanceError.operation(operation)
            }
        }

        try await check("connect-and-capabilities") {
            try await gateway.connect()
            let capabilities = try await gateway.request("gateway.capabilities", params: [:])
            guard capabilities["per_session_exclusive_submit"] as? Bool == true else {
                throw AcceptanceError.invalidResponse
            }
        }
        try await check("profile-identity") {
            let details = try await BotService(client: gateway).describe(profileID: profile)
            guard details.name == profile else { throw AcceptanceError.invalidResponse }
        }

        let create: [String: Any] = [
            "profile": profile, "source": HermesFeatureIDs.sessionSource, "title": "Herm acceptance",
            "cwd": directory.path, "cwd_explicit": true, "idempotency_key": UUID().uuidString,
            "messages": [
                ["role": "user", "content": "Acceptance fixture material"],
                ["role": "assistant", "content": "Acceptance fixture reply"],
            ],
        ]
        var owner: HermesSession?
        var createdRuntime: String?
        try await check("create-idempotency-and-explicit-directory") {
            let result = try await gateway.request("session.create", params: create)
            guard let id = result["stored_session_id"] as? String, !id.isEmpty else {
                throw AcceptanceError.invalidResponse
            }
            resources["session"] = id
            let info = result["info"] as? [String: Any] ?? [:]
            guard info["profile_name"] as? String == profile, info["cwd"] as? String == directory.path,
                let runtime = result["session_id"] as? String, !runtime.isEmpty
            else {
                throw AcceptanceError.invalidResponse
            }
            createdRuntime = runtime
            let repeated = try await gateway.request("session.create", params: create)
            guard repeated["stored_session_id"] as? String == id else {
                throw AcceptanceError.invalidResponse
            }
            let session = HermesSession(
                id: id, profileID: profile, title: "Herm acceptance",
                preview: "", startedAt: nil, messageCount: 2, source: "herm")
            owner = session
        }
        let session = try #require(owner)
        let rawResume = try await gateway.request(
            "session.resume",
            params: [
                "profile": profile,
                "session_id": session.id, "omit_messages": true, "source": HermesFeatureIDs.sessionSource,
            ])
        let resumeInfo = rawResume["info"] as? [String: Any] ?? [:]
        let resumeProfile = rawResume["profile"] as? String ?? resumeInfo["profile_name"] as? String
        if resumeProfile == nil {
            do {
                _ = try await service.resumeOwned(session)
                Issue.record("A named-profile resume without owner confirmation was accepted")
            } catch let error as QuickDraftError {
                #expect(error.localizedDescription.contains("owner profile"))
                checks.append(
                    Check(
                        operation: "named-profile-owned-resume", passed: false, milliseconds: 0,
                        errorDomain: nil, errorCode: nil,
                        unsupportedReason:
                            "The lazy resume response omits profile identity. Herm refuses the owned action."))
            }
        } else {
            try await check("named-profile-owned-resume") {
                guard resumeProfile == profile,
                    try await service.sessionDirectory(session) == directory.path
                else {
                    throw AcceptanceError.invalidResponse
                }
            }
        }
        try await check("scoped-inventory-and-result-read") {
            let inventory = try await control.sessions(limit: 20, profileID: profile)
            guard let rows = inventory["sessions"] as? [[String: Any]],
                rows.contains(where: { $0["id"] as? String == session.id })
            else {
                throw AcceptanceError.invalidResponse
            }
            let history = try await control.sessionMessages(
                sessionID: session.id, profileID: profile, latest: true)
            let result = try EdgeResultContent.parse(history, session: session)
            guard result?.text == "Acceptance fixture reply" else {
                throw AcceptanceError.invalidResponse
            }
        }
        let runtime = try #require(createdRuntime)
        guard rawResume["running"] as? Bool == false else { throw AcceptanceError.invalidResponse }
        let scope: [String: Any] = ["profile": profile, "session_id": runtime]
        try await check("generic-file-reference") {
            var params = scope
            params["name"] = "acceptance.txt"
            params["data_url"] =
                "data:text/plain;base64," + Data("Acceptance fixture".utf8).base64EncodedString()
            let result = try await gateway.request("file.attach", params: params)
            guard result["attached"] as? Bool == true,
                (result["ref_text"] as? String)?.hasPrefix("@file:") == true
            else {
                throw AcceptanceError.invalidResponse
            }
        }
        try await check("image-upload-and-owned-detach") {
            let bitmap = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
            bitmap.setColor(.white, atX: 0, y: 0)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            var params = scope
            params["filename"] = "acceptance.png"
            params["content_base64"] = png.base64EncodedString()
            let result = try await gateway.request("image.attach_bytes", params: params)
            guard result["attached"] as? Bool == true, let path = result["path"] as? String, !path.isEmpty
            else {
                throw AcceptanceError.invalidResponse
            }
            var detach = scope
            detach["path"] = path
            guard try await gateway.request("image.detach", params: detach)["detached"] as? Bool == true
            else {
                throw AcceptanceError.invalidResponse
            }
        }
        try await check("pdf-upload-and-owned-detach") {
            let pdfURL = directory.appendingPathComponent("acceptance.pdf")
            var bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
            let context = try #require(CGContext(pdfURL as CFURL, mediaBox: &bounds, nil))
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.endPDFPage()
            context.closePDF()
            let bytes = try Data(contentsOf: pdfURL)
            var params = scope
            params["filename"] = "acceptance.pdf"
            params["content_base64"] = bytes.base64EncodedString()
            let result: [String: Any]
            do { result = try await gateway.request("pdf.attach", params: params) } catch {
                guard
                    error.localizedDescription == "pdftoppm not installed (poppler-utils package required)"
                else { throw error }
                throw AcceptanceError.unsupported(
                    "The installed runtime requires pdftoppm for PDF capture, and it is unavailable.")
            }
            guard result["attached"] as? Bool == true, let pages = result["pages"] as? [[String: Any]],
                pages.count == 1, let path = pages.first?["path"] as? String, !path.isEmpty
            else {
                throw AcceptanceError.invalidResponse
            }
            var detach = scope
            detach["path"] = path
            guard try await gateway.request("image.detach", params: detach)["detached"] as? Bool == true
            else {
                throw AcceptanceError.invalidResponse
            }
        }
    }

    private struct Report: Codable {
        let resources: [String: String]
        let checks: [Check]
    }
    private enum AcceptanceError: Error {
        case unsupported(String)
        case invalidProfile, invalidResponse
        case operation(String)
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
