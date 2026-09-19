APP  := TokenPacer
## An ad-hoc signature is a fresh identity every build. Nothing reads the Keychain
## any more, so no grant rides on it — but Sparkle keys updates to the designated
## requirement, and an ad-hoc one changes on every rebuild. A real signing identity
## keeps it stable. Override with `make app SIGN=-` to go back to ad-hoc.
SIGN ?= $(shell security find-identity -v -p codesigning | awk 'NR==1{print $$2}')
ifeq ($(strip $(SIGN)),)
SIGN := -
endif
BIN  := .build/release/$(APP)
DEST := build/$(APP).app

## Marketing version from the plist; build number from the commit count, so it
## only ever goes up. Sparkle compares CFBundleVersion, not the pretty one.
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" TokenPacer/Info.plist)
BUILD   ?= $(shell git rev-list --count HEAD)
DMG     := build/$(APP)-$(VERSION).dmg

## Where the public can reach this. The source repo is private, and a private
## repo's release assets have no unauthenticated URL at all — nothing Sparkle or
## Homebrew fetches can live in it. Two public repos carry that instead: the site
## serves the feed from a domain we own, so it survives a move off GitHub, and the
## tap carries the cask. Both are checked out beside this one.
SITE_REPO ?= heybui/tokenpacer.com
SITE_DIR  ?= ../tokenpacer.com
TAP_REPO  ?= redevify/homebrew-tap
TAP_DIR   ?= ../homebrew-tap
## Per release, so it is never the URL baked into a build — only the feed is that,
## and the feed is the domain.
RELEASE_URL := https://github.com/$(SITE_REPO)/releases/download

## Distribution needs a *Developer ID Application* certificate — the Apple
## Development one above is for this machine only and cannot be notarized.
## Requires the paid Developer Program.
DEVID   := $(shell security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $$2}')
## `xcrun notarytool store-credentials token-pacer` once, then it is silent.
NOTARY_PROFILE ?= token-pacer
## CI keeps its credentials in a throwaway keychain rather than the login one,
## so it overrides this with the same profile plus `--keychain <path>`.
NOTARY_ARGS ?= --keychain-profile $(NOTARY_PROFILE)
## Empty locally: the EdDSA key is read from the login Keychain. CI writes the
## key to a file and passes `--ed-key-file` here — there is no Keychain to read.
APPCAST_ARGS ?=

## Sparkle ships as an XCFramework. SPM links it but cannot embed it, so the
## bundle assembly below copies it in and signs it inside-out. Checked in under
## Vendor rather than downloaded per checkout — see Vendor/Sparkle/Package.swift.
SPARKLE := Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
SPARKLE_BIN := Vendor/Sparkle/bin
## Release signing adds these; a debug build gets neither.
SIGNFLAGS ?=

.PHONY: icon run build app test xcbuild xctest clean release-app dmg notarize cask appcast check-devid release

## SPM links Sparkle but leaves no usable rpath in the bare binary, so an
## in-place run has to be told where the framework is. The bundle does not need
## this: `app` copies the framework in and adds its own rpath.
run:    ## debug build, run in place (accessory app: no Dock icon)
	DYLD_FRAMEWORK_PATH=$(dir $(SPARKLE)) swift run $(APP)

test:
	swift test

build:
	swift build -c release

## Rebuild the bundle icon from the design export. The ladder ships as
## `icon_512x512_2x.png`; `iconutil` only recognises `@2x`, and silently drops
## every file it does not recognise — a rename away from an icns that stops at
## 512 and looks blurred on a Retina Finder.
ICONSET := design/project/icons/iconset/transparent
icon:   ## regenerate TokenPacer.icns from design/project/icons
	@rm -rf build/$(APP).iconset && mkdir -p build/$(APP).iconset
	@for f in $(ICONSET)/icon_*.png; do \
	  cp "$$f" "build/$(APP).iconset/$$(basename $$f | sed 's/_2x\.png/@2x.png/')"; \
	done
	iconutil -c icns build/$(APP).iconset -o TokenPacer/Resources/$(APP).icns
	@rm -rf build/$(APP).iconset
	@echo "→ TokenPacer/Resources/$(APP).icns"

