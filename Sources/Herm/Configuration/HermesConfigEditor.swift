import SwiftUI

/// Hermes Desktop's curated config surface (apps/desktop settings `SECTIONS`,
/// `config-subpages.ts`, field copy and `ENUM_OPTIONS`), keyed by Dock
/// settings category. Values are read and written through the same
/// `/api/config` + `/api/config/schema` routes the Desktop uses.
enum HermesConfigCatalog {
    struct Field: Hashable {
        let key: String
        let label: String?
        let detail: String?
        init(_ key: String, _ label: String?, _ detail: String?) {
            self.key = key
            self.label = label
            self.detail = detail
        }
    }

    struct Page: Hashable {
        let title: String
        let fields: [Field]
    }

    // Omitted: `fallback_providers` (needs the provider/model picker) and
    // `desktop.*` (configures the Electron app only).
    static let pages: [SettingsCategory: [Page]] = [
        .runtime: [
            Page(title: "Main model", fields: [
                .init("model_context_length", "Main model context window (override)", "Overrides the detected context window of the MAIN chat model only (tokens). Leave at 0 to use the selected model's detected value. Does not affect auxiliary/MoA models."),
            ]),
        ],
        .chat: [
            Page(title: "Behavior", fields: [
                .init("display.personality", "Personality", "Default assistant style for new sessions."),
                .init("timezone", "Timezone", "IANA timezone identifier. Blank uses the system timezone."),
                .init("display.show_reasoning", "Reasoning Blocks", "Show reasoning sections when the backend provides them."),
            ]),
            Page(title: "Attachments", fields: [
                .init("agent.image_input_mode", "Image Attachments", "Controls how image attachments are sent to the model."),
            ]),
        ],
        .workspace: [
            Page(title: "Projects & discovery", fields: [
                .init("terminal.cwd", "Working Directory", "Default project folder for tool and terminal work."),
            ]),
            Page(title: "Shell environment", fields: [
                .init("terminal.persistent_shell", "Persistent Shell", "Keep shell state between commands when the backend supports it."),
                .init("terminal.env_passthrough", "Environment Passthrough", "Environment variables to pass into tool execution."),
            ]),
            Page(title: "Files & execution", fields: [
                .init("code_execution.mode", "Code Execution Mode", "How strictly code execution is scoped to the current project."),
                .init("file_read_max_chars", "File Read Limit", "Maximum characters Hermes can read from one file request."),
            ]),
        ],
        .safety: [
            Page(title: "Approvals", fields: [
                .init("approvals.mode", "Approval Mode", "How Hermes handles commands that need explicit approval."),
                .init("approvals.timeout", "Approval Timeout", "How long approval prompts wait before timing out."),
                .init("approvals.mcp_reload_confirm", "Confirm MCP Reloads", nil),
                .init("command_allowlist", "Command Allowlist", nil),
            ]),
            Page(title: "Privacy & network", fields: [
                .init("security.redact_secrets", "Redact Secrets", "Hide detected secrets from model-visible content when possible."),
                .init("security.allow_private_urls", "Allow Private URLs", nil),
            ]),
            Page(title: "Checkpoints", fields: [
                .init("checkpoints.enabled", "File Checkpoints", "Create rollback snapshots before file edits."),
            ]),
        ],
        .browser: [
            Page(title: "Browser profile", fields: [
                .init("browser.use_real_profile", "Use My Real Browser Profile", "Local browsing uses your real logins. Hermes copies your default browser's profile (cookies, logins, preferences) into a managed snapshot and drives it with its packaged Chromium — your live profile is never opened directly, and the copy is refreshed from it on each run. Also lets the agent open a local real-profile session on request even when a cloud browser backend is configured. Only Chromium browsers (Chrome, Edge, Brave, Brave Origin, Chromium) are supported; a non-Chromium default fails with a clear message. Off by default."),
            ]),
            Page(title: "Local & private URLs", fields: [
                .init("browser.allow_private_urls", "Browser Private URLs", nil),
                .init("browser.auto_local_for_private_urls", "Local Browser For Private URLs", nil),
            ]),
        ],
        .memory: [
            Page(title: "Persistent memory", fields: [
                .init("memory.memory_enabled", "Persistent Memory", "Save durable memories that can help future sessions."),
                .init("memory.user_profile_enabled", "User Profile", "Maintain a compact profile of user preferences."),
                .init("memory.memory_char_limit", "Memory Budget", nil),
                .init("memory.user_char_limit", "Profile Budget", nil),
                .init("memory.provider", "Memory Provider", nil),
            ]),
            Page(title: "Context & compression", fields: [
                .init("context.engine", "Context Engine", "Strategy for managing long conversations near the context limit."),
                .init("compression.enabled", "Auto-Compression", "Summarize older context when conversations get large."),
                .init("compression.threshold", "Compression Threshold", nil),
                .init("compression.codex_gpt55_autoraise", "Codex Compression Auto-Raise", "Raise compression to 85% for supported ChatGPT Codex OAuth models."),
                .init("compression.target_ratio", "Compression Target", nil),
                .init("compression.protect_last_n", "Protected Recent Messages", nil),
                .init("auxiliary.compression.timeout", "Compression model timeout (s)", "Seconds to wait for the auxiliary compression model per call (default 120). Raise for slow local models."),
            ]),
        ],
        .voice: [
            Page(title: "Voice conversation", fields: [
                .init("voice.voice_chat_mode", "Voice Chat Mode", "chained: speech-to-text → Hermes → text-to-speech with the providers below. gpt-live: one full-duplex OpenAI voice model (gpt-live-1) listens and talks, and hands every real request to Hermes — any model you have selected answers with the full toolset. Needs an OpenAI API key; the voice layer bills $0.05 per minute."),
                .init("voice.gpt_live.voice", "GPT-Live Voice", "Voice for GPT-Live mode. Custom voice IDs are accepted."),
                .init("voice.gpt_live.instructions", "GPT-Live Persona", "Extra sentences for the live voice persona (tone, pace, language). Hermes keeps its own system prompt."),
                .init("voice.record_key", "Voice Shortcut", nil),
                .init("voice.max_recording_seconds", "Max Recording Length", nil),
                .init("voice.client_direct", nil, nil),
            ]),
            Page(title: "Speech to text", fields: [
                .init("stt.enabled", "Speech To Text", "Enable local or provider-backed speech transcription."),
                .init("stt.echo_transcripts", "Echo Transcripts", "Post the raw 🎙️ transcript of voice messages back to the chat."),
                .init("stt.provider", "Speech-To-Text Provider", nil),
                .init("stt.local.model", "Local Transcription Model", nil),
                .init("stt.local.language", "Transcription Language", nil),
                .init("stt.openai.model", "OpenAI STT Model", nil),
                .init("stt.groq.model", "Groq STT Model", nil),
                .init("stt.mistral.model", "Mistral STT Model", nil),
                .init("stt.elevenlabs.model_id", "ElevenLabs STT Model", nil),
                .init("stt.elevenlabs.language_code", "ElevenLabs Language", "Optional ISO-639-3 language code. Blank lets ElevenLabs auto-detect."),
                .init("stt.elevenlabs.tag_audio_events", "Tag Audio Events", nil),
                .init("stt.elevenlabs.diarize", "Speaker Diarization", nil),
            ]),
            Page(title: "Text to speech", fields: [
                .init("tts.provider", "Text-To-Speech Provider", nil),
                .init("voice.auto_tts", "Read Responses Aloud", "Automatically speak assistant responses."),
                .init("tts.edge.voice", "Edge Voice", nil),
                .init("tts.openai.model", "OpenAI TTS Model", nil),
                .init("tts.openai.voice", "OpenAI Voice", nil),
                .init("tts.elevenlabs.voice_id", "ElevenLabs Voice", nil),
                .init("tts.elevenlabs.model_id", "ElevenLabs Model", nil),
                .init("tts.xai.voice_id", "xAI (Grok) Voice", "xAI voice ID (e.g. eve) or a custom voice ID."),
                .init("tts.xai.language", "xAI Language", "Spoken language code (e.g. en, pt-BR) or \"auto\" for auto-detection."),
                .init("tts.xai.speed", "xAI Playback Speed", "Playback speed. 0.7 = slower, 1.0 = normal, 1.5 = faster."),
                .init("tts.xai.auto_speech_tags", "xAI Auto Speech Tags", "Let an LLM insert expressive audio tags ([laughing], [sighs]) into the script before synthesis."),
                .init("tts.xai.optimize_streaming_latency", "xAI Streaming Latency Optimization", "Latency vs. quality trade-off. 0 = best quality, 2 = lowest latency."),
                .init("tts.xai.sample_rate", "xAI Sample Rate", "Audio sample rate in Hz. Higher = better quality, larger files."),
                .init("tts.xai.bit_rate", "xAI Bit Rate", "MP3 bitrate in bps. Only applies when codec is mp3."),
                .init("tts.minimax.model", "MiniMax TTS Model", nil),
                .init("tts.minimax.voice_id", "MiniMax Voice", nil),
                .init("tts.mistral.model", "Mistral TTS Model", nil),
                .init("tts.mistral.voice_id", "Mistral Voice", nil),
                .init("tts.gemini.model", "Gemini TTS Model", nil),
                .init("tts.gemini.voice", "Gemini Voice", nil),
                .init("tts.neutts.model", "NeuTTS Model", nil),
                .init("tts.neutts.device", "NeuTTS Device", "Local inference device for NeuTTS."),
                .init("tts.kittentts.model", "KittenTTS Model", nil),
                .init("tts.kittentts.voice", "KittenTTS Voice", nil),
                .init("tts.piper.voice", "Piper Voice", nil),
                .init("tts.deepinfra.model", "DeepInfra TTS Model", nil),
                .init("tts.deepinfra.voice", "DeepInfra Voice", nil),
            ]),
        ],
        .advanced: [
            Page(title: "Desktop & startup", fields: [
                .init("updates.non_interactive_local_changes", "In-App Update Local Changes", "When Hermes updates itself from the app (no terminal prompt), keep local source edits (stash) or throw them away (discard). Terminal updates always ask."),
            ]),
            Page(title: "Agent limits", fields: [
                .init("agent.max_turns", "Max Agent Steps", "Upper bound for tool-calling turns before Hermes stops a run."),
                .init("agent.api_max_retries", "API Retries", nil),
                .init("agent.service_tier", "Service Tier", nil),
            ]),
            Page(title: "Tool access", fields: [
                .init("toolsets", "Enabled Toolsets", nil),
                .init("agent.tool_use_enforcement", "Tool-Use Enforcement", nil),
            ]),
            Page(title: "Terminal backend", fields: [
                .init("terminal.backend", "Execution Backend", nil),
                .init("terminal.timeout", "Command Timeout", nil),
                .init("terminal.docker_image", "Docker Image", "Container image used when the execution backend is Docker."),
                .init("terminal.singularity_image", "Singularity Image", "Image used when the execution backend is Singularity."),
                .init("terminal.modal_image", "Modal Image", "Image used when the execution backend is Modal."),
                .init("terminal.daytona_image", "Daytona Image", "Image used when the execution backend is Daytona."),
            ]),
            Page(title: "Subagents", fields: [
                .init("delegation.model", "Subagent Model", nil),
                .init("delegation.provider", "Subagent Provider", nil),
                .init("delegation.max_iterations", "Subagent Turn Limit", nil),
                .init("delegation.max_concurrent_children", "Parallel Subagents", nil),
                .init("delegation.child_timeout_seconds", "Subagent Timeout", nil),
                .init("delegation.reasoning_effort", "Subagent Reasoning Effort", nil),
            ]),
            Page(title: "Output limits", fields: [
                .init("tool_output.max_bytes", "Terminal Output Limit", nil),
                .init("tool_output.max_lines", "File Page Limit", nil),
                .init("tool_output.max_line_length", "Line Length Limit", nil),
                .init("checkpoints.max_snapshots", "Checkpoint Limit", nil),
            ]),
        ],
    ]

