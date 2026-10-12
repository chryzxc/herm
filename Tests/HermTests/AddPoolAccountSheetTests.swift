import Testing
@testable import Herm

struct AddPoolAccountSheetTests {
    @Test func buildsAuthAddCommand() {
        #expect(AddPoolAccountSheet.command(provider: " openai-codex ", label: "", apiKey: nil) == "hermes auth add openai-codex")
        #expect(AddPoolAccountSheet.command(provider: "anthropic", label: "my work", apiKey: nil) == "hermes auth add anthropic --label my-work")
        #expect(AddPoolAccountSheet.command(provider: "openrouter", label: "", apiKey: "sk-1") == "hermes auth add openrouter --type api-key --api-key sk-1")
        #expect(AddPoolAccountSheet.command(provider: "", label: "", apiKey: nil) == nil)
        #expect(AddPoolAccountSheet.command(provider: "a b", label: "", apiKey: nil) == nil)
        #expect(AddPoolAccountSheet.command(provider: "x", label: "", apiKey: "") == nil)
    }
}
