# Common Muesli tasks. The real logic lives in scripts/ — this file is a thin,
# discoverable layer over build_native_app.sh, create_dmg.sh, dev-test.sh, and
# release.sh so it cannot drift from them.
#
# macOS ships GNU Make 3.81, which ignores .SHELLFLAGS; put the flags in SHELL itself.
SHELL := /bin/bash -eu -o pipefail

.DEFAULT_GOAL := help

# --- Config -------------------------------------------------------------------
# Signing identity resolution (first match wins):
#   1. SIGN_IDENTITY="..."  explicit override
#   2. OFFICIAL_SIGN_IDENTITY, when present in the keychain
#   3. the first codesigning identity in the keychain
#
# Entitlements follow the certificate *kind*, not the name: only a Developer ID
# Application certificate can back the iCloud/CloudKit entitlements in
# scripts/Muesli.entitlements without a provisioning profile, so every other
# identity signs with scripts/MuesliLocalOnly.entitlements (iCloud sync off).
#
# The maintainer identity below is an Apple Development certificate, so local
# builds are local-only by default and DMGs built here are NOT notarized —
# Gatekeeper warns on other machines. Notarized releases need a Developer ID
# certificate that this fork does not yet have.
SIGN_IDENTITY ?=
ENTITLEMENTS  ?=
OFFICIAL_SIGN_IDENTITY := Apple Development: mxshaheen@icloud.com (AMM3J847CY)

# VERSION stamps CFBundleShortVersionString, e.g. VERSION=1.2.3.
VERSION  ?=
# XCODE=1 pins the xcodebuild path so App Intents metadata ships (Shortcuts).
XCODE    ?=
# LANE=A/B/C selects an isolated parallel dev lane for `make dev`.
LANE     ?=
# FILTER narrows `make test` to matching suites/tests, e.g. FILTER=DictationStore.
FILTER   ?=
# APP_PATH must match where `make build` installs the app (MUESLI_INSTALL_DIR).
APP_PATH ?= /Applications/Muesli.app
DMG_DIR  ?= dist-release

VERSION_ENV := $(if $(VERSION),MUESLI_BUILD_VERSION='$(VERSION)')
XCODE_ENV   := $(if $(XCODE),MUESLI_USE_XCODE_BUILD=1)

# Resolved inside each recipe rather than via $(shell ...): identity names
# contain parentheses, which Make's function parser cannot swallow. Sets
# muesli_identity and muesli_ent in shell scope for that recipe.
define resolve_signing
if [ -n '$(SIGN_IDENTITY)' ]; then \
  muesli_identity='$(SIGN_IDENTITY)'; \
else \
  identities=$$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]* "\(.*\)"$$/\1/p' || true); \
  case "$$identities" in \
    *"$(OFFICIAL_SIGN_IDENTITY)"*) \
      muesli_identity='$(OFFICIAL_SIGN_IDENTITY)' ;; \
    *) \
      IFS= read -r muesli_identity <<< "$$identities" ;; \
  esac; \
fi; \
if [ -z "$$muesli_identity" ]; then \
  echo "error: no codesigning identity found in the keychain." >&2; \
  echo "       Pass SIGN_IDENTITY=\"...\" explicitly." >&2; \
  exit 2; \
fi; \
muesli_ent='$(ENTITLEMENTS)'; \
if [ -z "$$muesli_ent" ]; then \
  case "$$muesli_identity" in \
    "Developer ID Application:"*) muesli_ent='scripts/Muesli.entitlements' ;; \
    *) muesli_ent='scripts/MuesliLocalOnly.entitlements' ;; \
  esac; \
fi; \
printf 'Signing identity: %s\nEntitlements:     %s\n' "$$muesli_identity" "$$muesli_ent"
endef

.PHONY: help
help: ## Show available commands.
	@awk 'BEGIN { FS = ":.*##"; printf "\nCommands:\n" } /^[a-zA-Z0-9_.-]+:.*##/ { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\nExamples:\n'
	@printf '  make dmg                                # signed installer at %s\n' '$(DMG_DIR)'
	@printf '  make build VERSION=1.2.3 XCODE=1\n'
	@printf '  make dev LANE=A                         # parallel dev lane\n'
	@printf '  make test FILTER=DictationStore\n\n'
	@printf 'Options: VERSION XCODE LANE FILTER SIGN_IDENTITY ENTITLEMENTS APP_PATH DMG_DIR.\n'
	@printf 'Other MUESLI_* env vars (telemetry, scratch paths, ...) pass through to the scripts.\n\n'

.PHONY: config
config: ## Show the resolved signing identity and entitlements.
	@$(resolve_signing)

.PHONY: build
build: ## Signed Muesli.app installed to APP_PATH (replaces existing).
	@$(resolve_signing); \
	$(VERSION_ENV) $(XCODE_ENV) \
	MUESLI_SIGN_IDENTITY="$$muesli_identity" MUESLI_ENTITLEMENTS="$$muesli_ent" \
	./scripts/build_native_app.sh

.PHONY: dmg
dmg: build ## Signed installer at DMG_DIR/Muesli-<version>.dmg (builds first).
	@$(resolve_signing); \
	$(VERSION_ENV) \
	MUESLI_SIGN_IDENTITY="$$muesli_identity" \
	./scripts/create_dmg.sh "$(APP_PATH)" "$(DMG_DIR)"

.PHONY: dev
dev: ## Isolated dev/test build, MuesliDev.app; LANE=A/B/C for parallel lanes.
	./scripts/dev-test.sh $(if $(LANE),--lane $(LANE),)

.PHONY: test
test: ## Run the SwiftPM test suite; FILTER=<suite or test> narrows.
	swift test --package-path native/MuesliNative $(if $(FILTER),--filter '$(FILTER)',)

.PHONY: release
release: ## Official notarized release pipeline (Developer ID + MuesliNotary); VERSION=x.y.z pins.
	./scripts/release.sh $(VERSION)

.PHONY: clean
clean: ## Remove dist-native and temporary DMG staging.
	rm -rf dist-native
	rm -f "$(DMG_DIR)"/_temp_*.dmg
