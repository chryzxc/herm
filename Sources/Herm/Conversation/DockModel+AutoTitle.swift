import Foundation

extension DockModel {
    /// Gives an untitled session an on-device title after its first reply. Hermes' own title always wins.
    func nameSessionIfUntitled(_ owner: String) {
        let enabled = UserDefaults.standard.object(forKey: OnDeviceAssist.nameSessionsKey) as? Bool ?? true
        guard enabled, currentSessionIDs.contains(owner), let sessionID, !autoTitleAttempts.contains(sessionID),
            let prompt = messages.first(where: { $0.role == .user })?.text, !prompt.isEmpty
        else { return }
        autoTitleAttempts.insert(sessionID)
        Task { @MainActor [weak self] in
            // Give Hermes a moment to name the session itself, then re-read what it chose.
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.sessionID == sessionID else { return }
            let titled =
                self.sessions.first { $0.id == sessionID }.map {
                    !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } ?? false
            guard !titled, self.currentSessionTitle == nil,
                let reply = self.messages.last(where: { $0.role == .hermes })?.text, !reply.isEmpty,
                let title = await OnDeviceAssist.titleSession(prompt: prompt, reply: reply),
                self.sessionID == sessionID
            else { return }
            if (try? await HermesControlRPC(client: self.controlRPCClient).setSessionTitle(
                sessionID: sessionID, title: title)) != nil
            {
                self.updateCurrentSessionTitle(title)
                self.loadSessions(quiet: true)
            }
        }
    }
}