    /// Desktop `ENUM_OPTIONS`: suggestions for keys the schema types as free text.
    static let enumOptions: [String: [String]] = [
        "agent.image_input_mode": ["auto", "native", "text"],
        "approvals.mode": ["manual", "smart", "off"],
        "code_execution.mode": ["project", "strict"],
        "context.engine": ["compressor", "default", "custom"],
        "delegation.reasoning_effort": ["", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"],
        "terminal.backend": ["local", "docker", "singularity", "modal", "daytona", "ssh"],
        "stt.elevenlabs.model_id": ["scribe_v2", "scribe_v1"],
        "stt.local.model": ["tiny", "base", "small", "medium", "large-v3"],
        "stt.provider": ["local", "groq", "openai", "mistral", "xai", "elevenlabs"],
        "voice.voice_chat_mode": ["chained", "gpt-live"],
        "voice.gpt_live.voice": ["marin", "cedar", "quartz", "ripple", "vesper", "willow", "stone", "gleam", "meridian", "bossa", "tempo", "beacon", "delta", "cinder"],
        "tts.openai.voice": ["alloy", "ash", "ballad", "cedar", "coral", "echo", "fable", "marin", "nova", "onyx", "sage", "shimmer", "verse"],
        "tts.edge.voice": ["en-US-AriaNeural", "en-US-JennyNeural", "en-US-AndrewNeural", "en-US-BrianNeural", "en-US-GuyNeural", "en-GB-SoniaNeural"],
        "tts.gemini.model": ["gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"],
        "tts.gemini.voice": ["Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe", "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"],
        "tts.xai.voice_id": ["eve"],
        "tts.minimax.model": ["speech-02-hd", "speech-02-turbo"],
        "tts.mistral.model": ["voxtral-mini-tts-2603"],
        "tts.kittentts.model": ["KittenML/kitten-tts-nano-0.8-int8", "KittenML/kitten-tts-micro-0.8-int8", "KittenML/kitten-tts-mini-0.8-int8"],
        "tts.kittentts.voice": ["Jasper"],
        "tts.piper.voice": ["en_US-lessac-medium", "en_US-amy-medium", "en_US-ryan-high", "en_GB-alan-medium"],
        "tts.neutts.model": ["neuphonic/neutts-air-q4-gguf", "neuphonic/neutts-air-q8-gguf", "neuphonic/neutts-air"],
        "tts.provider": ["edge", "elevenlabs", "openai", "xai", "minimax", "mistral", "gemini", "neutts", "kittentts", "piper"],
        "stt.openai.model": ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe", "gpt-transcribe"],
        "stt.mistral.model": ["voxtral-mini-latest", "voxtral-mini-2602"],
        "tts.openai.model": ["gpt-4o-mini-tts", "tts-1", "tts-1-hd"],
        "tts.elevenlabs.model_id": ["eleven_v3", "eleven_ttv_v3", "eleven_multilingual_v2", "eleven_turbo_v2", "eleven_turbo_v2_5", "eleven_flash_v2", "eleven_flash_v2_5"],
        "tts.neutts.device": ["cpu", "cuda", "mps"],
        "updates.non_interactive_local_changes": ["stash", "discard"],
    ]

    static let builtinPersonalities: [String] = ["helpful", "concise", "technical", "creative", "teacher", "kawaii", "catgirl", "pirate", "shakespeare", "surfer", "noir", "uwu", "philosopher", "hype"]
}

/// Loads the Hermes config + schema over the local backend and saves one
/// field at a time as a partial `PUT /api/config` (the server deep-merges it).
@MainActor
final class HermesConfigEditor: ObservableObject {
    enum LoadState: Equatable { case idle, loading, ready, failed(String) }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var config: [String: Any] = [:]
    @Published private(set) var schema: [String: [String: Any]] = [:]
    @Published private(set) var savingKeys: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]

