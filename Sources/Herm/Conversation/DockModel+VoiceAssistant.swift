import AppKit
import Foundation

/// Shared screen context and spoken notices.
extension DockModel {
    // MARK: Turn context

    /// Prepares data only while this voice turn owns the submission.
    func voiceTurnExtras(for text: String, isCurrent: () -> Bool) async -> ([String], VoiceScreenContext?, Data?) {
        var extras = currentConversationApproval?.resolved == true ? [VoicePrompts.closedApprovalGuidance] : []
        if VoicePrompts.asksForBriefing(text), let briefingFacts, isCurrent() {
            extras += await briefingFacts().promptLines
        }
        guard isCurrent(), VoiceScreenContext.isEnabled, VoicePrompts.refersToScreen(text),
            let application = DesktopCaptureService.shared.voiceFrontApplication
        else { return (extras, nil, nil) }

        let context = await DesktopCaptureService.frontContext(of: application)
        guard isCurrent() else { return ([], nil, nil) }
        let jpeg =
            VoicePrompts.requestsScreenshot(text) ? await DesktopCaptureService.voiceWindowJPEG(of: application) : nil
        return (extras, context, jpeg)
    }

    /// A file reference goes in the owning turn's prompt, never in the session's next-image queue.
    func stageVoiceScreenshot(_ jpeg: Data, scope: [String: Any], isCurrent: () -> Bool) async -> String? {
        guard isCurrent() else { return nil }
        do {
            let result = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.fileAttach.rawValue,
                params: scope.merging([
                    "data_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())", "name": "screen.jpg",
                ]) { _, new in new })
            guard isCurrent(), result["attached"] as? Bool == true, let reference = result["ref_text"] as? String,
                reference.hasPrefix("@file:"), reference.count > "@file:".count,
                reference.rangeOfCharacter(from: .newlines) == nil
            else { return nil }
            return reference
        } catch {
            DebugLog.write(
                "voice: screenshot upload failed: " + HermesDiagnosticsService.safeSummary(error.localizedDescription))
            return nil
        }
    }

    // MARK: Spoken notices

    /// A notice about this chat, said aloud only when no call is open; a call already
    /// speaks its own replies and approval prompts.
    func announceNoticeAloud(_ notice: HermNotice) {
        guard voiceState == .inactive,
            let line = VoiceAnnouncer.line(for: notice.kind)
        else { return }
        offerVoiceAnnouncement(line, notice: notice, urgent: notice.kind.blocking)
    }

    /// In a call, the line waits for the next playback boundary or quiet gap. With no
    /// call open it plays through the local Mac voice when `VoiceAnnouncer` allows it.
    func offerVoiceAnnouncement(_ line: String, notice: HermNotice, urgent: Bool = false) {
        if let target = notchVoiceNoticeTarget, target.voiceState.isNativeConversationActive {
            target.offerVoiceAnnouncement(line, notice: notice, urgent: urgent)
            return
        }
        if voiceState.isNativeConversationActive, voiceState != .paused {
            guard voiceRepliesEnabled, !voiceCompletionAnnouncements.contains(line) else { return }
            voiceCompletionAnnouncements.append(line)
            speakPendingVoiceAnnouncements()
            return
        }
        let now = Date()
        guard
            VoiceAnnouncer.shouldSpeak(
                enabled: VoiceAnnouncer.isEnabled, wakeWord: VoiceWakeShortcut.wakeWordEnabled,
                quiet: interruptionCoordinator?.quiet ?? false, screenLocked: VoiceAnnouncer.isScreenLocked,
                lastSpoke: voiceAnnouncedAt, now: now, urgent: urgent),
            interruptionCoordinator?.admit(notice, channel: .voice) != false
        else { return }
        voiceAnnouncedAt = now
        VoiceEarcon.alert.play()
        voiceAnnouncementTask?.cancel()
        let playback = voiceAnnouncementPlayback
        voiceAnnouncementTask = Task { [weak self] in
            // Lets the sound land before the words.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            try? await playback.speak(line) { _ in }
            guard !Task.isCancelled else { return }
            self?.voiceAnnouncementTask = nil
        }
    }

    func stopVoiceAnnouncement() {
        voiceAnnouncementTask?.cancel()
        voiceAnnouncementTask = nil
        voiceAnnouncementPlayback.stop()
    }

    // MARK: Reminders

    /// The system delivers the reminder banner. Voice adds the optional spoken notice.
    func announceVoiceTimer(_ timer: VoiceTimer) {
        let stamp = String(Int(timer.due.timeIntervalSince1970))
        let notice = HermNotice(
            kind: .information, source: .routine, profileID: nil, sourceID: "voice-timer/\(timer.id)",
            eventID: stamp)
        offerVoiceAnnouncement(VoiceAnnouncer.reminderLine(timer.name), notice: notice, urgent: true)
    }
}
