import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Captures one explicit desktop window; no capture runs in the background.
@MainActor
final class DesktopCaptureService {
    static let shared = DesktopCaptureService()
    private var lastApplication: NSRunningApplication?
    private var observer: NSObjectProtocol?
    init() {
        lastApplication = NSWorkspace.shared.frontmostApplication
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            MainActor.assumeIsolated { self?.lastApplication = app }
        }
    }
    static func requestAppTextPermission() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    func capture() async throws -> (image: NSImage, context: String) {
        let application = lastApplication
        guard let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw QuickDraftError.message(
                "Switch to the window you want to capture, then try again. Your draft is kept.")
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw QuickDraftError.message(
                "Allow Screen Recording for Herm in System Settings, then capture again. Your draft has been kept.")
        }
        let (image, window) = try await Self.windowImage(of: application)
        var context = "Captured window: \(application.localizedName ?? "App") · \(window.title ?? "Window")"
        if UserDefaults.standard.bool(forKey: "herm.capture.includeAppText") {
            if AXIsProcessTrusted() {
                let app = AXUIElementCreateApplication(application.processIdentifier)
                if let focused = Self.element(app, kAXFocusedWindowAttribute) {
                    guard let title = window.title, !title.isEmpty, Self.string(focused, kAXTitleAttribute) == title
                    else {
                        return (
                            NSImage(cgImage: image, size: .zero),
                            context + "\nApp text omitted because the focused window changed."
                        )
                    }
                    context +=
                        "\nApp text (captured context):\n"
                        + Self.appText(in: focused, nodes: 200, limit: 8_192, readsValues: false)
                }
            } else {
                context += "\nApp text unavailable: Accessibility permission is required."
            }
        }
        return (NSImage(cgImage: image, size: .zero), context)
    }

    /// The last app you used before Herm, unless it's a password manager or no longer showing.
    var voiceFrontApplication: NSRunningApplication? {
        guard let application = lastApplication, !application.isTerminated, !application.isHidden,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            !VoiceScreenContext.isDenied(application.bundleIdentifier)
        else { return nil }
        return application
    }

    /// What voice may read from the front app: its focused window's title,
    /// the selected text, or else the window's visible text. Read-only, off the main
    /// thread, and never logged. Without Accessibility only the app name is known.
    static func frontContext(of application: NSRunningApplication) async -> VoiceScreenContext {
        let pid = application.processIdentifier
        let name = application.localizedName ?? "App"
        let bundleID = application.bundleIdentifier
        return await Task.detached(priority: .userInitiated) {
            var context = VoiceScreenContext(appName: name, bundleID: bundleID)
            guard AXIsProcessTrusted() else { return context }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            guard let window = element(app, kAXFocusedWindowAttribute) else { return context }
            context.windowTitle = string(window, kAXTitleAttribute)
            if let focused = element(app, kAXFocusedUIElementAttribute), !isSecure(focused) {
                context.selection = string(focused, kAXSelectedTextAttribute)
            }
            if context.selection == nil {
                let text = appText(in: window, nodes: 600, limit: VoiceScreenContext.textLimit, readsValues: true)
                context.visibleText = text.isEmpty ? nil : text
            }
            return context
        }.value
    }

    /// A JPEG of the app's frontmost window, only when Screen Recording is already allowed.
    static func voiceWindowJPEG(of application: NSRunningApplication) async -> Data? {
        guard CGPreflightScreenCaptureAccess(), let captured = try? await windowImage(of: application) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: captured.0).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    private static func windowImage(of application: NSRunningApplication) async throws -> (CGImage, SCWindow) {
        let orderedWindows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windowID =
            orderedWindows.first { row in
                row[kCGWindowOwnerPID as String] as? Int32 == application.processIdentifier
                    && row[kCGWindowLayer as String] as? Int == 0
            }?[kCGWindowNumber as String] as? UInt32
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard
            let window = content.windows.first(where: {
                $0.windowID == windowID && $0.owningApplication?.processID == application.processIdentifier
                    && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1
            })
        else { throw QuickDraftError.message("No eligible window is available in the last active app.") }
        let config = SCStreamConfiguration()
        let scale = min(2, 2560 / window.frame.width, 2560 / window.frame.height)
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        return (image, window)
    }

    /// Breadth-first text under `root`, skipping secure fields. `readsValues` adds what static
    /// text and text areas show, for voice; the capture context keeps titles and selections only.
    nonisolated static func appText(in root: AXUIElement, nodes: Int, limit: Int, readsValues: Bool) -> String {
        var queue = [root]
        var strings: [String] = []
        var visited = 0
        var length = 0
        let valueRoles: Set = ["AXStaticText", "AXTextArea", "AXHeading", "AXLink"]
        while !queue.isEmpty && visited < nodes && length < limit {
            let node = queue.removeFirst()
            visited += 1
            if isSecure(node) { continue }
            var attributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXSelectedTextAttribute]
            if readsValues, let role = string(node, kAXRoleAttribute), valueRoles.contains(role) {
                attributes.append(kAXValueAttribute)
            }
            for attribute in attributes {
                if let text = string(node, attribute), strings.last != text {
                    strings.append(String(text.prefix(512)))
                    length += min(512, text.count) + 1
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                let elements = children as? [AXUIElement]
            {
                queue.append(contentsOf: elements.prefix(nodes - visited))
            }
        }
        return String(strings.joined(separator: "\n").prefix(limit))
    }

    nonisolated private static func isSecure(_ node: AXUIElement) -> Bool {
        string(node, kAXSubroleAttribute) == "AXSecureTextField"
    }

    nonisolated private static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    nonisolated private static func element(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success, let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
