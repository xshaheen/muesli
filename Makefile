# Common Muesli tasks — `make help` lists everything.
#
# Signing identity is resolved at recipe time (identity names contain
# parentheses, which Make's $(shell ...) cannot parse). First match wins:
#   1. `make SIGN_IDENTITY="..."`   — explicit override
#   2. the official Developer ID cert, when present in the keychain
#   3. the first codesigning identity in the keychain (personal Apple
#      Development cert on contributor machines)
#
# A non-Developer-ID identity cannot back the iCloud/CloudKit entitlements in
# scripts/Muesli.entitlements without a provisioning profile, so those builds
# sign with scripts/MuesliLocalOnly.entitlements instead (iCloud sync off).
# DMGs signed this way are fine locally but are NOT notarized — Gatekeeper
# will warn on other machines. Notarized builds must go through `make release`.

OFFICIAL_SIGN_IDENTITY := Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)

# Pure shell (expanded inside recipes): resolve the identity, then pick
# entitlements — the official profile only when signing as the official
# Developer ID, local-only otherwise, ENTITLEMENTS=path always wins.
define resolve_signing
muesli_identity='$(SIGN_IDENTITY)'; \
if [ -z "$$muesli_identity" ]; then \
  muesli_identity=$$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]* "\(.*\)"$$/\1/p' | head -n 1); \
fi; \
if [ -z "$$muesli_identity" ]; then \
  echo "error: no codesigning identity found in the keychain. Pass SIGN_IDENTITY=\"...\"." >&2; \
  exit 2; \
fi; \
muesli_ent='$(ENTITLEMENTS)'; \
if [ -z "$$muesli_ent" ]; then \
  case "$$muesli_identity" in \
    "$(OFFICIAL_SIGN_IDENTITY)") muesli_ent='scripts/Muesli.entitlements' ;; \
    *) muesli_ent='scripts/MuesliLocalOnly.entitlements' ;; \
  esac; \
fi; \
echo "Signing: $$muesli_identity ($$muesli_ent)"
endef

# Optional passthroughs: VERSION=1.2.3 stamps CFBundleShortVersionString;
# XCODE=1 pins the xcodebuild path so App Intents metadata ships (Shortcuts).
ifneq ($(VERSION),)
VERSION_ENV := MUESLI_BUILD_VERSION=$(VERSION)
endif
ifneq ($(XCODE),)
XCODE_ENV := MUESLI_USE_XCODE_BUILD=1
endif

.DEFAULT_GOAL := help
.PHONY: help config build dmg dev test release clean

help:
	@echo "Muesli — common tasks"
	@echo "  make build               Signed Muesli.app installed to /Applications (replaces existing)"
	@echo "  make dmg                 Signed installer at dist-release/Muesli-<version>.dmg (builds first)"
	@echo "  make dev                 Isolated dev/test build, MuesliDev.app (LANE=A/B/C for parallel lanes)"
	@echo "  make test                Run the SwiftPM test suite"
	@echo "  make release VERSION=x   Official notarized release (needs Developer ID + MuesliNotary profile)"
	@echo "  make config              Show resolved signing identity and entitlements"
	@echo "  make clean               Remove dist-native and temp DMG staging"
	@echo ""
	@echo "Options: VERSION=1.2.3  XCODE=1  LANE=A  SIGN_IDENTITY=\"...\"  ENTITLEMENTS=path"
	@echo "Other MUESLI_* env vars (telemetry, scratch paths, ...) pass straight through to the scripts."

config:
	@$(resolve_signing)

build:
	@$(resolve_signing); \
	$(VERSION_ENV) $(XCODE_ENV) \
	MUESLI_SIGN_IDENTITY="$$muesli_identity" MUESLI_ENTITLEMENTS="$$muesli_ent" \
	./scripts/build_native_app.sh

dmg: build
	@$(resolve_signing); \
	$(VERSION_ENV) \
	MUESLI_SIGN_IDENTITY="$$muesli_identity" \
	./scripts/create_dmg.sh /Applications/Muesli.app dist-release

DEV_ARGS := $(if $(LANE),--lane $(LANE),)

dev:
	./scripts/dev-test.sh $(DEV_ARGS)

test:
	swift test --package-path native/MuesliNative

release:
	./scripts/release.sh $(VERSION)

clean:
	rm -rf dist-native
	rm -f dist-release/_temp_*.dmg
