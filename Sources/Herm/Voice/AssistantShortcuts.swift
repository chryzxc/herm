import AppKit
import Contacts
import Foundation

struct AssistantShortcutPreferences: Codable, Equatable {
    struct Shortcut: Codable, Equatable, Hashable, Identifiable {
        let id: UUID
        let name: String
    }

    struct Alias: Codable, Equatable, Identifiable {
        let name: String
        let shortcut: Shortcut
        var id: String { AssistantIntent.normalized(name) }
    }

    static let key = "herm.voice.shortcuts"
    var aliases: [Alias] = []
    var mail: Shortcut?
    var messages: Shortcut?

    static var current: Self {
        guard let data = UserDefaults.standard.data(forKey: key) else { return Self() }
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }

    static func shortcut(matching name: String) -> Shortcut? {
        current.aliases.first { $0.id == AssistantIntent.normalized(name) }?.shortcut
    }

    func shortcut(for channel: AssistantChannel) -> Shortcut? {
        channel == .mail ? mail : messages
    }
}

enum AssistantShortcuts {
    typealias Shortcut = AssistantShortcutPreferences.Shortcut

    struct Message: Encodable, Equatable {
        let version = 1
        let channel: AssistantChannel
        let recipient: String
        let subject: String?
        let body: String
    }

    private static let executable = "/usr/bin/shortcuts"

    static func installed() async throws -> [Shortcut] {
        let output = try await HermesLocalProcess.capture(
            executable, arguments: ["list", "--show-identifiers"], timeout: 15)
        guard output.code == 0 else { throw Failure.unavailable }
        return parseInstalled(String(decoding: output.data, as: UTF8.self))
    }

    static func parseInstalled(_ output: String) -> [Shortcut] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard
                let range = value.range(
                    of: #"[[:space:](\[]+[0-9a-fA-F-]{36}[)\]]?$"#, options: .regularExpression)
            else { return nil }
            let raw = value[range].trimmingCharacters(in: CharacterSet(charactersIn: " ()[]\t"))
            let name = value[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UUID(uuidString: raw), !name.isEmpty else { return nil }
            return Shortcut(id: id, name: name)
        }
    }

    @MainActor static func runAlias(_ name: String) -> AssistantReply {
        guard let shortcut = AssistantShortcutPreferences.shortcut(matching: name) else {
            return AssistantReply("Choose a Shortcut and save an alias in Voice settings first.")
        }
        return .confirm("Run the \(shortcut.name) shortcut?") {
            guard AssistantShortcutPreferences.shortcut(matching: name)?.id == shortcut.id else {
                return "That shortcut binding changed. Ask me to run it again."
            }
            do {
                try await run(shortcut)
                return "\(shortcut.name) finished."
            } catch {
                return "I couldn't confirm that \(shortcut.name) finished. It may have run."
            }
        }
    }

