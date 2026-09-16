APP  := BurnTracker
## An ad-hoc signature is a fresh identity every build, and the Keychain ACL on
## Claude Code's credentials is keyed to it — so "Always Allow" is granted to a
## binary that the next build replaces, and the password prompt returns. A real
## signing identity keeps the designated requirement stable across rebuilds.
## Override with `make app SIGN=-` to go back to ad-hoc.
SIGN ?= $(shell security find-identity -v -p codesigning | awk 'NR==1{print $$2}')
ifeq ($(strip $(SIGN)),)
SIGN := -
endif
BIN  := .build/release/$(APP)
DEST := build/$(APP).app

## Marketing version from the plist; build number from the commit count, so it
## only ever goes up. Sparkle compares CFBundleVersion, not the pretty one.
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD   ?= $(shell git rev-list --count HEAD)
DMG     := build/$(APP)-$(VERSION).dmg

## Distribution needs a *Developer ID Application* certificate — the Apple
## Development one above is for this machine only and cannot be notarized.
## Requires the paid Developer Program.
DEVID   := $(shell security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $$2}')
## `xcrun notarytool store-credentials burn-tracker` once, then it is silent.
NOTARY_PROFILE ?= burn-tracker

.PHONY: run build app test xcbuild xctest clean release-app dmg notarize cask check-devid

run:    ## debug build, run in place (accessory app: no Dock icon)
	swift run $(APP)

test:
	swift test

build:
	swift build -c release

## Assemble a real .app bundle. Xcode is not needed until Sparkle lands in phase 6.
app: build
	rm -rf $(DEST)
	mkdir -p $(DEST)/Contents/MacOS $(DEST)/Contents/Resources
	cp $(BIN) $(DEST)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(DEST)/Contents/Info.plist
	cp -R Resources/Fonts $(DEST)/Contents/Resources/Fonts
	cp Resources/BurnTracker.icns $(DEST)/Contents/Resources/BurnTracker.icns
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	                        -c "Set :CFBundleVersion $(BUILD)" $(DEST)/Contents/Info.plist
	codesign --force --deep --sign $(SIGN) $(DEST)
	@echo "→ $(DEST) $(VERSION) ($(BUILD))"

# MARK: - distribution

check-devid:
	@test -n "$(DEVID)" || { \
	  echo "No 'Developer ID Application' certificate in the Keychain."; \
	  echo "It needs the paid Apple Developer Program: create the certificate at"; \
	  echo "developer.apple.com/account/resources/certificates, download it, and"; \
	  echo "double-click to install. An Apple Development certificate cannot be"; \
	  echo "notarized and Gatekeeper will refuse the app on any other Mac."; \
	  exit 1; }

## The same bundle, signed for other people's machines: hardened runtime, a
## trusted timestamp, and the entitlements that say this app is not sandboxed.
## No --deep — it signs nested code wrong, and Apple's own advice is against it.
release-app: check-devid build
	$(MAKE) app SIGN=$(DEVID)
	codesign --force --sign $(DEVID) --options runtime --timestamp \
	         --entitlements Resources/BurnTracker.entitlements $(DEST)
	codesign --verify --strict --verbose=2 $(DEST)

## Drag-to-Applications disk image. No create-dmg dependency: a staging folder
## and a symlink is the whole feature.
dmg: release-app
	rm -rf build/dmg $(DMG)
	mkdir -p build/dmg
	cp -R $(DEST) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "$(APP) $(VERSION)" -srcfolder build/dmg \
	               -ov -format UDZO $(DMG)
	rm -rf build/dmg
	@echo "→ $(DMG)"

## Apple staples the ticket to the image, so a first launch works offline.
notarize: dmg
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)
	spctl --assess --type open --context context:primary-signature -v $(DMG)
	@echo "→ notarized $(DMG)"

## Generated, never checked in: only the version and the hash change per release,
## and a stale copy in the repo is how a tap ships the wrong checksum.
cask: dmg
	@mkdir -p build
	@printf '%s\n' \
	'cask "burn-tracker" do' \
	'  version "$(VERSION)"' \
	'  sha256 "$(shell shasum -a 256 $(DMG) | cut -d" " -f1)"' \
	'' \
	'  url "https://github.com/heybui/burn-tracker/releases/download/v#{version}/$(APP)-#{version}.dmg"' \
	'  name "Burn Tracker"' \
	'  desc "Claude Code and Codex usage in the notch"' \
	'  homepage "https://github.com/heybui/burn-tracker"' \
	'' \
	'  depends_on macos: ">= :sequoia"' \
	'' \
	'  app "$(APP).app"' \
	'' \
	'  zap trash: [' \
	'    "~/Library/Application Support/BurnTracker",' \
	'    "~/Library/Preferences/com.redevify.tokenburn.plist",' \
	'  ]' \
	'end' > build/burn-tracker.rb
	@echo "→ build/burn-tracker.rb"

xcbuild:   ## shipping path: signing, entitlements, hardened runtime
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Debug build

xctest:
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Debug test

clean:
	rm -rf .build build
