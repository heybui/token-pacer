# Token Pacer icon assets — one generation, exported together.
# Mark: notch bite + 80%-wide pace bar, three capsules (2% gaps), marker resting in the safe capsule.
# Zone boundaries: watch from 70%, over from 95%. Marker rest: pace 0.50.

icons/iconset/transparent/  icon_*.png ladder for .icns (alpha corners)
icons/iconset/opaque/       same ladder, corners filled with the ground colour
icons/mark/transparent/     flat token-pacer-<size>.png for web, docs, README
icons/mark/opaque/          same, opaque

# @ is not allowed in project filenames, so @2x files ship as _2x.
# Rebuild a real .iconset (run inside icons/iconset/transparent or icons/iconset/opaque):

mkdir -p TokenPacer.iconset
for f in icon_*.png; do cp "$f" "TokenPacer.iconset/${f/_2x/@2x}"; done
iconutil -c icns TokenPacer.iconset -o TokenPacer.icns
