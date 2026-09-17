# @ is not allowed in project filenames, so @2x files ship as _2x.
# Rebuild a real .iconset (run inside icons/transparent or icons/opaque):

mkdir -p TokenPacer.iconset
for f in icon_*.png; do cp "$f" "TokenPacer.iconset/${f/_2x/@2x}"; done
iconutil -c icns TokenPacer.iconset -o TokenPacer.icns
