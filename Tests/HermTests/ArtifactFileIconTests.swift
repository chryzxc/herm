import Testing
@testable import Herm

@MainActor
struct ArtifactFileIconTests {
    @Test func resolvesLanguageAndSpecialFileIcons() {
        #expect(ArtifactFileIcon.name(for: "index.ts") == "typescript")
        #expect(ArtifactFileIcon.name(for: "app.js") == "javascript")
        #expect(ArtifactFileIcon.name(for: "Button.test.tsx") == "test-jsx")
        #expect(ArtifactFileIcon.name(for: "types.d.ts") == "typescript-def")
        #expect(ArtifactFileIcon.name(for: "package.json") == "nodejs")
        #expect(ArtifactFileIcon.name(for: "records.json") == "json")
        #expect(ArtifactFileIcon.name(for: "Dockerfile") == "docker")
        #expect(ArtifactFileIcon.name(for: ".env.local") == "tune")
        #expect(ArtifactFileIcon.name(for: "notes") == "document")
    }

    @Test func everyMappedIconIsBundled() {
        let samples = ArtifactFileIcon.fileNames.keys.map { $0 } + ArtifactFileIcon.extensions.keys.map { "f.\($0)" } + ["unknown"]
        for sample in samples {
            #expect(ArtifactFileIcon.image(for: sample) != nil, "no bundled icon for \(sample)")
        }
    }
}