    private let rpc: () -> HermesControlRPC?

    init(rpc: @escaping () -> HermesControlRPC?) {
        self.rpc = rpc
    }

    func load() async {
        guard state != .loading else { return }
        guard let rpc = rpc() else {
            state = .failed("Hermes is not connected.")
            return
        }
        state = .loading
        do {
            let schemaJSON = try await rpc.fetchHTTP("/api/config/schema")
            let configJSON = try await rpc.fetchHTTP("/api/config")
            schema = schemaJSON["fields"] as? [String: [String: Any]] ?? [:]
            config = configJSON
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func value(_ key: String) -> Any? {
        Self.nested(config, key)
    }

    /// Schema type, inferred from the value for config-only keys like `stt.provider`.
    func type(of key: String) -> String {
        if let type = schema[key]?["type"] as? String { return type }
        switch value(key) {
        case is Bool: return "boolean"
        case is NSNumber: return "number"
        case is [Any]: return "list"
        default: return "string"
        }
    }

    func options(for key: String) -> [String]? {
        var options: [String]?
        if key == "display.personality" {
            let custom = (value("agent.personalities") as? [String: Any]).map { Array($0.keys).sorted() } ?? []
            options = [""] + HermesConfigCatalog.builtinPersonalities + custom
        } else {
            options = HermesConfigCatalog.enumOptions[key] ?? schema[key]?["options"] as? [String]
        }
        guard var options else { return nil }
        if let current = value(key) as? String, !current.isEmpty, !options.contains(current) {
            options.append(current)
        }
        var seen = Set<String>()
        return options.filter { seen.insert($0).inserted }
    }

    /// Desktop `voiceFieldVisible`: provider-specific TTS/STT fields only show
    /// for the selected provider (STT ones only while STT is enabled).
    func isVisible(_ key: String) -> Bool {
        let parts = key.split(separator: ".")
        guard parts.count >= 3, parts[0] == "tts" || parts[0] == "stt" else { return true }
        let domain = String(parts[0])
        if domain == "stt", (value("stt.enabled") as? Bool) != true { return false }
        let selected = (value("\(domain).provider") as? String).flatMap { $0.isEmpty ? nil : $0 }
        return String(parts[1]) == (selected ?? (domain == "tts" ? "edge" : "local"))
    }

    func set(_ key: String, _ newValue: Any) {
        guard let rpc = rpc() else {
            errors[key] = "Hermes is not connected."
            return
        }
        let previous = config
        config = Self.setting(config, key, newValue)
        savingKeys.insert(key)
        errors[key] = nil
        Task {
            do {
                _ = try await rpc.sendHTTP("PUT", path: "/api/config", body: ["config": Self.setting([:], key, newValue)])
            } catch {
                config = Self.setting(config, key, Self.nested(previous, key) ?? NSNull())
                errors[key] = error.localizedDescription
            }
            savingKeys.remove(key)
        }
    }

    nonisolated static func nested(_ root: [String: Any], _ key: String) -> Any? {
        var current: Any? = root
        for part in key.split(separator: ".") {
            current = (current as? [String: Any])?[String(part)]
        }
        return current is NSNull ? nil : current
    }

    nonisolated static func setting(_ root: [String: Any], _ key: String, _ value: Any) -> [String: Any] {
        let parts = key.split(separator: ".").map(String.init)
        guard let head = parts.first else { return root }
        var copy = root
        if parts.count == 1 {
            copy[head] = value
        } else {
            copy[head] = setting(root[head] as? [String: Any] ?? [:], parts.dropFirst().joined(separator: "."), value)
        }
        return copy
    }
}

struct HermesConfigCategoryView: View {
    @ObservedObject var editor: HermesConfigEditor
    let category: SettingsCategory

    var body: some View {
        let pages = HermesConfigCatalog.pages[category] ?? []
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: 17) {
                switch editor.state {
                case .idle, .loading:
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("READING HERMES CONFIG…").font(.system(size: 12)).tracking(0.6).foregroundStyle(Color.dockSecondaryText)
                    }
                case .failed(let message):
                    SettingsSection(title: "Hermes config unavailable", subtitle: "", tint: .dockWarning) {
                        Text(message).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
                        Button("Retry") { Task { await editor.load() } }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    }
                case .ready:
                    ForEach(pages, id: \.self) { page in
                        let fields = page.fields.filter { editor.isVisible($0.key) }
                        if !fields.isEmpty {
                            SettingsSection(title: page.title, subtitle: "", tint: .dockAccent) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(fields.enumerated()), id: \.element) { index, field in
                                        if index > 0 { Divider().overlay(Color.dockBorderLight) }
                                        HermesConfigFieldRow(editor: editor, field: field)
                                    }
                                }
                                .padding(.vertical, -8)
                            }
                        }
                    }
                }
            }
            .task { if editor.state == .idle { await editor.load() } }
        }
    }
}

