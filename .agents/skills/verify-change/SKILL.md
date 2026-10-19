---
name: verify-change
description: Verify a Herm code change before calling it done — pick the focused test suite, build, and check the Definition of Done without slow full runs or relaunching the app. Use after editing Swift sources or tests.
---

# Verify a Herm change

1. Build: `swift build --disable-automatic-resolution`.
2. Find the focused suite: match the changed type to its tests
   (`grep -rl "<TypeName>" Tests/HermTests`), then run
   `swift test --disable-automatic-resolution --filter '<Suite>|<OtherSuite>'`.
   Native UI fixtures share the main actor; add `--no-parallel` if they time out.
3. Generative UI changes: also run the CI job's filter
   `GenerativeUIIsolationTests|GenerativeUITests|GeneratedHTMLTests`.
4. Run `git diff --check`.
5. Check the Definition of Done in `STANDARDS.md`: README/DESIGN updated for
   user-visible changes, no credential-shaped values, and layout-stability rules
   respected.

Do not run the full suite, `make check`, or `make package` locally unless the
user asks; CI runs them. Never run `make run` or `Scripts/run-debug-app.sh`
unprompted, because it kills the user's live agents. Report which suites ran and their result,
including failures verbatim.
