#!/usr/bin/env bash
# install.sh — link the Claude usage plugin into SwiftBar's plugin directory.
#
# Idempotent. Never deletes files it did not create.
#
# Usage:
#   ./install.sh             # link the plugin
#   ./install.sh --dry-run   # report only, change nothing
#   ./install.sh --uninstall # remove the link

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="claude-usage.180s.sh"
SRC="$SCRIPT_DIR/$PLUGIN"
SWIFTBAR_DOMAIN="com.ameba.SwiftBar"
DEFAULT_DIR="$HOME/.config/swiftbar/plugins"

usage() { echo "usage: $0 [--dry-run|--uninstall]" >&2; }

MODE=install
case "${1:-}" in
  "")          ;;
  --dry-run)   MODE=dry ;;
  --uninstall) MODE=uninstall ;;
  -h|--help)   sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)           echo "unknown argument: $1" >&2; usage; exit 2 ;;
esac

status() { printf '%-9s %s\n' "$1" "$2"; }
fail()   { printf '%-9s %s\n' "ERROR" "$1" >&2; exit 1; }

refresh() { pgrep -qx SwiftBar && open -g "swiftbar://refreshallplugins" 2>/dev/null; }

[[ -d /Applications/SwiftBar.app ]] || fail "SwiftBar is not installed — brew install --cask swiftbar"

# SwiftBar records the folder you picked at first launch. Read it so we link
# into the folder actually in use; fall back to a conventional one otherwise.
plugin_dir=$(defaults read "$SWIFTBAR_DOMAIN" PluginDirectory 2>/dev/null)
picked=yes
if [[ -z "$plugin_dir" ]]; then
  plugin_dir="$DEFAULT_DIR"
  picked=no
fi
dst="$plugin_dir/$PLUGIN"

case "$MODE" in
  uninstall)
    if [[ -L "$dst" && "$(readlink -- "$dst")" == "$SRC" ]]; then
      unlink "$dst" || fail "could not remove $dst"
      status "REMOVE" "$dst"
      refresh
    elif [[ -e "$dst" ]]; then
      fail "$dst exists but is not our symlink — leaving it alone"
    else
      status "SKIP" "not installed"
    fi
    ;;
  dry|install)
    if [[ -L "$dst" && "$(readlink -- "$dst")" == "$SRC" ]]; then
      status "SKIP" "$dst (already linked)"
    elif [[ -e "$dst" || -L "$dst" ]]; then
      fail "$dst already exists and is not our symlink"
    elif [[ "$MODE" == dry ]]; then
      status "DRY-LINK" "$dst -> $SRC"
    else
      chmod +x "$SRC" || fail "could not make $SRC executable"
      mkdir -p "$plugin_dir" || fail "could not create $plugin_dir"
      ln -s -- "$SRC" "$dst" || fail "could not link $dst"
      status "LINK" "$dst -> $SRC"
      refresh
    fi
    ;;
esac

# Nothing was configured, so point SwiftBar at the folder we just linked into.
# The Homebrew build is not sandboxed, so this preference is usually enough;
# SwiftBar may still show its folder picker on a first launch.
if [[ "$picked" == no && "$MODE" == install ]]; then
  if defaults write "$SWIFTBAR_DOMAIN" PluginDirectory -string "$plugin_dir"; then
    status "PREFS" "PluginDirectory = $plugin_dir"
  fi
  echo
  echo "If SwiftBar asks you to choose a plugin folder, pick:"
  echo "    $plugin_dir"
  echo "(press Cmd-Shift-G in the picker to type that path)"
fi
