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
        guard let pid = application?.processIdentifier, pid != ProcessInfo.processInfo.processIdentifier else {
            throw QuickDraftError.message(
                "Switch to the window you want to capture, then try again. Your draft is kept.")
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw QuickDraftError.message(
                "Allow Screen Recording for Herm in System Settings, then capture again. Your draft has been kept.")
        }
        let orderedWindows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windowID =
            orderedWindows.first { row in
                row[kCGWindowOwnerPID as String] as? Int32 == application?.processIdentifier
                    && row[kCGWindowLayer as String] as? Int == 0
            }?[kCGWindowNumber as String] as? UInt32
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard
            let window = content.windows.first(where: {
                $0.windowID == windowID && $0.owningApplication?.processID == application?.processIdentifier
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
        var context = "Captured window: \(application?.localizedName ?? "App") · \(window.title ?? "Window")"
        if UserDefaults.standard.bool(forKey: "herm.capture.includeAppText"), let application {
            if AXIsProcessTrusted() {
                let app = AXUIElementCreateApplication(application.processIdentifier)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                    let value
                {
                    let focused = unsafeDowncast(value, to: AXUIElement.self)
                    var focusedTitle: CFTypeRef?
                    AXUIElementCopyAttributeValue(focused, kAXTitleAttribute as CFString, &focusedTitle)
                    guard let title = window.title, !title.isEmpty, focusedTitle as? String == title else {
                        return (
                            NSImage(cgImage: image, size: .zero),
                            context + "\nApp text omitted because the focused window changed."
                        )
                    }
                    var queue = [focused]
                    var strings: [String] = []
                    var visited = 0
                    while !queue.isEmpty && visited < 200 {
                        let node = queue.removeFirst()
                        visited += 1
                        var role: CFTypeRef?
                        AXUIElementCopyAttributeValue(node, kAXSubroleAttribute as CFString, &role)
                        if role as? String == "AXSecureTextField" { continue }
                        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXSelectedTextAttribute] {
                            var text: CFTypeRef?
                            if AXUIElementCopyAttributeValue(node, attribute as CFString, &text) == .success,
                                let text = text as? String, !text.isEmpty
                            {
                                strings.append(String(text.prefix(512)))
                            }
                        }
                        var children: CFTypeRef?
                        if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                            let elements = children as? [AXUIElement]
                        {
                            queue.append(contentsOf: elements.prefix(200 - visited))
                        }
                    }
                    context +=
                        "\nApp text (captured context):\n" + String(strings.joined(separator: "\n").prefix(8_192))
                }
            } else {
                context += "\nApp text unavailable: Accessibility permission is required."
            }
        }
        return (NSImage(cgImage: image, size: .zero), context)
    }
}