## Assemble a real .app bundle. Xcode is not needed until Sparkle lands in phase 6.
app: build
	rm -rf $(DEST)
	mkdir -p $(DEST)/Contents/MacOS $(DEST)/Contents/Resources
	cp $(BIN) $(DEST)/Contents/MacOS/$(APP)
	cp TokenPacer/Info.plist $(DEST)/Contents/Info.plist
	cp TokenPacer/Resources/InstrumentSans.ttf $(DEST)/Contents/Resources/
	cp TokenPacer/Resources/TokenPacer.icns $(DEST)/Contents/Resources/TokenPacer.icns
	mkdir -p $(DEST)/Contents/Frameworks
	cp -R $(SPARKLE) $(DEST)/Contents/Frameworks/
	install_name_tool -add_rpath @executable_path/../Frameworks $(DEST)/Contents/MacOS/$(APP)
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	                        -c "Set :CFBundleVersion $(BUILD)" $(DEST)/Contents/Info.plist
	@# Inside-out, never --deep: the signature of a bundle covers what it
	@# contains, so nested code has to be signed before the thing containing it.
	codesign --force --sign $(SIGN) $(SIGNFLAGS) \
	  $(DEST)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc \
	  $(DEST)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc \
	  $(DEST)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app \
	  $(DEST)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	codesign --force --sign $(SIGN) $(SIGNFLAGS) $(DEST)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign $(SIGN) $(SIGNFLAGS) $(ENTITLE) $(DEST)
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
release-app: check-devid
	$(MAKE) app SIGN=$(DEVID) SIGNFLAGS="--options runtime --timestamp" \
	            ENTITLE="--entitlements TokenPacer/TokenPacer.entitlements"
	codesign --verify --strict --deep --verbose=2 $(DEST)

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
	@# Gatekeeper assesses the image itself, not just the app inside it, so
	@# the image carries its own signature. Stapling afterwards only appends
	@# the ticket, which leaves that signature intact.
	codesign --force --sign $(DEVID) --timestamp $(DMG)
	@echo "→ $(DMG)"

## `appcast` and `cask` both describe an image that already exists — the one Apple
## stapled. Rebuilding it here would hand them a different file from the one that
## was notarized, so the image is a prerequisite they check rather than build.
$(DMG):
	@echo "No $(DMG) yet. Run 'make dmg' or 'make notarize' first: the feed and"; \
	 echo "the cask have to describe the stapled image, not a freshly built one."; \
	 exit 1

## The feed Sparkle reads. Uploaded as a release asset next to the DMG, so
## `releases/latest/download/appcast.xml` always points at the newest one.
## Signs each update with the EdDSA key in the login Keychain — without it an
## installed copy refuses the download, which is the whole point of the key.
appcast: $(DMG)
	@# Against `build` itself the tool would pick up every leftover in the
	@# scratch directory — an old ad-hoc zip, a delta against it — and write
	@# them into the feed as enclosures the release never uploads. Staging
	@# holds exactly what ships, so the feed cannot describe anything else.
	rm -rf build/feed && mkdir -p build/feed
	cp $(DMG) build/feed/
	$(SPARKLE_BIN)/generate_appcast $(APPCAST_ARGS) --download-url-prefix \
	  $(RELEASE_URL)/v$(VERSION)/ build/feed
	cp build/feed/appcast.xml build/appcast.xml
	@echo "→ build/appcast.xml"

## Apple staples the ticket to the image, so a first launch works offline.
notarize: dmg
	xcrun notarytool submit $(DMG) $(NOTARY_ARGS) --wait
	xcrun stapler staple $(DMG)
	spctl --assess --type open --context context:primary-signature -v $(DMG)
	@echo "→ notarized $(DMG)"

