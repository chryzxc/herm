import Foundation

struct QuickSubmissionFailure: LocalizedError {
    let message: String
    let uncertain: Bool
    var errorDescription: String? { message }
}

@MainActor
enum QuickDraftSubmission {
    static func send(
        _ original: QuickDraftRecord, client: HermesRPCClientProtocol,
        progress: (QuickDraftRecord) throws -> Void,
        beforeSubmit: ((QuickDraftRecord, String) async -> Void)? = nil
    ) async throws -> QuickDraftRecord {
        var draft = original
        guard draft.delivery != .needsReview else {
            throw QuickSubmissionFailure(
                message:
                    "Review the interrupted submission in its session before discarding or sending more work.",
                uncertain: true)
        }
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else {
            throw QuickSubmissionFailure(
                message: "Use the workspace for slash commands.", uncertain: false)
        }
        guard
            !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draft.files.isEmpty || !draft.sources.isEmpty || !(draft.contexts ?? []).isEmpty
        else { throw QuickDraftError.message("Capture a message or file first.") }
        // Validate every reference before creating a session or queuing an upload.
        for file in draft.files { _ = try await file.encoded() }
        var mutationInFlight = false
        do {
            try await client.connect()
            if !draft.files.isEmpty {
                let capabilities = try await client.request(
                    HermesFeatureIDs.ID.gatewayCapabilities.rawValue, params: [:])
                guard capabilities["per_session_exclusive_submit"] as? Bool == true else {
                    throw QuickDraftError.message(
                        "This Hermes runtime does not advertise protected attachment submission. Files remain in the draft; open the workspace to review compatibility."
                    )
                }
            }
            var scope: [String: Any] = [:]
            if let profile = draft.destination.profileID { scope["profile"] = profile }
            let creatingSession = draft.destination.sessionID == nil
            if creatingSession {
                var create = scope
                create["source"] = "herm"
                create["idempotency_key"] = draft.id.uuidString
                if let path = draft.destination.projectPath {
                    create["cwd"] = path
                    create["cwd_explicit"] = true
                }
                mutationInFlight = true
                let result = try await client.request(
                    HermesFeatureIDs.ID.sessionCreate.rawValue, params: create)
                guard let runtime = result["session_id"] as? String, !runtime.isEmpty else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                draft.destination.runtimeID = runtime
                draft.destination.sessionID = result["stored_session_id"] as? String ?? runtime
                draft.destination.title = result["title"] as? String ?? "New session"
                try progress(draft)
                mutationInFlight = false
            }
            guard let owner = draft.destination.sessionID else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            var validatedCount: Int?
            var validatedDirectory: String?
            func validateDestination(directoryRetries: Int = 0) async throws -> String {
                var params = scope
                params["session_id"] = owner
                params["omit_messages"] = true
                params["source"] = "herm"
                let result = try await client.request(
                    HermesFeatureIDs.ID.sessionResume.rawValue, params: params)
                let runtime = result["session_id"] as? String ?? owner
                guard
                    DockModel.resumeResponseProvesSessionOwnership(
                        requestedSessionID: owner, resolvedSessionID: runtime, result: result)
                else {
                    throw QuickDraftError.message(
                        "Hermes returned a different session. Open the destination to review it.")
                }
                let info = result["info"] as? [String: Any] ?? [:]
                validatedCount = result["message_count"] as? Int
                validatedDirectory = result["cwd"] as? String ?? info["cwd"] as? String
                if draft.files.contains(where: \.uploaded) {
                    guard let count = draft.uploadMessageCount, count == validatedCount,
                        let directory = draft.uploadDirectory, directory == validatedDirectory
                    else {
                        throw QuickSubmissionFailure(
                            message:
                                "The session history or directory changed after upload. Review its attachments before sending.",
                            uncertain: true)
                    }
                } else if !draft.files.isEmpty,
                    validatedCount == nil || validatedDirectory?.isEmpty != false
                {
                    throw QuickDraftError.message(
                        "Hermes did not provide the state needed to protect attachment retries. Files remain in the draft."
                    )
                }
                let profile =
                    result["profile"] as? String ?? info["profile_name"] as? String ?? info["profile"]
                    as? String
                if draft.destination.profileID != nil || profile != nil {
                    guard profile == (draft.destination.profileID ?? "default") else {
                        throw QuickDraftError.message(
                            "Hermes did not confirm the destination profile. Open the workspace to review compatibility."
                        )
                    }
                }
                guard result["running"] as? Bool != true, info["running"] as? Bool != true else {
                    throw QuickDraftError.message("This session is busy. The draft has been retained.")
                }
                if let requested = draft.destination.projectPath {
                    let reported = result["cwd"] as? String ?? info["cwd"] as? String
                    if reported?.isEmpty != false, directoryRetries > 0 {
                        try await Task.sleep(for: .seconds(1))
                        return try await validateDestination(directoryRetries: directoryRetries - 1)
                    }
                    guard let reported,
                        URL(fileURLWithPath: reported).standardizedFileURL
                            == URL(fileURLWithPath: requested).standardizedFileURL
                    else {
                        throw QuickDraftError.message(
                            "Hermes did not confirm the selected project directory. Open the session to review it."
                        )
                    }
                }
                return runtime
            }
            let runtime = try await validateDestination(directoryRetries: creatingSession ? 10 : 0)
            if creatingSession, let path = draft.destination.projectPath,
                let preferred = ProjectPreferences.shared.modelID(path), let session = draft.destination.session
            {
                let workflow = HermesWorkflowRPC(client: client, profileID: draft.destination.profileID)
                let available = try DockModel.runtimeModelOptions(from: await workflow.modelOptions(runtime))
                guard let option = available.first(where: { $0.id == preferred }) else {
                    throw QuickDraftError.message(
                        "The preferred project model is unavailable. Open the new session and choose an available model. Your draft was kept."
                    )
                }
                try await workflow.setSessionModel(session, option: option)
            }

            if let old = draft.destination.runtimeID, old != runtime,
                draft.files.contains(where: \.uploaded)
            {
                throw QuickSubmissionFailure(
                    message:
                        "The session runtime changed after upload. Review its attachments before sending.",
                    uncertain: true)
            }
            draft.destination.runtimeID = runtime
            if draft.uploadMessageCount == nil {
                draft.uploadMessageCount = validatedCount
                draft.uploadDirectory = validatedDirectory
            }
            try progress(draft)
            scope["session_id"] = runtime
            for index in draft.files.indices where !draft.files[index].uploaded {
                guard try await validateDestination() == runtime else {
                    throw QuickSubmissionFailure(
                        message: "The destination changed while preparing attachments. Review the session.",
                        uncertain: draft.files.contains(where: \.uploaded))
                }
                let file = draft.files[index]
                let bytes = try await file.encoded()
                let method: HermesFeatureIDs.ID
                var params = scope
                switch file.kind {
                case .image:
                    method = .imageAttachBytes
                    params["content_base64"] = bytes
                    params["filename"] = file.name
                case .pdf:
                    method = .pdfAttach
                    params["content_base64"] = bytes
                    params["filename"] = file.name
                case .file:
                    method = .fileAttach
                    params["data_url"] = "data:application/octet-stream;base64,\(bytes)"
                    params["name"] = file.name
                }
                mutationInFlight = true
                let result = try await client.request(method.rawValue, params: params)
                if result["attached"] as? Bool == false {
                    throw QuickSubmissionFailure(
                        message: "Hermes rejected \(file.name). The file remains in the draft.",
                        uncertain: false)
                }
                guard result["attached"] as? Bool == true else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                switch file.kind {
                case .image:
                    guard let path = result["path"] as? String, !path.isEmpty else {
                        throw HermesGateway.GatewayError.malformedResponse
                    }
                    draft.files[index].uploadedPaths = [path]
                case .pdf:
                    guard let pages = result["pages"] as? [[String: Any]], !pages.isEmpty,
                        pages.allSatisfy({ ($0["path"] as? String)?.isEmpty == false })
                    else { throw HermesGateway.GatewayError.malformedResponse }
                    draft.files[index].uploadedPaths = pages.compactMap { $0["path"] as? String }
                case .file:
                    guard let ref = result["ref_text"] as? String, ref.hasPrefix("@file:"),
                        !ref.contains("\n")
                    else {
                        throw HermesGateway.GatewayError.malformedResponse
                    }
                    draft.files[index].reference = ref
                }
                draft.files[index].uploaded = true
                try progress(draft)
                mutationInFlight = false
            }
            let checkedRuntime = try await validateDestination()
            guard checkedRuntime == runtime else {
                throw QuickSubmissionFailure(
                    message: "The destination changed after upload. Review the session.", uncertain: true)
            }
            let material =
                ([ChatContext.prompt(draft.text, contexts: draft.contexts ?? [])] + draft.sources
                + draft.files.compactMap(\.reference)).filter {
                    !$0.isEmpty
                }.joined(separator: "\n\n")
            var prompt = scope
            let text = material.isEmpty ? "Review these attachments." : material
            prompt["text"] = draft.requestsVisualReply == false ? text : GenerativeUIIntegration.preparePrompt(text)
            if let directory = validatedDirectory, let beforeSubmit {
                await beforeSubmit(draft, directory)
                guard try await validateDestination() == runtime else {
                    throw QuickSubmissionFailure(
                        message: "The destination changed before submission. Review the session.",
                        uncertain: true)
                }
            }
            mutationInFlight = true
            let result = try await client.request(
                HermesFeatureIDs.ID.promptSubmit.rawValue, params: prompt)
            guard result["status"] as? String == "streaming" else {
                throw QuickSubmissionFailure(
                    message: "Hermes did not confirm an immediate turn. Review the session before resending.",
                    uncertain: true)
            }
            return draft
        } catch {
            if let failure = error as? QuickSubmissionFailure { throw failure }
            let ns = error as NSError
            let rejected = ns.domain == "Hermes" && ns.code == 1
            throw QuickSubmissionFailure(
                message: DockModel.safeUserDiagnostic(error.localizedDescription),
                uncertain: mutationInFlight && !rejected)
        }
    }

