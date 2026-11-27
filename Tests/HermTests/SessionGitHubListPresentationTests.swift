import Testing

@testable import Herm

struct SessionGitHubListPresentationTests {
    @Test func scopeChangesHideOldWarningsAndRows() {
        for initialLoad in [false, true] {
            let state = SessionGitHubListPresentation(
                scopeMatches: false, isInitialLoad: initialLoad, warning: "Old repository warning")
            #expect(state.isLoading)
            #expect(state.warning == nil)
        }
    }

    @Test func matchingScopePreservesLoadingAndWarningsIndependently() {
        for initialLoad in [false, true] {
            for warning in [nil, "GitHub unavailable"] as [String?] {
                let state = SessionGitHubListPresentation(
                    scopeMatches: true, isInitialLoad: initialLoad, warning: warning)
                #expect(state.isLoading == initialLoad)
                #expect(state.warning == warning)
            }
        }
    }
}
