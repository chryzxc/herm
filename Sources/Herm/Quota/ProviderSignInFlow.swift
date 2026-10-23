import AppKit
import SwiftUI

/// What a provider login command is currently asking for, read from its output.
struct ProviderSignInPrompt: Equatable {
    var url: URL?
    var code: String?
    /// The command is waiting on stdin (a pasted authorization code, a Y/n).
    var needsInput = false
    var asksForCode = false
    /// `Added <provider> … credential #N: "<label>"`, Hermes' success line.
    var successLine: String?
    var accountLabel: String?

    /// `lines` are complete output lines; `partial` is a prompt printed
    /// without a newline (`Authorization code: `), which is what a command
    /// blocked on stdin leaves behind.
    static func parse(_ lines: [String], partial: String = "") -> Self {
        var prompt = Self()
        let all = lines + (partial.isEmpty ? [] : [partial])
        prompt.url = all.lazy.compactMap { links(in: $0).first?.url }.first
        prompt.code = all.lazy.compactMap(code(in:)).last
        if let success = lines.last(where: { $0.hasPrefix("Added ") || $0.hasPrefix("Saved ") }) {
            prompt.successLine = success
            prompt.accountLabel = success.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first.map(String.init)
        }
        // input() prompts never end in a newline, so only the partial line can be one.
        let waiting = partial.trimmingCharacters(in: .whitespaces)
        prompt.needsInput = waiting.hasSuffix(":") || waiting.hasSuffix("?")
        prompt.asksForCode = prompt.needsInput && waiting.lowercased().contains("code")
        return prompt
    }

    /// `Enter this code: ABCD-1234` / `If prompted, enter code: ABCD-1234`.
    static func code(in line: String) -> String? {
        guard let match = line.range(of: #"(?i)enter (this )?code:\s*[A-Z0-9][A-Z0-9-]{3,}"#, options: .regularExpression) else { return nil }
        return line[match].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func links(in line: String) -> [(range: Range<String.Index>, url: URL)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: line) else { return nil }
            return (range, url)
        }
    }

    /// The line with every URL as an underlined, clickable link.
    static func linked(_ line: String) -> AttributedString {
        var result = AttributedString()
        var cursor = line.startIndex
        for (range, url) in links(in: line) {
            result += AttributedString(line[cursor..<range.lowerBound])
            var link = AttributedString(line[range])
            link.link = url
            link.underlineStyle = .single
            link.foregroundColor = .dockAccent
            result += link
            cursor = range.upperBound
        }
        result += AttributedString(line[cursor...])
        return result
    }
}

/// The running → success / failure part of a provider sign-in, shared by
/// Quota's Add account, the Quota connect sheet, and Settings → Providers.
struct ProviderSignInFlow: View {
    @ObservedObject var login: ProviderLoginModel
    let providerName: String
    let mark: ProviderMark
    var accountLabel: String = ""
    /// False for key-only adds, which never open a browser.
    var usesBrowser = true
    var successDetail = "Hermes can use it for every agent now. Quota is refreshing."
    var onRetry: (() -> Void)?

    @State private var reply = ""
    @State private var showsReply = false
    @State private var showsDetails = false