    @MainActor static func compose(
        channel: AssistantChannel, recipient: String, subject: String?, body: String, draftOnly: Bool
    ) async -> AssistantReply {
        guard !recipient.isEmpty, !body.isEmpty, body.count <= 4_000, (subject?.count ?? 0) <= 200 else {
            return AssistantReply("I need one recipient and a shorter message.")
        }
        let matches: [Recipient]
        if let address = explicitAddress(recipient, for: channel) {
            matches = [Recipient(name: nil, address: address)]
        } else {
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                return AssistantReply(
                    "Say a full \(channel == .mail ? "email address" : "phone number"), or connect Contacts in Voice settings."
                )
            }
            matches = await Task.detached { matchingContacts(recipient, for: channel) }.value
        }
        let prepare: @MainActor (Recipient) -> AssistantReply = { result in
            let message = Message(channel: channel, recipient: result.address, subject: subject, body: body)
            let destination = result.name.map { "\($0), \(result.address)" } ?? result.address
            return draft(message, destination: destination, draftOnly: draftOnly)
        }
        switch matches.count {
        case 0:
            return AssistantReply(
                "I couldn't find a single address for \(recipient). Say the full address or phone number.")
        case 1: return prepare(matches[0])
        default:
            return .choose("Which address?", choices: matches.map { ($0.label, $0) }) { prepare($0) }
        }
    }

    private struct Recipient: Sendable {
        let name: String?
        let address: String
        var label: String { name.map { "\($0), \(address)" } ?? address }
    }

    private static func explicitAddress(_ spoken: String, for channel: AssistantChannel) -> String? {
        switch channel {
        case .mail:
            let address = spoken.replacingOccurrences(of: #"(?i) at "#, with: "@", options: .regularExpression)
                .replacingOccurrences(of: #"(?i) dot "#, with: ".", options: .regularExpression)
                .replacingOccurrences(of: #"\s*([@.])\s*"#, with: "$1", options: .regularExpression)
            return address.range(
                of: #"^[A-Z0-9.!#$%&'*+/=?^_{}|~-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)+$"#,
                options: [.regularExpression, .caseInsensitive]) == nil ? nil : address
        case .messages:
            guard spoken.range(of: #"^\+?[\d ()-]+$"#, options: .regularExpression) != nil else { return nil }
            let digits = spoken.filter(\.isASCII).filter(\.isNumber)
            guard (7...15).contains(digits.count) else { return nil }
            return (spoken.hasPrefix("+") ? "+" : "") + digits
        }
    }

    private static func matchingContacts(_ query: String, for channel: AssistantChannel) -> [Recipient] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
        ].map { $0 as NSString }
        guard
            let contacts = try? CNContactStore().unifiedContacts(
                matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
        else { return [] }
        var seen = Set<String>()
        return contacts.flatMap { contact -> [Recipient] in
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let addresses =
                channel == .mail
                ? contact.emailAddresses.map { $0.value as String }
                : contact.phoneNumbers.map { $0.value.stringValue }
            return addresses.compactMap { value -> Recipient? in
                guard let address = explicitAddress(value, for: channel),
                    seen.insert(AssistantIntent.normalized(address)).inserted
                else { return nil }
                return Recipient(name: name.isEmpty ? contact.nickname : name, address: address)
            }
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    @MainActor private static func draft(_ message: Message, destination: String, draftOnly: Bool) -> AssistantReply {
        let subject = message.channel == .mail ? " Subject: \(message.subject ?? "No subject")." : ""
        let readback = "\(message.channel.title) to \(destination).\(subject) Message: \(message.body)"
        if draftOnly {
            return AssistantReply(readback + " Draft ready. Say “prepare to send” or “cancel”.") { answer in
                switch AssistantIntent.normalized(answer).trimmingCharacters(in: CharacterSet(charactersIn: ".!?")) {
                case "cancel", "no", "discard": return AssistantReply("Draft discarded.")
                case "prepare to send": return draft(message, destination: destination, draftOnly: false)
                default: return draft(message, destination: destination, draftOnly: true)
                }
            }
        }
        guard let shortcut = AssistantShortcutPreferences.current.shortcut(for: message.channel) else {
            return AssistantReply(readback + " Choose a \(message.channel.title) sending shortcut in Voice settings.")
        }
        return .confirm(readback, phrase: "send it", requiresReadback: true) {
            guard AssistantShortcutPreferences.current.shortcut(for: message.channel)?.id == shortcut.id else {
                return "The sending shortcut changed. Prepare the draft again."
            }
            do {
                try await run(shortcut, message: message)
                return "The \(message.channel.title) shortcut reported that it submitted the message."
            } catch {
                return
                    "I couldn't verify whether the message was submitted. Check \(message.channel.title) before trying again."
            }
        }
    }

    private static func run(_ shortcut: Shortcut, message: Message? = nil) async throws {
        var arguments = ["run", shortcut.id.uuidString]
        var directory: URL?
        defer { if let directory { try? FileManager.default.removeItem(at: directory) } }
        if let message {
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            directory = target
            let input = target.appendingPathComponent("message.json")
            try JSONEncoder().encode(message).write(to: input, options: .atomic)
            arguments += ["--input-path", input.path]
        }
        try Task.checkCancellation()
        let result = try await HermesLocalProcess.capture(executable, arguments: arguments, timeout: 60)
        guard result.code == 0,
            message == nil
                || String(decoding: result.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    == "submitted"
        else { throw Failure.unavailable }
    }

    private enum Failure: Error { case unavailable }
}

@MainActor
enum AssistantMac {
    static func perform(_ intent: AssistantIntent) -> AssistantReply? {
        switch intent {
        case .open(let name): return AssistantReply(open(name))
        case .time(let location):
            let zone: TimeZone
            if let location {
                let term = AssistantIntent.normalized(location.replacingOccurrences(of: " ", with: "_"))
                let matches = TimeZone.knownTimeZoneIdentifiers.filter {
                    AssistantIntent.normalized($0) == term
                        || AssistantIntent.normalized($0.split(separator: "/").last.map(String.init) ?? "") == term
                }
                guard let identifier = matches.first, matches.count == 1, let match = TimeZone(identifier: identifier)
                else { return AssistantReply("I couldn't find a unique time zone for \(location).") }
                zone = match
            } else {
                zone = .current
            }
            var format = Date.FormatStyle().hour().minute().timeZone()
            format.timeZone = zone
            let time = Date.now.formatted(format)
            return AssistantReply("It's \(time).")
        case .calculation(let expression):
            return AssistantReply(AssistantMath.answer(expression) ?? "I couldn't calculate that.")
        default: return nil
        }
    }

    static func openBrowserApp(_ browser: AssistantBrowserApp) async -> AssistantReply {
        let workspace = NSWorkspace.shared
        // Query the registered HTTPS handler without opening or contacting a page.
        let app =
            browser == .systemDefault
            ? URL(string: "https://example.com").flatMap { workspace.urlForApplication(toOpen: $0) }
            : workspace.urlForApplication(withBundleIdentifier: browser.rawValue)
        guard let app else { return AssistantReply("I couldn’t find \(browser.displayName) on this Mac.") }
        do {
            try Task.checkCancellation()
            _ = try await workspace.openApplication(at: app, configuration: .init())
            return AssistantReply("Opened \(browser.displayName).")
        } catch {
            return AssistantReply("I couldn’t open \(browser.displayName).")
        }
    }

    private static func open(_ name: String) -> String {
        let term = AssistantIntent.normalized(name)
            .replacingOccurrences(of: #"^the | (?:app|folder)$"#, with: "", options: .regularExpression)
        let folders: [String: FileManager.SearchPathDirectory] = [
            "desktop": .desktopDirectory, "documents": .documentDirectory, "downloads": .downloadsDirectory,
            "pictures": .picturesDirectory, "music": .musicDirectory, "movies": .moviesDirectory,
        ]
        if let folder = folders[term], let url = FileManager.default.urls(for: folder, in: .userDomainMask).first {
            return NSWorkspace.shared.open(url) ? "Opened \(name)." : "I couldn't open \(name)."
        }
        if term == "home" {
            return NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
                ? "Opened your Home folder." : "I couldn't open your Home folder."
        }
        let installed = NSWorkspace.shared.runningApplications.compactMap { app -> URL? in
            guard let name = app.localizedName, AssistantIntent.normalized(name) == term,
                let url = app.bundleURL, url.pathExtension == "app"
            else { return nil }
            return url
        }
        let locations = [
            "/Applications", "/System/Applications", "/System/Applications/Utilities",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
        ]
        let applications = locations.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: [.localizedNameKey], options: [.skipsHiddenFiles])) ?? []
        }.filter { url in
            guard url.pathExtension == "app" else { return false }
            let name = url.deletingPathExtension().lastPathComponent
            let localized = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName
            return [name, localized ?? name].contains { AssistantIntent.normalized($0) == term }
        }
        let matches = Set(installed + applications)
        guard matches.count == 1, let app = matches.first else {
            return matches.isEmpty
                ? "I couldn't find an installed app named \(name)." : "I found multiple apps named \(name)."
        }
        return NSWorkspace.shared.open(app) ? "Opened \(name)." : "I couldn't open \(name)."
    }
}
