APP  := BurnTracker
BIN  := .build/release/$(APP)
DEST := build/$(APP).app

.PHONY: run build app test xcbuild xctest clean

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
	codesign --force --deep --sign - $(DEST)
	@echo "→ $(DEST)"

xcbuild:   ## shipping path: signing, entitlements, hardened runtime
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Debug build

xctest:
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Debug test

clean:
	rm -rf .build build
