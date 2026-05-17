SHELL := /bin/bash

APP_NAME := CalendarSync
VERSION_FILE := VERSION
VERSION ?= $(shell test -f $(VERSION_FILE) && tr -d '[:space:]' < $(VERSION_FILE))
TAP_REPO ?= https://github.com/khramtsoff/homebrew-brew.git
TAP_DIR ?= $(HOME)/Projects/homebrew-brew
FORMULA_NAME ?= calendar-sync
NOTARY_KEYCHAIN_PROFILE ?= calendarsync-notary
DERIVED_DATA_PATH ?= build/DerivedData

.PHONY: help project build run kill watch check-signing check-release-notes dist publish-github publish-homebrew release clean

help:
	@echo "CalendarSync targets"
	@echo ""
	@echo "  make project                         Generate CalendarSync.xcodeproj"
	@echo "  make build                           Generate project and build Debug"
	@echo "  make run                             Build Debug and launch app"
	@echo "  make kill                            Stop running app"
	@echo "  make watch                           Rebuild/relaunch on Swift changes (requires fswatch)"
	@echo "  make check-signing                   Check local Developer ID identity"
	@echo "  make dist                            Build, sign, notarize, staple, zip"
	@echo "  make publish-github                  Create/update GitHub release"
	@echo "  make publish-homebrew                Update khramtsoff/homebrew-brew"
	@echo "  make release                         dist + GitHub release + Homebrew tap"
	@echo ""
	@echo "Version: $(VERSION) (override with VERSION=1.2.3)"
	@echo "Notarization: uses NOTARY_KEYCHAIN_PROFILE=$(NOTARY_KEYCHAIN_PROFILE) by default."

project:
	xcodegen generate

build: project
	xcodebuild -project CalendarSync.xcodeproj -scheme CalendarSync -configuration Debug -derivedDataPath "$(DERIVED_DATA_PATH)" build

kill:
	@pkill -x "$(APP_NAME)" 2>/dev/null || true

run: build kill
	open "$(DERIVED_DATA_PATH)/Build/Products/Debug/$(APP_NAME).app"

watch:
	@command -v fswatch >/dev/null 2>&1 || (echo "fswatch is required: brew install fswatch" >&2; exit 127)
	fswatch -o CalendarSync project.yml | while read -r _; do $(MAKE) run; done

check-signing:
	@if security find-identity -v -p codesigning | grep -E "Developer ID Application: .* \\(JF25G9C7A8\\)"; then \
		echo "Signing identity found."; \
	else \
		echo "Signing identity not found: Developer ID Application certificate for team JF25G9C7A8" >&2; \
		echo "Install the Developer ID Application certificate and private key in Keychain Access." >&2; \
		exit 1; \
	fi

check-release-notes:
	@test -n "$(VERSION)" || (echo "VERSION is required; set VERSION file or pass VERSION=1.2.3" >&2; exit 2)
	@test -s RELEASE_NOTES.md || (echo "RELEASE_NOTES.md is required and must not be empty." >&2; exit 2)
	@rg -q "^##[[:space:]]+$(VERSION)([[:space:]]|$$)" RELEASE_NOTES.md || (echo "RELEASE_NOTES.md must contain a section for $(VERSION)." >&2; exit 2)

dist: check-release-notes
	NOTARY_KEYCHAIN_PROFILE="$(NOTARY_KEYCHAIN_PROFILE)" ./scripts/make-notarized-zip.sh "$(VERSION)"

publish-github:
	@test -n "$(VERSION)" || (echo "VERSION is required; set VERSION file or pass VERSION=1.2.3" >&2; exit 2)
	./scripts/publish-github-release.sh "$(VERSION)"

publish-homebrew:
	@test -n "$(VERSION)" || (echo "VERSION is required; set VERSION file or pass VERSION=1.2.3" >&2; exit 2)
	TAP_REPO="$(TAP_REPO)" TAP_DIR="$(TAP_DIR)" FORMULA_NAME="$(FORMULA_NAME)" ./scripts/update-homebrew-tap.sh "$(VERSION)"

release: dist publish-github publish-homebrew

clean:
	rm -rf build dist
