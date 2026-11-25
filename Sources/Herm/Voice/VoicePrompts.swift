import Foundation

/// How voice mode reads approvals and clarify questions aloud, and how a
/// spoken reply maps back onto the answer Hermes expects.
enum VoicePrompts {
    static func knownApprovalDescription(_ approval: ApprovalPresentation) -> String? {
        if approval.detailIsCommand,
            approval.detail.wholeMatch(of: /computer_use: click at \(-?[0-9]+,\s*-?[0-9]+\)/) != nil
        {
            return "I need to click on the screen"
        }
        return nil
    }

    static func approvalSpeech(_ approval: ApprovalPresentation, explanation: String? = nil) -> String {
        if approval.smartDenied {
            return "A safety check blocked this action. Review the details in chat before deciding."
        }
        let fallback = approval.detailIsCommand ? "A command needs approval" : "An action needs approval"
        let description =
            knownApprovalDescription(approval)
            ?? spokenApprovalExplanation(explanation, approval: approval)
            ?? "\(fallback). Check the details in chat"
        // Keep the question fixed for echo handling. Never read aloud an approval choice.
        return "\(description). \(approvalQuestion)"
    }

    private static func spokenApprovalExplanation(_ explanation: String?, approval: ApprovalPresentation) -> String? {
        guard let line = explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
            line.contains(where: \.isLetter), line.count <= 140, !line.contains(where: \.isNewline),
            !line.contains(/[`_*#?!<>|;\/]/), !line.contains(/\(-?[0-9]+,\s*-?[0-9]+\)/),
            !line.contains(/(?:^|\s)-{1,2}[A-Za-z0-9]/),
            !approval.detailIsCommand || !line.localizedCaseInsensitiveContains(approval.detail),
            line.caseInsensitiveCompare("unknown") != .orderedSame,
            !tokens(line).contains(where: {
                ["yes", "no", "approve", "deny", "allow", "confirm", "session"].contains($0)
            })
        else { return nil }
        return line.trimmingCharacters(in: CharacterSet(charactersIn: ".\"“”"))
    }

    static func clarificationSpeech(question: String, choices: [String], multiSelect: Bool, progress: String?) -> String
    {
        var parts = [progress.map { $0 + "." }, question].compactMap { $0 }
        if !choices.isEmpty {
            let options = choices.prefix(6).enumerated().map { "\($0.offset + 1): \($0.element)." }
            parts.append("Your options are " + options.joined(separator: " "))
            if multiSelect { parts.append("You can pick more than one.") }
        }
        return parts.joined(separator: " ")
    }

    /// Uses the same removable context envelope as visual chat, without its
    /// large UI catalog. Hermes still owns persona, memory, tools and approvals.
    /// `visuals`: the plugin can serve the catalog and tab tool. With just `previews`,
    /// Herm can still display an ordinary Markdown table from the reply.
    /// `extras`: literal screen or briefing lines. Only the runtime's staged screenshot may add a reference.
    static func conversationPrompt(
        _ text: String, visuals: Bool = GenerativeUIIntegration.isEnabled && HermPlugin.isLoaded,
        previews: Bool = GenerativeUIIntegration.isEnabled, extras: [String] = [], screenshotReference: String? = nil
    ) -> String {
        let request = GenerativeUIIntegration.displayUserText(text)
        let screen: String
        if visuals {
            screen =
                "For results worth seeing (charts, comparisons, timelines, diagrams, findings, or maps), add one compact read-only herm-ui surface after the spoken summary. Use standard map, table, and comparison blocks so voice can navigate their data. Don’t invent data or read the blocks aloud. Fetch the rules with herm_reference \"herm.generative-ui\" once per session.\(asksToSee(request) ? " I asked to see something, so include the visual or a real media delivery." : "") Use herm_inspector only if I explicitly ask for a tab."
        } else if previews, !Set(tokens(request)).isDisjoint(with: ["diagram", "flowchart", "mindmap"]) {
            screen =
                "After the spoken summary, show one compact Mermaid diagram using only confirmed relationships. Do not open another tab."
        } else if previews, asksToSee(request) {
            screen =
                "For results that fit a table, add a short Markdown table of confirmed data after the spoken summary. Keep it here unless I ask to open a tab."
        } else {
            screen = "Avoid visual UI blocks unless requested."
        }
        var lines = [
            "This is a spoken conversation. Lead with useful information, without a separate acknowledgment or filler. Keep the spoken summary brief and without Markdown formatting. Do not announce tool calls, skills, or internal steps. \(screen) Use background delegation for substantial tasks when available. Report only confirmed results. Respect approval requirements. If I ask to retry a denied action, request fresh approval."
        ]
        if previews && asksToSee(request) { lines.append(RichFeatureRegistry.mediaGuidance) }
        if asksForReminder(request) { lines.append(reminderGuidance) }
        // Hermes expands context references before the model can treat this text as quoted data.
        lines += extras.map {
            VoiceScreenContext.sanitized($0, limit: 6_000).replacingOccurrences(of: "@", with: "＠")
        }.filter { !$0.isEmpty }
        if let screenshotReference, requestsScreenshot(request) {
            lines.append("Use vision_analyze to view the screenshot file for this request: \(screenshotReference)")
        }
        return request
            + "\n\n[Herm rendering context v1]\n" + lines.joined(separator: "\n") + "\n[/Herm rendering context]"
    }

    static let closedApprovalGuidance =
        "The previous approval is closed. If I explicitly ask to retry the action or ask for approval again, start a fresh attempt through the normal approval flow. Do not reuse the old approval, bypass a denial, or tell me to do it myself if you can ask again. If you cannot retry, explain the actual blocker."

    /// Hermes' cron treats a bare "10m" as repeating and never delivers a TUI session's job
    /// back to it, so Herm keeps the countdown and raises the alert itself.
    static let reminderGuidance =
        "For a reminder or timer, create one cronjob with schedule \"in 10m\" or an ISO timestamp, never a bare \"10m\" (that repeats); name it with what to remind me about. Herm shows the countdown and alerts me at that time."

    /// "Remind me to call Sam in 10 minutes", "set a timer for 5 minutes", "notify me at 3pm".
    /// ponytail: keyword match, like `asksToSee`.
    static func asksForReminder(_ spoken: String) -> Bool {
        let words = tokens(spoken)
        let set = Set(words)
        if !set.isDisjoint(with: ["remind", "reminder", "timer", "alarm", "countdown"]) { return true }
        let phrase = " " + words.joined(separator: " ") + " "
        let asks = [" notify me ", " ping me ", " alert me ", " tell me ", " let me know "].contains(
            where: phrase.contains)
        let units: Set = ["minute", "minutes", "min", "mins", "hour", "hours", "second", "seconds"]
        let timed =
            phrase.range(
                of: #" in (\d+|a|an|one|two|three|five|ten|fifteen|twenty|thirty) "#, options: .regularExpression)
            != nil && !set.isDisjoint(with: units)
        let clock = phrase.range(of: #" at \d{1,2}( \d{2})?( ?(am|pm))? "#, options: .regularExpression) != nil
        return asks && (timed || clock)
    }

    /// Access to the front app requires a request about a named screen or selection.
    static func refersToScreen(_ spoken: String) -> Bool {
        if requestsScreenshot(spoken) { return true }
        let phrase = tokens(spoken).joined(separator: " ")
        let action =
            #"^(?:(?:please|can you|could you) )?"#
            + #"(?:summari[sz]e|explain|translate|reply to|read|review|check|describe|what['’]s|what is) "#
        let target =
            #"(?:this (?:page|window|email|document|tab|article|screen)"#
            + #"|(?:the )?(?:selected|highlighted) (?:text|email|code|paragraph|selection)"#
            + #"|(?:on )?my screen|on the screen)(?: |$)"#
        return phrase.range(of: action + target, options: .regularExpression) != nil
    }

    static func requestsScreenshot(_ spoken: String) -> Bool {
        let phrase = tokens(spoken).joined(separator: " ")
        let pattern =
            #"^(?:(?:please|can you|could you) )?(?:attach|share|send|take|capture) (?:a |the )?screenshot"#
            + #"(?: of (?:this (?:window|app|page|tab)|my screen|the (?:front|current) (?:app|window)))?(?: please)?$"#
        return phrase.range(of: pattern, options: .regularExpression) != nil
    }

    static func endsVoice(_ spoken: String, acceptsPlainStop: Bool = false) -> Bool {
        let line = tokens(spoken).joined(separator: " ")
        return (acceptsPlainStop && line == "stop") || ["stop listening", "end voice", "end the call"].contains(line)
    }

    static func cancelsVoiceTask(_ spoken: String) -> Bool {
        ["cancel the task", "cancel this task", "cancel this request", "stop working"]
            .contains(tokens(spoken).joined(separator: " "))
    }

    static func silencesVoiceReply(_ spoken: String) -> Bool {
        ["stop talking", "stop speaking", "stop reading"].contains(tokens(spoken).joined(separator: " "))
    }

    /// "Good morning", "brief me", "what's my day look like", "what did I miss".
    static func asksForBriefing(_ spoken: String) -> Bool {
        // Only a standalone request may add private calendar and task details.
        var words = tokens(spoken)
        if words.first == "please" { words.removeFirst() }
        if words.last == "please" { words.removeLast() }
        let phrase = words.joined(separator: " ").replacingOccurrences(of: "’", with: "'")
        return [
            "good morning", "brief me", "brief me on my day", "give me a briefing", "give me my morning briefing",
            "what's my day", "what's my day like", "what's my day look like", "what does my day look like",
            "what is my day like", "what's on my calendar today", "catch me up", "what did i miss", "plan my day",
        ].contains(phrase)
    }

    /// Whether the spoken request is about seeing something, so its answer needs a visual.
    /// ponytail: keyword match; let the on-device model classify if phrasing slips through.
    static func asksToSee(_ spoken: String) -> Bool {
        let words = Set(tokens(spoken))
        let visual: Set = [
            "show", "see", "look", "compare", "comparison", "chart", "graph", "table", "list", "diagram",
            "map", "picture", "image", "photo", "visualize", "breakdown", "timeline", "options", "steps",
        ]
        return !words.isDisjoint(with: visual)
    }

    private static let approvalQuestion = "May I continue?"
    static let approvalVocabulary = ["Yes", "No", "Allow once", "I allow it", "Go ahead", "This session"]

    static func approvalAnswerHint(choices: [String], heard: String? = nil) -> String {
        let guidance: String
        if choices.contains(ApprovalChoice.once), choices.contains(ApprovalChoice.deny) {
            guidance = "Say “yes” to allow once or “no” to deny."
        } else if choices.contains(ApprovalChoice.once) {
            guidance = "Say “yes” to allow once."
        } else if choices.contains(ApprovalChoice.deny) {
            guidance = "Say “no” to deny."
        } else {
            guidance = "The approval is still pending."
        }
        guard let words = heard?.split(whereSeparator: \.isWhitespace).joined(separator: " "), !words.isEmpty
        else { return guidance }
        let short = words.count > 48 ? String(words.prefix(48)) + "…" : words
        return "Heard “\(short)”. \(guidance)"
    }

    /// Strip the current approval's exact readout even after output stops, since recognition can end later.
    /// Sharing words with the readout is not evidence of echo.
    static func approvalAnswer(_ spoken: String, readout: String?) -> String? {
        let original = tokens(spoken)
        guard !original.isEmpty else { return nil }
        guard let readout, !readout.isEmpty else { return spoken }
        let reading = tokens(readout)
        var words = original[...]
        let question = tokens(approvalQuestion)
        var echoes = [reading]
        if reading.suffix(question.count).elementsEqual(question) {
            // A late mic can catch just the fixed question or its tail.
            echoes += [question, Array(question.dropFirst())]
        }
        // Do not remove arbitrary clauses: "yes if it's safe" is not consent
        // even if the explanation happened to say "if it's safe" too.
        for echo in echoes where !echo.isEmpty {
            if words.starts(with: echo) {
                words = words.dropFirst(echo.count)
                break
            }
            if words.suffix(echo.count).elementsEqual(echo) {
                words = words.dropLast(echo.count)
                break
            }
        }
        guard !words.isEmpty else { return nil }
        if reading.count >= words.count,
            (0...(reading.count - words.count)).contains(where: {
                reading[$0..<($0 + words.count)].elementsEqual(words)
            })
        {
            return nil
        }
        return words.elementsEqual(original) ? spoken : words.joined(separator: " ")
    }

    /// "always" is deliberately not voice-answerable: a misheard reply must not
    /// permanently allowlist a command. That choice stays on the card.
    static func approvalChoice(for spoken: String, choices: [String]) -> String? {
        let fillers: Set = ["uh", "um", "erm", "ah"]
        var decision = tokens(spoken).drop(while: fillers.contains)
        while let last = decision.last, fillers.contains(last) { decision = decision.dropLast() }
        let words = Set(decision)
        let repeatedReplies: Set = ["yes", "yeah", "yep", "no", "nope"]
        let phrase =
            words.count == 1 && decision.first.map(repeatedReplies.contains) == true
            ? decision.first ?? "" : decision.joined(separator: " ")
        let deny: Set = [
            "no", "nope", "nah", "deny", "deny it", "stop", "stop it", "cancel", "cancel it",
            "reject", "reject it", "decline", "do not", "do not run it", "do not run that", "do not continue",
            "do not do it", "do not allow it", "do not approve it",
        ]
        // Denial is a decision too. "I don't want to click" must not deny the action.
        let negative = (phrase.hasPrefix("no ") ? String(phrase.dropFirst(3)) : phrase)
            .replacing(/\bdon['’]?t\b/, with: "do not")
        if phrase == "no thanks" || deny.contains(negative) {
            return choices.contains(ApprovalChoice.deny) ? ApprovalChoice.deny : nil
        }
        let session: Set = [
            "this session", "allow this session", "allow for this session", "allow it for this session",
        ]
        if session.contains(phrase), choices.contains(ApprovalChoice.session) { return ApprovalChoice.session }
        let allow: Set = [
            "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "approve", "allow", "proceed",
            "go ahead", "yes go ahead", "yeah go ahead", "yes please", "allow once", "allow it",
            "yes do it", "do it", "run it", "yes run it", "i allow it", "i approve it", "yes i allow it",
            "yeah i allow it", "yes yes i allow it", "yes i approve it", "yes you may", "yes you can",
            "you may continue", "i'll allow it", "i’ll allow it", "i will allow it", "yes allow it",
            "allow it once", "i allow it once",
        ]
        if choices.contains(ApprovalChoice.once), repeatsOnlyAllowOnce(decision, phrases: allow) {
            return ApprovalChoice.once
        }
        return nil
    }

    private static func repeatsOnlyAllowOnce(_ words: ArraySlice<String>, phrases: Set<String>) -> Bool {
        guard !words.isEmpty, words.count <= 18 else { return false }
        var remaining = words
        while !remaining.isEmpty {
            guard
                let length = (1...min(6, remaining.count)).reversed().first(where: {
                    phrases.contains(remaining.prefix($0).joined(separator: " "))
                })
            else { return false }
            remaining = remaining.dropFirst(length)
        }
        return true
    }

    /// Recognize independent questions or requests without promoting ambiguous consent into a new turn.
    static func isSeparateRequestDuringApproval(_ spoken: String) -> Bool {
        let words = tokens(spoken).drop(while: { ["also", "and", "please", "um", "uh"].contains($0) })
        let approvalWords: Set<String> = [
            "yes", "yeah", "yep", "no", "nope", "allow", "approve", "approval", "deny", "permission", "command",
        ]
        guard let first = words.first, words.count > 1, approvalWords.isDisjoint(with: words) else { return false }
        let refersToPendingAction =
            !Set(["it", "that", "this", "same"]).isDisjoint(with: words)
            && !Set(["run", "execute", "do", "proceed", "continue", "retry"]).isDisjoint(with: words)
        guard !refersToPendingAction else { return false }
        let requestStarts: Set<String> = [
            "show", "find", "search", "look", "tell", "check", "read", "summarize", "list", "compare", "explain",
            "write", "make", "review", "open", "play", "run", "what", "what's", "what’s", "where", "when", "who",
            "how", "why", "which",
        ]
        let prefix = words.prefix(2).joined(separator: " ")
        let requestQuestions = ["can you", "could you", "would you", "will you"]
        return requestStarts.contains(first) || requestQuestions.contains(prefix)
            || words.starts(with: ["i", "want", "you", "to"])
    }

    static func clarificationHint(choices: [String], multiSelect: Bool, heard: String? = nil) -> String {
        let hint =
            choices.isEmpty
            ? "Say your answer."
            : multiSelect
                ? "Say the option names or numbers, joined by “and.”"
                : "Say an option name or “option one.”"
        guard let heard else { return hint }
        return "Heard “\(String(heard.prefix(48)))”. \(hint)"
    }

    private static let clarifyLeads = [
        "let's go with", "let’s go with", "i'll go with", "i’ll go with", "i would like", "go with",
        "i choose", "i pick", "i select", "choose", "pick", "select", "use", "option", "choice", "number",
    ]

    /// During narration, require a selection the prompt isn't saying itself, such as "option two".
    /// After playback, the user may simply say an option name.
    static func clarificationUtterance(_ heard: String, readout: String?, overPlayback: Bool) -> String? {
        let original = tokens(heard)
        guard !original.isEmpty else { return nil }
        guard let readout else { return overPlayback ? nil : heard }
        func normalizedNumbers(_ words: [String]) -> [String] {
            words.map { ordinals[$0].map { String($0 + 1) } ?? $0 }
        }
        let spoken = normalizedNumbers(original)
        let cues = ([readout] + VoiceSubtitleTrack.cues(from: VoiceSpeechText.prepare(readout)))
            .map { normalizedNumbers(tokens($0)) }
        var answer = original[...]
        for cue in cues where !cue.isEmpty {
            if spoken.starts(with: cue) {
                answer = answer.dropFirst(cue.count)
                break
            }
            if spoken.suffix(cue.count).elementsEqual(cue) {
                answer = answer.dropLast(cue.count)
                break
            }
        }
        guard !answer.isEmpty else { return nil }
        if overPlayback {
            let phrase = answer.drop(while: { $0 == "the" }).joined(separator: " ")
            guard clarifyLeads.contains(where: { phrase.hasPrefix($0 + " ") }) else { return nil }
            let remaining = normalizedNumbers(Array(answer))
            let reading = normalizedNumbers(tokens(readout))
            if reading.count >= remaining.count,
                (0...(reading.count - remaining.count)).contains(where: {
                    reading[$0..<($0 + remaining.count)].elementsEqual(remaining)
                })
            {
                return nil
            }
        }
        return answer.elementsEqual(original) ? heard : answer.joined(separator: " ")
    }

    typealias ClarificationAnswer = (answer: String, display: String, pickedOption: Bool)

    /// Resolve the whole spoken selection, not a substring such as "Production" in "not Production".
    /// Custom responses still work; "my answer is…" disambiguates short custom text.
    static func clarificationAnswer(
        for spoken: String, choices: [String], multiSelect: Bool
    ) -> ClarificationAnswer? {
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tokens(text).isEmpty else { return nil }
        func result(_ selected: [String], pickedOption: Bool = false) -> ClarificationAnswer {
            (
                multiSelect ? ClarifyQuestion.multiSelectAnswer(selected) : selected[0],
                selected.joined(separator: ", "), pickedOption
            )
        }
        if let lead = text.range(of: #"^my answer is[\s,:]+"#, options: [.regularExpression, .caseInsensitive]) {
            let custom = String(text[lead.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return tokens(custom).isEmpty ? nil : result([custom])
        }
        if choices.isEmpty { return result([text]) }

        func selection(_ phrase: String) -> String? {
            var words = Array(tokens(phrase).drop(while: { ["uh", "um", "please"].contains($0) }))
            if words.last == "please" { words.removeLast() }
            let exact = choices.filter { tokens($0) == words }
            if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
            for lead in clarifyLeads where words.starts(with: tokens(lead)) {
                if ["option", "choice", "number"].contains(lead) { break }
                words = Array(words.dropFirst(tokens(lead).count))
                break
            }
            let names = choices.filter { tokens($0) == words }
            if !names.isEmpty { return names.count == 1 ? names[0] : nil }

            if words.first == "the" { words.removeFirst() }
            let selectors = ["option", "choice", "number"]
            let specified = words.first.map(selectors.contains) == true
            if specified {
                words.removeFirst()
                if words.first == "number" { words.removeFirst() }
            }
            if words.count == 2, let last = words.last, (selectors + ["one"]).contains(last) { words.removeLast() }
            guard words.count == 1, let word = words.first else { return nil }
            let homophone = specified ? ["to": 1, "too": 1, "for": 3][word] : nil
            let digits = word.prefix(while: \.isNumber)
            let number =
                ["", "st", "nd", "rd", "th"].contains(String(word.dropFirst(digits.count))) ? Int(digits) : nil
            guard
                let index = ordinals[word] ?? homophone
                    ?? number.flatMap({ (1...choices.count).contains($0) ? $0 - 1 : nil }),
                choices.indices.contains(index)
            else { return nil }
            return choices[index]
        }

        if let answer = selection(text) { return result([answer], pickedOption: true) }
        if multiSelect {
            let parts = text.replacingOccurrences(of: ",", with: " and ")
                .replacing(/\s+and\s+/, with: "\n").split(separator: "\n")
            let picked = parts.compactMap { selection(String($0)) }
            if parts.count > 1, picked.count == parts.count {
                var seen = Set<String>()
                return result(picked.filter { seen.insert($0).inserted }, pickedOption: true)
            }
        }
        let words = tokens(text)
        let line = " " + words.joined(separator: " ") + " "
        let mentionsChoice = choices.contains { choice in
            let name = tokens(choice)
            return !name.isEmpty && line.contains(" " + name.joined(separator: " ") + " ")
        }
        let looksNumbered =
            words.contains { ordinals[$0] != nil }
            && words.allSatisfy { ordinals[$0] != nil || ["the", "please"].contains($0) }
        guard words.count > 2, !mentionsChoice, !looksNumbered,
            !words.contains(where: { ["option", "choice", "number", "and", "or"].contains($0) }),
            !clarifyLeads.contains(where: { line.hasPrefix(" " + $0 + " ") })
        else { return nil }
        return result([text])
    }

    /// What follows "hey <name>" in a sleeping utterance: nil when the wake
    /// phrase was not said, empty when it was said on its own.
    static func afterWakePhrase(_ spoken: String, name: String) -> String? {
        let pattern =
            #"^\s*(hey|hi|hello|ok|okay)[\s,]+"# + NSRegularExpression.escapedPattern(for: name) + #"\b[\s,.:;!?…–—-]*"#
        guard let range = spoken.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(spoken[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func afterWakePhrase(_ spoken: String, names: [String]) -> String? {
        for name in names.sorted(by: { $0.count > $1.count }) {
            if let request = afterWakePhrase(spoken, name: name) { return request }
        }
        return nil
    }

    /// Once awake, an address alone leaves the call listening for a request.
    static func removingVoiceAddress(_ spoken: String, names: [String]) -> String {
        afterWakePhrase(spoken, names: names) ?? spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Close", "hide that", "close the preview": the whole utterance is the command.
    static func isClosePreview(_ spoken: String) -> Bool {
        let filler: Set = [
            "the", "it", "that", "this", "please", "preview", "screen", "map", "chart", "table", "calendar", "agenda",
        ]
        let words = tokens(spoken).filter { !filler.contains($0) }
        return words.count == 1 && ["close", "hide", "dismiss"].contains(words[0])
    }

    /// "Open the browser", "show me the terminal": the whole utterance asks for one inspector tab.
    static func revealedTab(_ spoken: String) -> SessionInspector.Section? {
        let filler: Set = ["the", "please", "me", "my", "a", "can", "could", "you", "up", "tab", "panel", "pane"]
        let words = tokens(spoken).filter { !filler.contains($0) }
        let tabs = [
            "browser": "browser", "terminal": "terminal", "files": "files", "explorer": "files",
            "changes": "changes", "diff": "diff", "timeline": "timeline", "artifacts": "artifacts",
        ]
        guard words.count == 2, ["open", "show", "view"].contains(words[0]), let tab = tabs[words[1]] else {
            return nil
        }
        return SessionInspector.Section(agentTab: tab)
    }

    /// "Switch to Cypher", "talk to Cypher", "let me talk to the Cypher bot": the roster index of
    /// the Bot asked for, else nil. Names match loosely, since a recognizer spells "Cypher" as "cipher".
    static func botSwitchTarget(_ spoken: String, among names: [String]) -> Int? {
        guard let asked = botSwitchRequest(spoken)?.name else { return nil }
        let key = soundKey(tokens(asked).joined())
        return names.firstIndex { soundKey(tokens($0).joined()) == key }
    }

    /// The name asked for in "switch to <name>", and whether the phrasing can only
    /// mean switching ("switch to", "talk to") rather than "get"/"call" requests.
    static func botSwitchRequest(_ spoken: String) -> (name: String, explicit: Bool)? {
        let filler: Set = [
            "the", "please", "bot", "agent", "now", "instead", "over", "me", "let", "can", "i", "could", "you",
        ]
        let words = tokens(spoken).filter { !filler.contains($0) }
        let explicit: [[String]] = [
            ["switch", "to"], ["talk", "to"], ["speak", "to"], ["hand", "to"], ["pass", "to"],
        ]
        let loose: [[String]] = [["go", "to"], ["get"], ["call"]]
        guard let lead = (explicit + loose).first(where: { words.starts(with: $0) }) else { return nil }
        let rest = words.dropFirst(lead.count)
        guard (1...3).contains(rest.count) else { return nil }
        return (rest.joined(separator: " "), explicit.contains(lead))
    }

    /// Hermes' recorder error when its per-session voice mode is off.
    static func isVoiceModeOff(_ error: String) -> Bool {
        let text = error.lowercased()
        return text.contains("voice mode is off") || text.contains("/voice on")
    }

    static func botNotFound(_ name: String) -> String {
        "I couldn't find a Bot named \(name)."
    }

    /// A rough sound-alike key: y/i and ph/f, c/k/s before soft sounds, doubled letters, and silent e.
    static func soundKey(_ word: String) -> String {
        var key = word.lowercased()
            .replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "ck", with: "k")
            .replacingOccurrences(of: "y", with: "i")
        key = String(key.map { $0 == "c" || $0 == "z" ? "s" : $0 == "q" ? "k" : $0 })
        key = key.reduce(into: "") { if $0.last != $1 { $0.append($1) } }
        if key.count > 3, key.hasSuffix("e") { key.removeLast() }
        return key
    }

    /// Short utterances that mention a panel or hiding: worth asking the on-device
    /// model whether they are a local command. Everything else skips that wait.
    static func mayBeLocalCommand(_ spoken: String) -> Bool {
        let words = tokens(spoken)
        let cues: Set = [
            "close", "hide", "dismiss", "away", "rid", "browser", "terminal", "files", "explorer", "changes", "diff",
            "timeline", "artifacts", "tab", "panel", "pane", "preview",
        ]
        return words.count <= 8 && words.contains(where: cues.contains)
    }

    /// Whether speech heard over a spoken reply is the user cutting in rather
    /// than the reply echoing back from the speakers.
    /// ponytail: word-overlap echo filter; use voice-processing AEC if speakers still trip it.
    static func isBargeIn(_ heard: String, over reply: String) -> Bool {
        let words = tokens(heard)
        let replyWords = Set(tokens(reply))
        let foreign = words.filter { !replyWords.contains($0) }
        let cutIns: Set = ["stop", "wait", "hold", "pause", "enough", "cancel", "quiet", "shut", "no", "hey"]
        if foreign.contains(where: cutIns.contains) { return true }
        // Echo cancellation already removes most of the reply, so two words of your own
        // are enough: the reply stops while you are still mid-sentence, not after it.
        return words.count >= 2 && foreign.count * 2 > words.count
    }

    /// Mostly the reply's own words: the mic picked up the speakers.
    static func isEcho(_ heard: String, of reply: String) -> Bool {
        let words = tokens(heard)
        let replyWords = Set(tokens(reply))
        return !words.isEmpty && words.filter(replyWords.contains).count * 3 >= words.count * 2
    }

    private static let ordinals: [String: Int] = [
        "1": 0, "one": 0, "first": 0, "2": 1, "two": 1, "second": 1, "3": 2, "three": 2, "third": 2,
        "4": 3, "four": 3, "fourth": 3, "5": 4, "five": 4, "fifth": 4, "6": 5, "six": 5, "sixth": 5,
        "seven": 6, "seventh": 6, "eight": 7, "eighth": 7, "nine": 8, "ninth": 8,
        "ten": 9, "tenth": 9, "eleven": 10, "eleventh": 10, "twelve": 11, "twelfth": 11,
    ]

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
    }
}