## Generated, never checked in: only the version and the hash change per release,
## and a stale copy in the repo is how a tap ships the wrong checksum.
cask: $(DMG)
	@mkdir -p build
	@printf '%s\n' \
	'cask "token-pacer" do' \
	'  version "$(VERSION)"' \
	'  sha256 "$(shell shasum -a 256 $(DMG) | cut -d" " -f1)"' \
	'' \
	'  url "$(RELEASE_URL)/v#{version}/$(APP)-#{version}.dmg"' \
	'  name "Token Pacer"' \
	'  desc "Claude Code and Codex usage in the notch"' \
	'  homepage "https://tokenpacer.com"' \
	'' \
	'  depends_on macos: ">= :sequoia"' \
	'' \
	'  app "$(APP).app"' \
	'' \
	'  zap trash: [' \
	'    "~/Library/Application Support/TokenPacer",' \
	'    "~/Library/Preferences/com.redevify.token-pacer.plist",' \
	'  ]' \
	'end' > build/token-pacer.rb
	@echo "→ build/token-pacer.rb"

## Cut a release. Everything above this line is local; this is the only target
## that publishes, and the only one that pushes anywhere.
##
## Sequenced by hand rather than by prerequisites, because the order is load
## bearing: stapling rewrites the disk image, so the feed has to be generated
## after it or it signs bytes nobody downloads.
release:
	$(MAKE) notarize
	$(MAKE) appcast
	$(MAKE) cask
	@# Notes come from this repo's log. --generate-notes reads the repo the
	@# release is created in, which is the website: it would list landing-page
	@# commits under an app version. No tag yet means the whole history.
	git log --no-merges --pretty='- %s' \
	  $$(git describe --tags --abbrev=0 2>/dev/null || git rev-list --max-parents=0 HEAD)..HEAD \
	  > build/notes.md
	gh release create v$(VERSION) --repo $(SITE_REPO) \
	  --title "$(APP) $(VERSION)" --notes-file build/notes.md $(DMG) build/appcast.xml
	@# Tag here too, so the next release knows where these notes start.
	git tag -a v$(VERSION) -m "$(APP) $(VERSION)"
	git push origin v$(VERSION)
	@# The feed lives at the domain, not at the release: a build polls the URL it
	@# shipped with for ever, and that one has to outlive wherever the DMG sits.
	@# It goes in public/ — the site deploys dist/, built from src/ and public/,
	@# so a copy at the repo root is never served and Sparkle would 404.
	cp build/appcast.xml $(SITE_DIR)/public/appcast.xml
	git -C $(SITE_DIR) add public/appcast.xml
	git -C $(SITE_DIR) commit -m "release: $(APP) $(VERSION)"
	git -C $(SITE_DIR) push
	@# The tap is a convenience, not the product: Sparkle and the DMG above
	@# are how anyone actually gets the app. A release must not fail because
	@# the tap is not checked out beside this repo — which is also what lets
	@# CI run this same target without one.
	@if [ -d "$(TAP_DIR)/.git" ]; then \
	  mkdir -p $(TAP_DIR)/Casks; \
	  cp build/token-pacer.rb $(TAP_DIR)/Casks/token-pacer.rb; \
	  git -C $(TAP_DIR) add Casks/token-pacer.rb; \
	  git -C $(TAP_DIR) commit -m "token-pacer $(VERSION)"; \
	  git -C $(TAP_DIR) push; \
	else \
	  echo "No tap at $(TAP_DIR) — skipped the cask; build/token-pacer.rb is ready."; \
	fi
	@echo "→ released $(APP) $(VERSION)"

xcbuild:   ## shipping path: signing, entitlements, hardened runtime
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Debug build

xctest:
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Debug test

clean:
	rm -rf .build build
