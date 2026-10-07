import Testing
@testable import Herm

struct RepositoryChangesBrowserTests {
    @Test func displayLinesDropGitPreambleAndNoNewlineMarker() {
        let patch = "diff --git a/x b/x\nnew file mode 100644\nindex 0..1\n--- /dev/null\n+++ b/x\n@@ -0,0 +1,2 @@\n+# Title\n-old\n\\ No newline at end of file"
        let lines = RepositoryChangesBrowser.displayLines(patch)
        #expect(lines.map(\.text) == ["@@ -0,0 +1,2 @@", "+# Title", "-old"])
        #expect(lines.map(\.kind) == [.hunk, .addition, .deletion])
        #expect(RepositoryChangesBrowser.displayLines("Binary files differ").isEmpty)
    }
}
