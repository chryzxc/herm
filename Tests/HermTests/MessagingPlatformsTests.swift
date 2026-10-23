import Testing

@testable import Herm

struct MessagingPlatformsTests {
    @Test func decodesDashboardPlatformRow() throws {
        let platform = try #require(
            MessagingPlatformsModel.platform([
                "id": "telegram", "name": "Telegram", "enabled": false, "configured": false, "state": "disabled",
                "docs_url": "https://example.com/telegram",
                "env_vars": [
                    [
                        "key": "TELEGRAM_BOT_TOKEN", "required": true, "is_set": true, "redacted_value": "12…ab",
                        "is_password": true, "prompt": "Bot token",
                    ],
                    ["key": "TELEGRAM_ALLOWED_USERS", "is_list": true, "value": "42"],
                ],
            ]))
        #expect(platform.envVars.map(\.key) == ["TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS"])
        #expect(
            platform.envVars[0].required && platform.envVars[0].isPassword && platform.envVars[0].prompt == "Bot token")
        #expect(platform.envVars[1].value == "42")
        #expect(platform.statusLabels.map(\.1) == ["Disabled", "Needs setup"])
        #expect(MessagingPlatformsModel.platform(["name": "no id"]) == nil)
    }
}
