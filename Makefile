APP_NAME   := Nutola
BUNDLE_ID  := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' packaging/Info.plist)
DIST       := dist
APP        := $(DIST)/$(APP_NAME).app
BINARY     := .build/release/$(APP_NAME)
# Ad-hoc by default. For a stable TCC identity across rebuilds we pin an explicit
# designated requirement. Set SIGN_ID to your "Apple Development: ..." identity
# for the best experience (permissions survive rebuilds without re-prompting).
# Release builds use the same signing configuration unless SIGN_ID is supplied.
SIGN_ID    ?= -

# Hardened Runtime (-o runtime + entitlements) is required for notarization and is the
# default: verified end-to-end on 2026-07-09 — it launches cleanly and a real recording
# captures BOTH the mic AND the Core Audio system-audio process tap, then transcribes,
# diarizes (2 speakers) and summarizes, all under -o runtime with only com.apple.security.*
# entitlements (no provisioning profile needed). Set HARDENED=0 for a plain ad-hoc
# signature (no runtime/entitlements) if ever needed for debugging.
HARDENED   ?= 1
ifeq ($(HARDENED),1)
RUNTIME_ARGS := -o runtime --entitlements packaging/Nutola.entitlements
else
RUNTIME_ARGS :=
endif

.PHONY: build test app run install relaunch app-icon nav-icon clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BINARY)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp packaging/Info.plist "$(APP)/Contents/Info.plist"
	@# Stamp the version from VERSION (single source of truth) into the
	@# bundled Info.plist. CFBundleShortVersionString = VERSION;
	@# CFBundleVersion = VERSION with dots stripped (build number).
	@V=$$(cat VERSION 2>/dev/null | tr -d ' \n'); \
	B=$$(echo "$$V" | tr -d '.'); \
	python3 -c "import plistlib; p='$(APP)/Contents/Info.plist'; d=plistlib.load(open(p,'rb')); d['CFBundleShortVersionString']='$$V'; d['CFBundleVersion']='$$B'; plistlib.dump(d, open(p,'wb'))"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp LICENSE "$(APP)/Contents/Resources/LICENSE"
	@# SwiftPM resource bundle (menu bar icon) must ride along or Bundle.module lookups fail
	@if [ -d ".build/release/$(APP_NAME)_$(APP_NAME).bundle" ]; then \
		cp -R ".build/release/$(APP_NAME)_$(APP_NAME).bundle" "$(APP)/Contents/Resources/"; \
	fi
	@# RUNTIME_ARGS is empty for local dev (HARDENED=0) and adds -o runtime + entitlements
	@# for the notarizable release build (HARDENED=1). All entitlements are
	@# com.apple.security.* keys, honored ad-hoc with no provisioning profile.
	codesign --force --sign "$(SIGN_ID)" $(RUNTIME_ARGS) \
		-r='designated => identifier "$(BUNDLE_ID)"' "$(APP)"
	codesign --verify --deep --strict "$(APP)"
	@echo "Built $(APP) (HARDENED=$(HARDENED))"

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "/Applications/$(APP_NAME).app"
	@echo "Installed to /Applications/$(APP_NAME).app"

# Kill running instance, wipe old bundles, rebuild, install to /Applications, and launch.
relaunch:
	-pkill -x $(APP_NAME)
	rm -rf "/Applications/$(APP_NAME).app" "$(APP)"
	$(MAKE) install
	open "/Applications/$(APP_NAME).app"

# Regenerate the nav-bar template glyphs loaded via Bundle.module.
nav-icon:
	swift scripts/MakeIcon.swift Resources menu
	cp Resources/NavIcon.png Resources/NavIcon@2x.png Sources/Nutola/Resources/
	rm -f Resources/NavIcon.png Resources/NavIcon@2x.png Resources/NavIcon-preview.png

# Regenerate the app icon from Resources/AppIcon.svg: .icns and 1024 master.
app-icon:
	swift scripts/MakeIcon.swift Resources app
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	rm -rf Resources/AppIcon.iconset

clean:
	rm -rf .build "$(DIST)"
