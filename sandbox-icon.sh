#!/usr/bin/env bash
# Badge an app icon with a "#" mark and install it into the user's icon theme,
# so a sandboxed launcher can be told apart from the real one.
#
#   sandbox-icon.sh [-o NAME] ICON
#
# ICON is an icon name (looked up in the hicolor theme and /usr/share/pixmaps)
# or a path to a PNG/SVG. The result is installed as
# ~/.local/share/icons/hicolor/<size>x<size>/apps/NAME.png for the usual
# sizes (default NAME: <icon>-sandboxed) and the name is printed, ready for
# an Icon= line. Needs ImageMagick 7 (magick).
set -eu

usage() { echo "usage: sandbox-icon.sh [-o NAME] ICON" >&2; exit 2; }

NAME=""
while getopts o:h OPT; do
  case "$OPT" in
    o) NAME="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
ICON="$1"

# resolve an icon name to its largest available file
SRC=""
if [ -f "$ICON" ]; then
  SRC="$ICON"
else
  for DIR in "$HOME/.local/share/icons" /usr/share/icons /var/lib/snapd/desktop/icons; do
    for F in "$DIR"/hicolor/scalable/apps/"$ICON".svg; do [ -f "$F" ] && SRC="$F" && break 2; done
    for S in 1024 512 256 128 96 64 48; do
      for F in "$DIR"/hicolor/${S}x${S}/apps/"$ICON".png; do [ -f "$F" ] && SRC="$F" && break 3; done
    done
  done
  [ -n "$SRC" ] || for F in /usr/share/pixmaps/"$ICON".png /usr/share/pixmaps/"$ICON".svg; do
    [ -f "$F" ] && SRC="$F" && break
  done
fi
[ -n "$SRC" ] || { echo "sandbox-icon.sh: icon not found: $ICON" >&2; exit 1; }
if [ -z "$NAME" ]; then
  NAME="$(basename "$ICON")"; NAME="${NAME%.*}-sandboxed"
fi

MASTER=512   # badge is drawn once at this size and scaled down with the icon
DEST="$HOME/.local/share/icons/hicolor"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The badge: a dark rounded square in the bottom-right corner, holding a
# white "#" — it covers ~40% of the edge so it survives downscaling. The
# source is drawn onto a MASTER-sized transparent canvas (SVGs rasterised at
# high density) so the badge geometry is the same for every icon.
B=$((MASTER * 40 / 100)); R=$((B / 5)); P=$((MASTER / 32))
X0=$((MASTER - P - B)); Y0=$((MASTER - P - B))
magick -background none -density 300 "$SRC[0]" -density 72 \
  -resize "${MASTER}x${MASTER}" -gravity center -extent "${MASTER}x${MASTER}" \
  \( -size "${MASTER}x${MASTER}" xc:none \
     -fill '#202020' -stroke white -strokewidth $((MASTER / 64)) \
     -draw "roundrectangle $X0,$Y0 $((X0 + B)),$((Y0 + B)) $R,$R" \) \
  -compose over -composite \
  \( -size "$((B * 3 / 4))x$((B * 3 / 4))" -background none -fill white \
     -font DejaVu-Sans-Bold -gravity center label:'#' \) \
  -gravity northwest -geometry "+$((X0 + B / 8))+$((Y0 + B / 8))" -composite \
  "$TMP/master.png"

for S in 512 256 128 96 64 48 32 24 22 16; do
  mkdir -p "$DEST/${S}x${S}/apps"
  magick "$TMP/master.png" -resize "${S}x${S}" "$DEST/${S}x${S}/apps/$NAME.png"
done
[ -f "$DEST/index.theme" ] || cp /usr/share/icons/hicolor/index.theme "$DEST/" 2>/dev/null || true
# GTK reads a prebuilt index; KDE has only a lazy runtime cache (KIconLoader),
# so instead tell running KDE apps to drop it — matters when re-badging an
# existing name or when a launcher was shown before its icon existed
gtk-update-icon-cache -q -t -f "$DEST" 2>/dev/null || true
dbus-send --session --type=signal /KIconLoader org.kde.KIconLoader.iconChanged int32:0 2>/dev/null || true
echo "$NAME"
