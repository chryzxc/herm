import Foundation

enum AgentBrowserLaunch {
    static func arguments(profile: URL, userAgent: String) -> [String] {
        [
            "--headless=new", "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1",
            "--user-data-dir=\(profile.path)",
            "--no-first-run", "--no-default-browser-check", "--window-size=1280,800",
            "--force-device-scale-factor=2",
            "--disable-blink-features=AutomationControlled", "--user-agent=\(userAgent)",
            "about:blank",
        ]
    }
}