    /// Only confirmed, draft-owned paths are detached; an unknown upload is never guessed.
    static func detach(_ draft: QuickDraftRecord, client: HermesRPCClientProtocol) async throws {
        guard draft.delivery != .needsReview, let owner = draft.destination.sessionID else {
            throw QuickDraftError.message(
                "Review interrupted uploads in the workspace before discarding this draft.")
        }
        var scope: [String: Any] = ["session_id": owner, "omit_messages": true]
        if let profile = draft.destination.profileID { scope["profile"] = profile }
        let session = try await client.request(
            HermesFeatureIDs.ID.sessionResume.rawValue, params: scope)
        let runtime = session["session_id"] as? String ?? owner
        let info = session["info"] as? [String: Any] ?? [:]
        if let expected = draft.destination.profileID {
            let profile =
                session["profile"] as? String ?? info["profile_name"] as? String
                ?? info["profile"] as? String
            guard profile == expected else {
                throw QuickDraftError.message("Hermes did not confirm the attachment owner's profile.")
            }
        }
        guard
            DockModel.resumeResponseProvesSessionOwnership(
                requestedSessionID: owner, resolvedSessionID: runtime, result: session),
            session["running"] as? Bool != true, info["running"] as? Bool != true,
            runtime == draft.destination.runtimeID,
            let count = draft.uploadMessageCount, session["message_count"] as? Int == count,
            let directory = draft.uploadDirectory,
            (session["cwd"] as? String ?? info["cwd"] as? String) == directory
        else {
            throw QuickDraftError.message(
                "The session changed or is busy. Review its attachments in the workspace.")
        }
        for path in draft.files.flatMap(\.uploadedPaths) {
            var params: [String: Any] = ["session_id": runtime, "path": path]
            if let profile = draft.destination.profileID { params["profile"] = profile }
            let result = try await client.request(
                HermesFeatureIDs.ID.imageDetach.rawValue, params: params)
            guard result["detached"] as? Bool == true else {
                throw QuickDraftError.message("Hermes could not confirm attachment cleanup.")
            }
        }
    }
}