private struct HermesConfigFieldRow: View {
    @ObservedObject var editor: HermesConfigEditor
    let field: HermesConfigCatalog.Field

    @State private var draft = ""
    @State private var listDraft = ""

    private var key: String { field.key }
    private var title: String {
        field.label ?? (editor.schema[key]?["description"] as? String) ?? key
    }
    private var detail: String {
        [field.detail, editor.errors[key]].compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        switch editor.type(of: key) {
        case "list":
            VStack(alignment: .leading, spacing: 6) {
                SettingsPreferenceRow(title: title, detail: detail) {
                    if listDraft != listText {
                        Button("Save") { editor.set(key, listItems(listDraft)) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    } else if editor.savingKeys.contains(key) {
                        ProgressView().controlSize(.small)
                    }
                }
                TextEditor(text: $listDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 54, maxHeight: 120)
                    .padding(6)
                    .background(Color.dockControlSurface)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.bottom, 10)
            }
            .onAppear { listDraft = listText }
            .onChange(of: listText) { _, text in listDraft = text }
        default:
            SettingsPreferenceRow(title: title, detail: detail) {
                HStack(spacing: 8) {
                    if editor.savingKeys.contains(key) { ProgressView().controlSize(.small) }
                    control
                }
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if editor.type(of: key) == "boolean" {
            Toggle("", isOn: Binding(
                get: { editor.value(key) as? Bool ?? false },
                set: { editor.set(key, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color.dockAccent)
        } else if let options = editor.options(for: key) {
            Picker("", selection: Binding(
                get: { stringValue },
                set: { editor.set(key, $0) }
            )) {
                if !options.contains(stringValue) { Text(stringValue.isEmpty ? "Default" : stringValue).tag(stringValue) }
                ForEach(options, id: \.self) { option in
                    Text(option.isEmpty ? "Default" : option).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 220)
        } else {
            TextField(editor.type(of: key) == "number" ? "0" : "Default", text: $draft)
                .textFieldStyle(.dockGlass)
                .multilineTextAlignment(editor.type(of: key) == "number" ? .trailing : .leading)
                .frame(width: editor.type(of: key) == "number" ? 90 : 220)
                .onAppear { draft = stringValue }
                .onChange(of: stringValue) { _, value in draft = value }
                .onSubmit(commitDraft)
        }
    }

    private var stringValue: String {
        switch editor.value(key) {
        case let number as NSNumber: return number.stringValue
        case let text as String: return text
        default: return ""
        }
    }

    private var listText: String {
        (editor.value(key) as? [Any] ?? []).map { "\($0)" }.joined(separator: "\n")
    }

    private func listItems(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func commitDraft() {
        guard draft != stringValue else { return }
        guard editor.type(of: key) == "number" else {
            editor.set(key, draft)
            return
        }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if let int = Int(trimmed) {
            editor.set(key, int)
        } else if let double = Double(trimmed) {
            editor.set(key, double)
        } else {
            draft = stringValue
        }
    }
}
