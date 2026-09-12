#!/bin/bash

# Install Barback into ~/.config/omarchy/plugins/ninepointlabs.barback.
#
# Copies runtime assets only, validates the staged copy before it goes live,
# and swaps it in with an atomic rename that rolls back on failure. It does
# not enable the plugin, does not touch the bar layout, and does not restart
# the shell — placing the chip is a separate, deliberate step:
#
#   omarchy bar put ninepointlabs.barback --section right
#
# Usage: ./install.sh [--bin-dir <dir>] [--no-cli]

set -euo pipefail

PLUGIN_ID="ninepointlabs.barback"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
DEST="$PLUGINS_DIR/$PLUGIN_ID"
BIN_DIR="$HOME/.local/bin"
INSTALL_CLI=1

die() { echo "install: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir) BIN_DIR="${2:-}"; shift 2 ;;
    --no-cli)  INSTALL_CLI=0; shift ;;
    -h|--help) sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

command -v omarchy-plugin-validate >/dev/null 2>&1 \
  || die "omarchy-plugin-validate not found; is Omarchy installed?"

# A symlinked destination (or a symlinked path to it) would let the copy land
# somewhere that is none of our business.
[[ -L $DEST ]] && die "$DEST is a symlink; refusing to install over it"
for part in "$HOME/.config" "$HOME/.config/omarchy" "$PLUGINS_DIR"; do
  [[ -e $part && -L $part ]] && die "$part is a symlink; refusing to install through it"
done
mkdir -p "$PLUGINS_DIR"

# Every runtime asset. A missing file here is the classic blank-chip bug.
ASSETS=(manifest.json BarWidget.qml Model.js README.md LICENSE)

# Stage beside the live directory so the final move is a rename on the same
# filesystem, not a copy that can be interrupted half way.
STAGE="$(mktemp -d "$PLUGINS_DIR/.$PLUGIN_ID.stage.XXXXXXXX")"
BACKUP=""
cleanup() {
  [[ -n $STAGE ]] && rm -rf "$STAGE"
  if [[ -n $BACKUP && -d $BACKUP ]]; then
    rm -rf "$DEST"
    mv "$BACKUP" "$DEST"
    echo "install: rolled back to the previous install" >&2
  fi
}
trap cleanup EXIT

for asset in "${ASSETS[@]}"; do
  [[ -f "$SRC/$asset" ]] || die "missing runtime asset: $asset"
  cp "$SRC/$asset" "$STAGE/$asset"
done
mkdir -p "$STAGE/bin"
cp "$SRC/bin/barback" "$STAGE/bin/barback"
chmod +x "$STAGE/bin/barback"

omarchy-plugin-validate "$STAGE" || die "the staged copy failed validation; nothing was installed"

if [[ -d $DEST ]]; then
  BACKUP="$(mktemp -d "$PLUGINS_DIR/.$PLUGIN_ID.prev.XXXXXXXX")"
  rmdir "$BACKUP"
  mv "$DEST" "$BACKUP"
fi
mv "$STAGE" "$DEST"
STAGE=""
chmod 755 "$DEST"

# Past this point the install has landed; do not roll it back.
if [[ -n $BACKUP ]]; then
  rm -rf "$BACKUP"
  BACKUP=""
fi

echo "installed $PLUGIN_ID to $DEST"

if [[ $INSTALL_CLI -eq 1 ]]; then
  mkdir -p "$BIN_DIR"
  cp "$DEST/bin/barback" "$BIN_DIR/barback"
  chmod +x "$BIN_DIR/barback"
  echo "installed the barback CLI to $BIN_DIR/barback"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on your PATH" ;;
  esac
fi

cat <<NEXT

Not done automatically, on purpose:
  1. Put the chip on the bar:  omarchy bar put $PLUGIN_ID --section right
  2. Park something in it:     barback add <plugin-id>

An empty drawer is one small dimmed chip: click it and pick a widget, which is
step 2 without the CLI.
NEXT
