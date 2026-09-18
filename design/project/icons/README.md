# Token Pacer icon assets — one generation, exported together.
# Mark: notch bite + 80%-wide pace bar, three capsules (2% gaps), marker resting in the safe capsule.
# Zone boundaries: watch from 75%, over from 90%. Marker rest: pace 0.375.
# Zones: safe #3ec98a, watch #e8b33c, over #e2543f. Ground #1d1f26, bite #0f1014.
# Sizes under 64px use the exaggerated 50/25/25 split so watch and over stay legible.

icons/iconset/transparent/  icon_*.png ladder for .icns (alpha corners)
icons/iconset/opaque/       same ladder, corners filled with the ground colour
icons/mark/transparent/     flat token-pacer-<size>.png for web, docs, README
icons/mark/opaque/          same, opaque

# @ is not allowed in project filenames, so @2x files ship as _2x.
# Rebuild a real .iconset (run inside icons/iconset/transparent or icons/iconset/opaque):

mkdir -p TokenPacer.iconset
for f in icon_*.png; do cp "$f" "TokenPacer.iconset/${f/_2x/@2x}"; done
iconutil -c icns TokenPacer.iconset -o TokenPacer.icns
