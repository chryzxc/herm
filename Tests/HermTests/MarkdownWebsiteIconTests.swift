import AppKit
import Testing

@testable import Herm

@MainActor
struct MarkdownWebsiteIconTests {
    @Test func formatsBareGitHubReferencesAndPreservesCustomLabels() throws {
        let pr = try #require(URL(string: "https://github.com/owner/repo/pull/7723"))
        #expect(MarkdownWebsiteIcon.label(pr.absoluteString, for: pr) == "PR #7723")
        #expect(MarkdownWebsiteIcon.label("Fix rendering", for: pr) == "Fix rendering")
        let issue = try #require(URL(string: "https://github.com/owner/repo/issues/42"))
        #expect(MarkdownWebsiteIcon.label(issue.absoluteString, for: issue) == "Issue #42")
        let file = try #require(URL(string: "https://github.com/owner/repo/pull/7723/files"))
        #expect(MarkdownWebsiteIcon.label(file.absoluteString, for: file) == file.absoluteString)
    }

    @Test func faviconRequestsContainOnlyThePublicHTTPSOrigin() throws {
        let url = try #require(URL(string: "http://user:secret@docs.example.com:8080/private?q=secret#section"))
        #expect(MarkdownWebsiteIcon.faviconURL(for: url)?.absoluteString == "https://docs.example.com/favicon.ico")
        for value in [
            "mailto:me@example.com", "file:///tmp/test.md", "https://localhost", "https://127.0.0.1", "https://[::1]",
            "https://host.local", "https://host.internal",
        ] {
            #expect(MarkdownWebsiteIcon.faviconURL(for: try #require(URL(string: value))) == nil)
        }
    }

    @Test func iconsAreClickableAndAppearOnceAcrossStyledLinkRuns() throws {
        let url = try #require(URL(string: "https://github.com/owner/repo/pull/7723"))
        let output = NativeMarkdownAttributedTextBuilder.document(
            "See [PR **#7723**](\(url.absoluteString)) and `app.ts`.", palette: NativeMarkdownPalette()
        ).string
        var websiteIcons = 0
        var fileIcons = 0
        output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, range, _ in
            guard value is NSTextAttachment else { return }
            #expect(
                output.attribute(
                    NativeMarkdownAttributedTextBuilder.fileIconKey, at: range.location, effectiveRange: nil) != nil)
            if output.attribute(.link, at: range.location, effectiveRange: nil) as? URL == url {
                websiteIcons += 1
            } else {
                fileIcons += 1
            }
        }
        #expect(websiteIcons == 1)
        #expect(fileIcons == 1)
    }

    @Test func unsafeLinksAndCodeURLsDoNotGetWebsiteIcons() {
        let output = NativeMarkdownAttributedTextBuilder.document(
            "[Unsafe](javascript:alert) and `https://github.com/owner/repo/pull/1`", palette: NativeMarkdownPalette()
        ).string
        var icons = 0
        output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, _, _ in
            if value != nil { icons += 1 }
        }
        #expect(icons == 0)
    }

    @Test func bareGitHubLinkKeepsItsDestinationAfterShortening() throws {
        let url = try #require(URL(string: "https://github.com/owner/repo/pull/7723"))
        let output = NativeMarkdownAttributedTextBuilder.document(
            "See \(url.absoluteString)", palette: NativeMarkdownPalette()
        ).string
        #expect(output.string.contains("PR #7723"))
        let labelRange = (output.string as NSString).range(of: "PR #7723")
        #expect(labelRange.location != NSNotFound)
        if labelRange.location != NSNotFound {
            #expect(output.attribute(.link, at: labelRange.location, effectiveRange: nil) as? URL == url)
            #expect(
                output.attribute(.underlineStyle, at: labelRange.location, effectiveRange: nil) as? Int
                    == NSUnderlineStyle.single.rawValue)
        }
    }

    @Test func localWebsiteFallbackKeepsFixedIconBounds() throws {
        let url = try #require(URL(string: "https://docs.local/guide"))
        let attachment = try #require(MarkdownWebsiteIcon.attachment(for: url, size: 13, color: .labelColor))
        #expect(attachment.image != nil)
        #expect(attachment.bounds == CGRect(x: 0, y: -2, width: 13, height: 13))
        #expect(
            MarkdownWebsiteIcon.attachment(
                for: try #require(URL(string: "mailto:me@example.com")), size: 13, color: .labelColor) == nil)
    }
}
