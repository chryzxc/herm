import AppKit
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
        let samples =
            ArtifactFileIcon.fileNames.keys.map { $0 } + ArtifactFileIcon.extensions.keys.map { "f.\($0)" } + [
                "unknown"
            ]
        for sample in samples {
            #expect(ArtifactFileIcon.image(for: sample) != nil, "no bundled icon for \(sample)")
        }
    }
}

@MainActor
struct InlineFileIconTests {
    @Test func recognizesFilePathsButNotCodeOrProse() {
        #expect(ArtifactFileIcon.mappedName(forPath: "/Users/me/.hermes/auth-log-pr-body.md") == "markdown")
        #expect(ArtifactFileIcon.mappedName(forPath: "user-auth-log.deletion.routes.test.js") == "test-js")
        #expect(ArtifactFileIcon.mappedName(forPath: "notes.txt") == "document")
        #expect(ArtifactFileIcon.mappedName(forPath: "npm run build") == nil)
        #expect(ArtifactFileIcon.mappedName(forPath: "config.set") == nil)
        #expect(ArtifactFileIcon.mappedName(forPath: "") == nil)
    }

    @Test func nativeMarkdownTagsIconsBeforeFileCodeSpans() {
        let output = NativeMarkdownAttributedTextBuilder.document(
            "See `app.ts` and `npm test`.", palette: NativeMarkdownPalette())
        var icons = 0
        output.string.enumerateAttribute(
            NativeMarkdownAttributedTextBuilder.fileIconKey, in: NSRange(location: 0, length: output.string.length)
        ) { value, _, _ in
            if value != nil { icons += 1 }
        }
        #expect(icons == 1)
    }
}
