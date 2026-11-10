SHELL := /bin/sh

PROJECT_ROOT := $(CURDIR)
SWIFT_FORMAT ?= $(shell xcrun --find swift-format 2>/dev/null)

.PHONY: test build build-release run guard lint format smoke-contract color-contract button-contract card-contract shell-contract naming-contract resource-contract design-contract check package

test:
	# Native UI fixtures share the main actor; serialize to keep their deadlines meaningful.
	. Scripts/appintents.sh && reset_stale_metal_cache && swift test --no-parallel --disable-automatic-resolution

build:
	. Scripts/appintents.sh && reset_stale_metal_cache && swift build --disable-automatic-resolution

# Same flags as Scripts/package-app.sh, so packaging reuses this build instead of recompiling.
build-release:
	. Scripts/appintents.sh && swift_build_with_appintents -c release --disable-automatic-resolution

run:
	Scripts/run-debug-app.sh

lint:
	@test -n "$(SWIFT_FORMAT)" || (echo "swift-format is required; install Xcode Command Line Tools or set SWIFT_FORMAT" >&2; exit 1)
	"$(SWIFT_FORMAT)" lint --strict --parallel --recursive Sources Tests

format:
	@test -n "$(SWIFT_FORMAT)" || (echo "swift-format is required; install Xcode Command Line Tools or set SWIFT_FORMAT" >&2; exit 1)
	"$(SWIFT_FORMAT)" format --in-place --parallel --recursive Sources Tests

smoke-contract:
	sh -n Scripts/run-debug-app.sh Scripts/build-and-run-app.sh
	swift test --disable-automatic-resolution --filter WorkflowAccessibilityIdentifierTests

color-contract:
	python3 Scripts/test-color-contract.py
	python3 Scripts/check-colors.py

card-contract:
	python3 Scripts/test-card-contract.py
	python3 Scripts/check-card-contract.py

shell-contract:
	python3 Scripts/check-shell-contract.py

button-contract:
	python3 Scripts/test-button-contract.py
	python3 Scripts/check-button-contract.py

design-contract:
	python3 Scripts/test-design-doc.py
	python3 Scripts/check-design-doc.py

naming-contract:
	python3 Scripts/test-naming-contract.py
	python3 Scripts/check-naming-contract.py

# SwiftPM's Bundle.module traps in packaged apps; resources go through Bundle.herm.
resource-contract:
	@! grep -rn 'Bundle\.module' Sources --include='*.swift' | grep -v '^Sources/Herm/App/HermResources.swift:' || \
		{ echo 'Use Bundle.herm instead of Bundle.module (it crashes outside the build machine).'; exit 1; }

guard: color-contract button-contract card-contract shell-contract naming-contract design-contract resource-contract lint
	git diff --check

check: guard test smoke-contract build-release
	git diff --check

package:
	Scripts/package-app.sh $(VERSION)
