SHELL := /bin/bash

APP_NAME := CalendarSync
VERSION ?=
TAP_REPO ?= https://github.com/khramtsoff/homebrew-brew.git
TAP_DIR ?= $(HOME)/Projects/homebrew-brew
FORMULA_NAME ?= calendarsync
NOTARY_KEYCHAIN_PROFILE ?= calendarsync-notary

.PHONY: help project check-signing dist publish-github publish-homebrew release clean

help:
	@echo "CalendarSync local release targets"
	@echo ""
	@echo "  make project                         Generate CalendarSync.xcodeproj"
	@echo "  make check-signing                   Check local Developer ID identity"
	@echo "  make dist VERSION=1.2.3              Build, sign, notarize, staple, zip"
	@echo "  make publish-github VERSION=1.2.3    Create/update GitHub release"
	@echo "  make publish-homebrew VERSION=1.2.3  Update khramtsoff/homebrew-brew"
	@echo "  make release VERSION=1.2.3           dist + GitHub release + Homebrew tap"
	@echo ""
	@echo "Notarization: uses NOTARY_KEYCHAIN_PROFILE=$(NOTARY_KEYCHAIN_PROFILE) by default."

project:
	xcodegen generate

check-signing:
	@if security find-identity -v -p codesigning | grep -F "Developer ID Application"; then \
		echo "Signing identity found."; \
	else \
		echo "Signing identity not found: Developer ID Application" >&2; \
		echo "Install the Developer ID Application certificate and private key in Keychain Access." >&2; \
		exit 1; \
	fi

dist:
	@test -n "$(VERSION)" || (echo "VERSION is required, e.g. make dist VERSION=1.2.3" >&2; exit 2)
	NOTARY_KEYCHAIN_PROFILE="$(NOTARY_KEYCHAIN_PROFILE)" ./scripts/make-notarized-zip.sh "$(VERSION)"

publish-github:
	@test -n "$(VERSION)" || (echo "VERSION is required, e.g. make publish-github VERSION=1.2.3" >&2; exit 2)
	./scripts/publish-github-release.sh "$(VERSION)"

publish-homebrew:
	@test -n "$(VERSION)" || (echo "VERSION is required, e.g. make publish-homebrew VERSION=1.2.3" >&2; exit 2)
	TAP_REPO="$(TAP_REPO)" TAP_DIR="$(TAP_DIR)" FORMULA_NAME="$(FORMULA_NAME)" ./scripts/update-homebrew-tap.sh "$(VERSION)"

release: dist publish-github publish-homebrew

clean:
	rm -rf build dist
