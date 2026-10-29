#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 PremiereNux contributors
# Removes what install.sh put on this machine: the install folder (Wine runner, prefix with Premiere, drivers, logs), the
# menu entry, the settings file and the vm.max_map_count file. Files that Premiere's users saved in the prefix (Documents,
# Desktop, Videos, Music, Pictures, Downloads of the Wine user) are moved to ~/PremiereNux-user-files-<time>/ first.
# Windows files and system packages are left alone.
#
#   uninstall.sh [-y|--yes]
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"
YES=0
case "${1:-}" in -y|--yes) YES=1 ;; "") ;; *) echo "usage: uninstall.sh [-y|--yes]" >&2; exit 2 ;; esac

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'; else B=""; G=""; Y=""; N=""; fi
say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
ask_yn() {
    local a
    [ "$YES" = 1 ] && return 0
    read -r -p "$1 [y/N] " a < /dev/tty || die "no terminal for questions (use --yes)"
    case "$a" in [yYeE]*) return 0 ;; *) return 1 ;; esac
}

case "$PRNUX_HOME" in ""|/|"$HOME"|"$HOME/") die "refusing to remove '$PRNUX_HOME'" ;; esac
[ -d "$PRNUX_HOME" ] || [ -f "$PRNUX_CONFIG" ] || { say "nothing to remove: no $PRNUX_HOME"; exit 0; }
[ -d "$PRNUX_HOME/wineprefix" ] || [ -d "$PRNUX_HOME/runner" ] || [ -x "$PRNUX_HOME/scripts/launch_premiere.sh" ] \
    || die "$PRNUX_HOME does not look like a PremiereNux installation (no runner, wineprefix or scripts)"

APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
SYSCTL=/etc/sysctl.d/99-premierenux.conf
# the menu entry belongs to this installation when it starts a script from this install folder
MENU=""
grep -qF "Exec=$PRNUX_HOME/" "$APPS/premierenux.desktop" 2> /dev/null && MENU="$APPS/premierenux.desktop"
say "${B}PremiereNux $PRNUX_VERSION uninstall${N}"
say "  install folder   $PRNUX_HOME ($(du -sh "$PRNUX_HOME" 2> /dev/null | cut -f1))"
[ -n "$MENU" ] && say "  menu entry       $MENU"
[ -f "$PRNUX_CONFIG" ] && say "  settings         $PRNUX_CONFIG"
[ -f "$SYSCTL" ] && say "  kernel setting   $SYSCTL (needs sudo)"

# what the Wine user saved inside the prefix
KEEP=""
for u in "$WINEPREFIX"/drive_c/users/*; do
    [ -d "$u" ] || continue
    case "$(basename "$u")" in Public|"All Users") continue ;; esac
    for d in Documents Desktop Videos Music Pictures Downloads; do
        [ -d "$u/$d" ] && [ -n "$(find "$u/$d" -mindepth 1 -print -quit 2> /dev/null)" ] && KEEP="$KEEP $u/$d"
    done
done
[ -n "$KEEP" ] && say "  user files       moved to ~/PremiereNux-user-files-<time>/ first: $(for k in $KEEP; do printf '%s ' "$(basename "$k")"; done)"
say "  not touched      Windows files, system packages"
ask_yn "Remove all of this?" || { say "cancelled"; exit 1; }

"$WINE_BIN_DIR/wineserver" -k > /dev/null 2>&1 || true
if [ -n "$KEEP" ]; then
    SAVE="$HOME/PremiereNux-user-files-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$SAVE" || die "cannot create $SAVE"
    for k in $KEEP; do
        dest="$SAVE/$(basename "$(dirname "$k")")/$(basename "$k")"
        mkdir -p "$(dirname "$dest")"
        mv "$k" "$dest" || die "cannot move $k to $dest; nothing else was removed"
    done
    say "  ${G}ok${N}    user files are in $SAVE"
fi
rm -rf "$PRNUX_HOME"
rm -f "$PRNUX_CONFIG"
rmdir "$(dirname "$PRNUX_CONFIG")" 2> /dev/null || true
if [ -n "$MENU" ]; then
    rm -f "$MENU"
    command -v update-desktop-database > /dev/null 2>&1 && update-desktop-database "$APPS" > /dev/null 2>&1
fi
if [ -f "$SYSCTL" ]; then
    sudo rm -f "$SYSCTL" && say "  ${G}ok${N}    removed $SYSCTL (the running value stays until the next boot)"
fi
say "  ${G}ok${N}    PremiereNux is removed"
