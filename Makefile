SHELL := /bin/sh

PROJECT_ROOT := $(CURDIR)
SWIFT_FORMAT ?= $(shell xcrun --find swift-format 2>/dev/null)

.PHONY: test build build-release run guard lint format smoke-contract color-contract check package

test:
	# Native UI fixtures share the main actor; serialize to keep their deadlines meaningful.
	swift test --no-parallel --disable-automatic-resolution

build:
	swift build --disable-automatic-resolution

build-release:
	swift build -c release --disable-automatic-resolution

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

guard: color-contract lint
	git diff --check

check: guard test smoke-contract build-release
	git diff --check

package:
	Scripts/package-app.sh $(VERSION)