    private var prompt: ProviderSignInPrompt { .parse(login.outputLines, partial: login.partialLine) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if login.exitStatus == 0 && !login.isRunning {
                    success
                } else {
                    header
                    if login.isRunning {
                        running
                    } else if let failure = login.failureText {
                        failed(failure)
                    } else if let status = login.exitStatus {
                        failed("Sign-in didn't finish (exit status \(status)). The details below show what Hermes reported.")
                    }
                }
                if !login.outputLines.isEmpty || !login.partialLine.isEmpty {
                    DisclosureGroup(isExpanded: $showsDetails) { details } label: {
                        Text("Sign-in details")
                            .dockFont(.body, weight: .medium)
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    .disclosureGroupStyle(DockDisclosureGroupStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: login.exitStatus) { if login.exitStatus != 0 { showsDetails = true } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProviderMarkBadge(mark: mark, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(providerName)
                    .dockFont(.navigation, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                if !accountLabel.isEmpty {
                    Text(accountLabel)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var running: some View {
        let prompt = prompt
        VStack(alignment: .leading, spacing: 12) {
            if usesBrowser {
                step(1, "Open the sign-in page", done: false) {
                    if let url = prompt.url {
                        Button { NSWorkspace.shared.open(url) } label: {
                            DockIconLabel("Open \(url.host ?? "sign-in page")", icon: .arrowSquareOut)
                        }
                        .buttonStyle(.dockPrimary)
                        .controlSize(.small)
                        .help(url.absoluteString)
                    } else {
                        Text("Waiting for Hermes to create the sign-in link…")
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                }
                if let code = prompt.code {
                    step(2, "Enter this code when asked", done: false) {
                        HStack(spacing: 10) {
                            Text(code)
                                .dockFont(.metric, weight: .semibold, design: .monospaced)
                                .tracking(2)
                                .foregroundStyle(Color.dockPrimaryText)
                                .textSelection(.enabled)
                            DockCopyButton(code, accessibilityLabel: "Copy code", presentation: .icon)
                                .buttonStyle(.dockPress)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                .dockSurfaceFill(Color.dockControlSurface, stroke: Color.dockBorder, lineWidth: DockLayout.hairline)
                        )
                    }
                }
            }
            if prompt.needsInput || showsReply {
                step(usesBrowser ? (prompt.code == nil ? 2 : 3) : 1, prompt.asksForCode || !prompt.needsInput ? "Paste the authorization code" : "Hermes is asking a question", done: false) {
                    if prompt.needsInput, !prompt.asksForCode {
                        Text(login.partialLine).dockFont(.metadata, weight: .regular, design: .monospaced).foregroundStyle(Color.dockSecondaryText)
                    }
                    HStack(spacing: 8) {
                        DockTextField(prompt.asksForCode ? "Paste the code from the browser" : "Type a reply", text: $reply)
                            .textFieldStyle(.dockGlass)
                            .onSubmit(sendReply)
                        Button("Submit", action: sendReply)
                            .buttonStyle(.dockSecondary)
                            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(usesBrowser ? "Waiting for you to finish signing in…" : "Adding the account…")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer()
                if usesBrowser && !prompt.needsInput && !showsReply {
                    Button("Have a code to paste?") { showsReply = true }
                        .buttonStyle(.dockLink)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockAccent)
                }
            }
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .dockFont(.metadata, weight: .bold, design: .rounded)
                .foregroundStyle(Color.dockOnAccentText)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.dockAccent))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                content()
            }
        }
    }

    private var success: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ProviderMarkBadge(mark: mark, size: 52)
                DockIcon(.checkCircle, size: 22, color: Color.dockSuccess)
                    .background(Circle().fill(Color.dockSurface))
                    .offset(x: 6, y: 6)
            }
            .padding(.top, 12)
            Text("\(providerName) account added")
                .dockFont(size: 15, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            if let label = prompt.accountLabel ?? (accountLabel.isEmpty ? nil : accountLabel) {
                Text("“\(label)”")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
            }
            Text(successDetail)
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func failed(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            ModalNote(text: message, icon: .warning, tone: .dockWarning)
            Spacer()
            if let onRetry {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.dockSecondary)
                    .controlSize(.small)
            }
        }
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array((login.outputLines + (login.partialLine.isEmpty ? [] : [login.partialLine])).enumerated()), id: \.offset) { _, line in
                    Text(ProviderSignInPrompt.linked(line))
                        .dockFont(.metadata, weight: .regular, design: .monospaced)
                        .foregroundStyle(Color.dockSecondaryText)
                        .tint(Color.dockAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .dockSurfaceFill(Color.dockSurface.opacity(0.4), stroke: Color.dockBorderLight, lineWidth: DockLayout.hairline)
        )
        .padding(.top, 6)
    }

    private func sendReply() {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        login.sendInput(trimmed)
        reply = ""
        showsReply = false
    }
}
