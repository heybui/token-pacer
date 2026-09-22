-- The disk image's window, arranged once by hand.
--
-- Running this writes a `.DS_Store` on the mounted volume; that file is what
-- `make dmg` copies in, so no release has to talk to Finder. Which matters:
-- releases are cut on a GitHub runner, where there is no Finder session to
-- talk to.
--
-- To change the layout: `make dmg-layout`, then commit what it writes back to
-- `packaging/dmg-DS_Store`. The icon positions here and the arrow drawn by
-- `make-background.swift` are the same two coordinates twice — move one and
-- the arrow points at nothing.
tell application "Finder"
  tell disk "Token Pacer"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 640 x 440 of content, which is the size the background is drawn at.
    set the bounds of container window to {300, 140, 940, 580}

    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 12
    set label position of opts to bottom
    set background picture of opts to file ".background:background.tiff"

    set position of item "TokenPacer.app" of container window to {160, 200}
    set position of item "Applications" of container window to {480, 200}

    update without registering applications
    delay 2
    close
  end tell
end tell
