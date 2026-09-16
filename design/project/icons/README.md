# @ is not allowed in project filenames, so @2x files ship as _2x.
# Rebuild a real .iconset (run inside icons/transparent or icons/opaque):

mkdir -p BurnTracker.iconset
for f in icon_*.png; do cp "$f" "BurnTracker.iconset/${f/_2x/@2x}"; done
iconutil -c icns BurnTracker.iconset -o BurnTracker.icns
