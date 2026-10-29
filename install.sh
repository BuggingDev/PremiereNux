#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 PremiereNux contributors
# One-command installer: asks first (where the Windows files are), shows the plan, then installs without further input:
# system packages, Wine runner, GPU driver parts, Wine prefix, DXVK, vkd3d-proton, the JSON shim and
# Premiere Pro 2024 or 2026. Safe to run again: finished parts are skipped. Parts of the procedure (Wine runner, dzn, DXVK,
# vkd3d-proton, nvidia-libs, the package tables) are those of NuxFX's installer (Copyright (C) 2026 NuxFX contributors,
# GPL-3.0-or-later).
#
#   ./install.sh [options]
#     -y, --yes              take every default (needs Windows files it can find, or --windows / --premiere-dir)
#     --windows DIR          root of a Windows installation: a mounted Windows partition, or a folder that has its layout
#                            (Program Files/Adobe/..., Program Files (x86)/..., Windows/System32/...)
#     --premiere-dir DIR     the "Adobe Premiere Pro 2024" (or 2026) folder alone (has Adobe Premiere Pro.exe)
#     --home DIR             install folder (default ~/.local/share/premierenux)
#     --no-packages          do not install system packages
#     --cuda                 install the CUDA bridge (nvidia-libs) and let Premiere use it; off by default (see README)
#     --no-webview           do not copy the Microsoft Edge WebView2 runtime (the Home screen panels need it)
#     --no-dzn               do not install dzn and Mesa's OpenGL driver (default when /dev/dxg is missing)
#     --build-shim           build the JSON shim from winrt-json/ instead of using the shipped one (needs mingw-w64)
#     --force                redo parts that look finished
#     --dry-run              show the plan and change nothing
#     -h, --help             this text
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

YES=0; DRY=0; FORCE=0; PACKAGES=1; CUDA=0; WEBVIEW=1; DZN=auto; BUILD_SHIM=0
OPT_HOME=""; OPT_WIN=""; OPT_PP=""
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) YES=1 ;;
        --windows) OPT_WIN=${2:-}; shift ;;
        --premiere-dir) OPT_PP=${2:-}; shift ;;
        --home) OPT_HOME=${2:-}; shift ;;
        --no-packages) PACKAGES=0 ;;
        --cuda) CUDA=1 ;;
        --no-webview) WEBVIEW=0 ;;
        --no-dzn) DZN=0 ;;
        --build-shim) BUILD_SHIM=1 ;;
        --force) FORCE=1 ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '10,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$OPT_HOME" ] && export PRNUX_HOME="$OPT_HOME"
. "$HERE/scripts/common.sh"

# Pinned downloads: the releases everything was tested with, checked by SHA-256.
# Wine 11.17 or newer: Premiere Pro 2026 needs the gdiplus fix of 11.17 (11.12 replaces the family name of a private font by
# its full name, so "Adobe Clean" is not found: "Initialization Failure: ... FontFamilyNotFound Font: Adobe Clean")
WINE_VER=11.17
WINE_URL="https://github.com/Kron4ek/Wine-Builds/releases/download/$WINE_VER/wine-$WINE_VER-staging-tkg-amd64-wow64.tar.xz"
WINE_SHA=d5270a1e2737311c84f0820276523764d993fc04322729da768efc84c971e2d7
DXVK_URL="https://github.com/doitsujin/dxvk/releases/download/v3.0.1/dxvk-3.0.1.tar.gz"
DXVK_SHA=bebb6284db590535b7b005c102ebf6850c98842cff0fded9aacb74babae14c49
VKD3D_URL="https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v3.0.1/vkd3d-proton-3.0.1.tar.zst"
VKD3D_SHA=3cf2315522af5e43605ef6d3c41dad91387040bf97199934f3f7ab76caaa2f0c
NVLIBS_URL="https://github.com/SveSop/nvidia-libs/releases/download/v1.0.2/nvidia-libs-v1.0.2.tar.xz"
NVLIBS_SHA=01e8bb6368d088e22d8e8f1d02497214e8db436476021725ef0c0707b7cb1738
WT_URL="https://raw.githubusercontent.com/Winetricks/winetricks/20250102/src/winetricks"
WT_SHA=53194dead910f8a5eb1deacaa4773d4e48f5873633d18ab1ecd6fdb0cb92243b
# Mesa 25.2.8 with the dzn patches of NuxFX (Vulkan on Direct3D 12) and its OpenGL driver, built by NuxFX's release workflow
MESA_BASE="https://github.com/BuggingDev/NuxFX/releases/download/mesa-25.2.8-sc92933ff"
DZN_ASSET=nuxfx-mesa-dzn-25.2.8-sc92933ff732a-x86_64.tar.zst
DZN_SHA=31567cc2de0e440140fdac8dcda0f1743c3090df99321a31199abdeb9be1da62
GL_ASSET=nuxfx-mesa-gl-25.2.8-sc92933ff732a-x86_64.tar.zst
GL_SHA=3f77277a007cedbb9403a1980d745f2b413486ddf7c48003dfd3dedc85be6b32
# winrt-json/premierenux_json.dll as built from winrt-json/premierenux_json.c (build.sh prints the hash)
SHIM_SHA=9beafdb145d4ff27de9624cef9dccf98fddc8a164f451a9c88ae7114723c84af

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
say()   { printf '%s\n' "$*"; }
head1() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
good()  { printf '  %sok%s    %s\n' "$G" "$N" "$*"; }
note()  { printf '  %s!%s     %s\n' "$Y" "$N" "$*"; }
die()   { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have()  { command -v "$1" > /dev/null 2>&1; }

ask_yn() { # "question" default(y|n)
    local a
    if [ "$YES" = 1 ]; then [ "$2" = y ]; return; fi
    read -r -p "$1 [$( [ "$2" = y ] && echo Y/n || echo y/N )] " a < /dev/tty || die "no terminal for questions (use --yes)"
    case "${a:-$2}" in [yYeE]*) return 0 ;; *) return 1 ;; esac
}

pp_version_of() { sed -n 's/.*<Data key="ProductVersion">\([0-9][0-9.]*\).*/\1/p' "$1/AMT/application.xml" 2> /dev/null | head -n 1; }

# Windows partitions that are mounted here (also a dual-boot disk): they have a "Program Files" folder.
windows_drives() {
    local d
    for d in /mnt/* /media/*/* /run/media/*/*; do
        [ -d "$d/Program Files" ] && printf '%s\n' "$d"
    done
}

[ "$(id -u)" = 0 ] && die "do not run the installer as root: Wine would create a root-owned prefix (it asks for sudo where it needs it)"
[ "$(uname -m)" = x86_64 ] || die "x86_64 only"
if is_d3d12_host && [ "$DZN" = auto ]; then DZN=1; elif [ "$DZN" = auto ]; then DZN=0; fi
FAMILY=$(prnux_family)

T0=$(date +%s)
head1 "PremiereNux $PRNUX_VERSION: Adobe Premiere Pro on Linux (Wine, DXVK, vkd3d-proton)"
say "  Host:    $( . /etc/os-release 2> /dev/null; echo "${PRETTY_NAME:-Linux}" ) (packages: $FAMILY)"
say "  GPU:     $([ "$DZN" = 1 ] && echo "reached through Direct3D 12 (/dev/dxg): Vulkan through dzn, OpenGL through Mesa's D3D12 driver" || echo "the host's own Vulkan driver")"
say "  Install: $PRNUX_HOME"

# ---------- questions ----------

head1 "1. Windows files"
say "  Premiere Pro (2024 or 2026) and a few Adobe and Microsoft components are taken from a Windows installation (not downloaded)."
WIN=${OPT_WIN%/}
PP_SRC=""
if [ -n "$OPT_PP" ]; then
    PP_SRC=${OPT_PP%/}
    if [ -z "$WIN" ]; then case "$PP_SRC" in */Program\ Files/Adobe/*) WIN=${PP_SRC%/Program Files/Adobe/*} ;; esac; fi
elif [ -f "$PP_DIR/Adobe Premiere Pro.exe" ] && [ "$FORCE" = 0 ] && [ -z "$WIN" ]; then
    PP_SRC=$PP_DIR
    good "Premiere Pro is already in $PP_DIR (kept; use --force to copy it again)"
else
    if [ -n "$WIN" ]; then DRIVES=("$WIN"); else mapfile -t DRIVES < <(windows_drives); fi
    CANDS=()
    for drive in "${DRIVES[@]}"; do
        for d in "$drive/Program Files/Adobe"/Adobe\ Premiere\ Pro\ 20*; do
            [ -f "$d/Adobe Premiere Pro.exe" ] && CANDS+=("$d")
        done
    done
    if [ ${#CANDS[@]} -gt 0 ]; then
        say "  Found:"
        i=1; DEF=1
        for d in "${CANDS[@]}"; do
            say "    $i) $d  (version $(pp_version_of "$d"))"
            case "$d" in *"Pro 2024") DEF=$i ;; esac
            i=$((i + 1))
        done
        if [ "$YES" = 1 ] || [ ${#CANDS[@]} -eq 1 ]; then sel=$DEF; else read -r -p "  Choose [$DEF] " sel < /dev/tty || die "no terminal (use --windows or --premiere-dir)"; fi
        sel=${sel:-$DEF}
        PP_SRC=${CANDS[$((sel - 1))]:-}
    else
        say "  No Premiere Pro found. Mount the Windows partition, or copy the folders listed in the README into one"
        say "  directory (keeping the Windows folder names) and give it with --windows DIR."
        [ "$YES" = 1 ] && die "pass --windows DIR or --premiere-dir DIR"
        read -r -p "  Windows root folder: " a < /dev/tty || die "no terminal"
        WIN=${a%/}
        PP_SRC=$(ls -d "$WIN/Program Files/Adobe"/Adobe\ Premiere\ Pro\ 20*/ 2> /dev/null | sort | tail -n 1)
        PP_SRC=${PP_SRC%/}
    fi
    if [ -z "$WIN" ] && [ -n "$PP_SRC" ]; then case "$PP_SRC" in */Program\ Files/Adobe/*) WIN=${PP_SRC%/Program Files/Adobe/*} ;; esac; fi
fi
[ -f "$PP_SRC/Adobe Premiere Pro.exe" ] || die "Adobe Premiere Pro.exe not found in: ${PP_SRC:-(none)}"
PP_V=$(pp_version_of "$PP_SRC")
good "Premiere Pro folder: $PP_SRC (version ${PP_V:-unknown})"
case "$PP_V" in 24.4.*|26.0*) ;; *) note "only 24.4.1 and 26.0 were tested; other versions may not start" ;; esac
# The folder keeps its name in the prefix: Premiere's AMT data holds the path (C:\Program Files\Adobe\Adobe Premiere Pro 2026\AMT\...).
PP_NAME=$(basename "$PP_SRC")
case "$PP_NAME" in "Adobe Premiere Pro"*) PP_DIR="$(dirname "$PP_DIR")/$PP_NAME" ;; *) PP_NAME="Adobe Premiere Pro 2024" ;; esac

# where the other components come from (a Windows root), and where they go (inside the prefix)
PFX="$WINEPREFIX/drive_c"
ADC64_SRC="$WIN/Program Files/Common Files/Adobe/Adobe Desktop Common";  ADC64_DST="$PFX/Program Files/Common Files/Adobe/Adobe Desktop Common"
ADC32_SRC="$WIN/Program Files (x86)/Common Files/Adobe/Adobe Desktop Common"; ADC32_DST="$PFX/Program Files (x86)/Common Files/Adobe/Adobe Desktop Common"
WV_DST="$PFX/Program Files/Common Files/Adobe/Microsoft/EdgeWebView"
WV_SRC=""
[ -n "$WIN" ] && WV_SRC=$(ls -d "$WIN/Program Files (x86)/Microsoft/EdgeWebView/Application"/[0-9]*/ 2> /dev/null | sort -V | tail -n 1)
WV_SRC=${WV_SRC%/}
MSXML_SRC="$WIN/Windows"
comp_state() { # DESCRIPTION SRC_EXISTS(0|1) DST_EXISTS(0|1)
    if [ "$2" = 1 ]; then good "$1"
    elif [ "$3" = 1 ]; then good "$1 (already in the prefix)"
    else note "$1: not found; Premiere may fail or show empty windows"; fi
}
head1 "2. Components taken from Windows"
[ -n "$WIN" ] && say "  Windows root: $WIN"
c() { [ -d "$1" ] && echo 1 || echo 0; }
f() { [ -f "$1" ] && echo 1 || echo 0; }
comp_state "Adobe Desktop Common (NGL components)" "$(c "$ADC64_SRC")" "$(c "$ADC64_DST/NGL")"
comp_state "Adobe Desktop Common x86 (inter-app messaging, IPC broker)" "$(c "$ADC32_SRC")" "$(c "$ADC32_DST/IPCBox")"
if [ "$WEBVIEW" = 1 ]; then comp_state "Microsoft Edge WebView2 runtime ${WV_SRC:+$(basename "$WV_SRC")} (Home screen panels)" "$([ -n "$WV_SRC" ] && f "$WV_SRC/msedgewebview2.exe" || echo 0)" "$(f "$WV_DST/msedgewebview2.exe")"; fi
comp_state "msxml3.dll and msxml3r.dll (Premiere's start needs the native ones)" "$([ "$(f "$MSXML_SRC/System32/msxml3.dll")$(f "$MSXML_SRC/System32/msxml3r.dll")" = 11 ] && echo 1 || echo 0)" "$(f "$PFX/windows/system32/msxml3r.dll")"
[ "$WEBVIEW" = 1 ] || WV_SRC=""
# The Object Mask tool (AI) of Premiere Pro 25 and newer loads its models from a folder of the Windows installation,
# "Common Files/Adobe/Premiere Pro/<major.minor>/<module id>/ObjectMask" (380 MB); without it the tool does nothing.
PP_MAJOR=$(printf '%s' "$PP_V" | cut -d. -f1)
case "$PP_MAJOR" in ''|*[!0-9]*) PP_MAJOR=0 ;; esac
ML_REL="Program Files/Common Files/Adobe/Premiere Pro/$(printf '%s' "$PP_V" | cut -d. -f1,2)"
ML_DST="$PFX/$ML_REL"
ML_SRC=""; ML_ID=""
if [ "$PP_MAJOR" -ge 25 ] && [ -n "$WIN" ]; then
    ML_SRC=$(ls -d "$WIN/$ML_REL"/*/ObjectMask 2> /dev/null | head -n 1)
    [ -n "$ML_SRC" ] && ML_ID=$(basename "$(dirname "$ML_SRC")")
fi
if [ "$PP_MAJOR" -ge 25 ]; then
    if [ -n "$ML_SRC" ]; then good "Object Mask models (the AI tool)"
    elif compgen -G "$ML_DST/*/ObjectMask" > /dev/null; then good "Object Mask models (already in the prefix)"
    else note "Object Mask models: \"$ML_REL/<id>/ObjectMask\" not found in the Windows files; the tool will do nothing"; fi
fi

# ---------- GPU facts ----------

# libcuda comes with the GPU driver: in the linker cache, or (Direct3D 12 route) in a folder of its own under /usr/lib
HAVE_CUDA=0
for l in $(ldconfig -p 2> /dev/null | sed -n 's/.*libcuda\.so\.1 .*=> //p') $(find /usr/lib /usr/lib64 -maxdepth 3 -name libcuda.so.1 2> /dev/null); do
    [ -e "$l" ] && HAVE_CUDA=1 && break
done
[ "$CUDA" = 1 ] && [ "$HAVE_CUDA" = 0 ] && { CUDA=0; note "no libcuda found: the CUDA bridge is skipped"; }

# A Wine program with a large working set needs many memory mappings; some distributions still ship the kernel default.
MAPS=$(cat /proc/sys/vm/max_map_count 2> /dev/null || echo 0)
RAISE_MAPS=0
if [ "$PACKAGES" = 1 ] && [ "$MAPS" -lt 1048576 ] 2> /dev/null; then RAISE_MAPS=1; fi

# ---------- plan ----------

head1 "Plan"
say "  Install folder    $PRNUX_HOME"
say "  Premiere Pro      $PP_SRC  ($(du -sh "$PP_SRC" 2> /dev/null | cut -f1))"
say "  System packages   $([ "$PACKAGES" = 1 ] && echo "Wine libraries, fonts (sudo)" || echo skipped)"
say "  Memory mappings   vm.max_map_count $MAPS$([ "$RAISE_MAPS" = 1 ] && echo ", raised to 1048576 (sudo, /etc/sysctl.d/99-premierenux.conf)" || echo ", left alone")"
say "  Wine runner       $WINE_VER (Wine TkG staging, checked by SHA-256)"
say "  dzn + OpenGL      $([ "$DZN" = 1 ] && echo "Mesa 25.2.8 prebuilt packages of NuxFX" || echo skipped)"
say "  DXVK / vkd3d      3.0.1 / 3.0.1"
say "  CUDA bridge       $([ "$CUDA" = 1 ] && echo "nvidia-libs 1.0.2" || echo "off (Premiere renders in software; --cuda to try the GPU renderer)")"
say "  WinRT JSON shim   winrt-json/ (Premiere needs IMap<HSTRING, IJsonValue> on JsonObject)"
[ "$PP_MAJOR" -ge 25 ] && say "  Object Mask       $([ -n "$ML_SRC" ] && echo "models from $ML_SRC ($(du -sh "$ML_SRC" 2> /dev/null | cut -f1))" || echo "models not found in the Windows files")"
[ "$DRY" = 1 ] && { say; say "dry run: nothing changed"; exit 0; }
# the wineserver of a running Premiere would keep "waiting for the wineserver" below from ever finishing
if [ -n "$(prnux_prefix_pids 'Adobe Premiere Pro[.]exe' | head -n 1)" ]; then
    die "Premiere Pro runs from this prefix: close it (or run $WINE_BIN_DIR/wineserver -k) and start the installer again"
fi
ask_yn "Start the installation?" y || { say "cancelled"; exit 1; }

# ---------- install ----------

mkdir -p "$PRNUX_HOME/downloads" "$PRNUX_LOG_DIR"
LOG="$PRNUX_LOG_DIR/install_$(date +%Y%m%d_%H%M%S).log"
say "  log: $LOG"
STEP=0; TOTAL=15
step() { STEP=$((STEP + 1)); head1 "[$STEP/$TOTAL] $*"; }

# run DESCRIPTION CMD...: output goes to the log; on failure the tail is shown (stdin is closed, the log is capped)
run() {
    local desc=$1; shift
    printf '  %s ... ' "$desc"
    echo "### $desc: $*" >> "$LOG"
    "$@" < /dev/null 2>&1 | head -c 200000000 >> "$LOG"
    if [ "${PIPESTATUS[0]}" = 0 ]; then printf '%sdone%s\n' "$G" "$N"; else
        printf '%sFAILED%s\n' "$R" "$N"; tail -n 25 "$LOG" >&2
        die "step failed: $desc (full log: $LOG)"
    fi
}
# soft DESCRIPTION CMD...: a failure is only a note
soft() {
    local desc=$1; shift
    printf '  %s ... ' "$desc"
    echo "### $desc: $*" >> "$LOG"
    if "$@" < /dev/null >> "$LOG" 2>&1; then printf '%sdone%s\n' "$G" "$N"; else printf '%sfailed%s (the installation goes on)\n' "$Y" "$N"; fi
}

fetch() { # URL FILE SHA256
    local url=$1 file=$2 sha=$3
    if [ -f "$file" ] && [ "$(sha256sum "$file" | cut -c1-64)" = "$sha" ]; then good "$(basename "$file") already downloaded"; return 0; fi
    printf '  downloading %s\n' "$(basename "$file")"
    curl -fL --retry 3 --connect-timeout 20 -C - -sS -o "$file" "$url" || true
    if [ ! -f "$file" ]; then
        case "$url" in */releases/download/mesa-*) note "these Mesa packages are only needed when the GPU is reached through Direct3D 12; a host with its own GPU driver can skip them (--no-dzn)" ;; esac
        die "download failed: $url"
    fi
    [ "$(sha256sum "$file" | cut -c1-64)" = "$sha" ] || { rm -f "$file"; die "SHA-256 mismatch for $(basename "$file"); removed it"; }
    good "$(basename "$file") verified"
}

DL="$PRNUX_HOME/downloads"
# the wineserver writes the registry files when it exits; the vkd3d-proton installer looks for system.reg
settle() { run "waiting for the wineserver" "$WINE_BIN_DIR/wineserver" -w; }
# copy_tree SRC DEST: rsync without modes (files from a Windows drive arrive read-only), then make them writable
copy_tree() { mkdir -p "$2" && rsync -rlt --exclude Installer "$1/" "$2/" && chmod -R u+rwX,go+rX "$2"; }
# the package managers ask "Proceed?" and the installer closes stdin: the commands get their non-interactive flags here
noninteractive() {
    sed -e 's/^sudo apt install/sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y/' \
        -e 's/^sudo dnf install/sudo dnf install -y/' \
        -e 's/^sudo pacman -S --needed/sudo pacman -S --needed --noconfirm/' \
        -e 's/^sudo zypper install/sudo zypper --non-interactive install/'
}

step "System packages"
if [ "$PACKAGES" = 1 ]; then
    BASE=(git curl tar gzip xz zstd cabextract pkg-config awk procps which rsync vulkan-loader fontconfig pactl)
    WINE_LIBS=$(prnux_libs_missing "$PRNUX_WINE_SONAMES" | tr '\n' ' ')
    MESA_LIBS=""
    [ "$DZN" = 1 ] && MESA_LIBS=$(prnux_libs_missing "$PRNUX_MESA_SONAMES" | tr '\n' ' ')
    MISSING_ANY=0
    for t in git curl tar gzip xz zstd cabextract awk pgrep which rsync fc-list pactl; do have "$t" || MISSING_ANY=1; done
    prnux_have_lib libvulkan.so.1 || MISSING_ANY=1
    [ -n "$WINE_LIBS$MESA_LIBS" ] && MISSING_ANY=1
    # shellcheck disable=SC2206
    BASE+=($WINE_LIBS $MESA_LIBS)
    CMD=$(prnux_pkg_hint "${BASE[@]}")
    if [ "$FAMILY" = other ]; then
        note "this distribution is not known to the installer; install what is missing yourself: ${BASE[*]}"
    elif [ "$MISSING_ANY" = 1 ]; then
        say "  needs: $CMD"
        if ask_yn "  Run this with sudo?" y; then
            [ "$FAMILY" = apt ] && soft "updating the package lists" sudo apt-get update
            run "installing packages" env DEBIAN_FRONTEND=noninteractive bash -c "$(printf '%s\n' "$CMD" | noninteractive)"
        else
            note "skipped; the steps below may fail"
        fi
    else
        good "everything needed is installed"
    fi
    STILL=$(prnux_libs_missing "$PRNUX_WINE_SONAMES" | tr '\n' ' ')
    [ -z "$STILL" ] || note "still missing: $STILL (Wine switches the matching feature off)"
    # Adobe's text engine throws "invalid map<K, T> key" when Wine sees no system fonts
    if [ "$(fc-list 2> /dev/null | wc -l)" -gt 100 ]; then
        good "fonts: $(fc-list : family 2> /dev/null | sort -u | wc -l) families"
    elif [ "$FAMILY" != other ]; then
        FCMD=$(prnux_pkg_hint $(prnux_font_pkgs))
        say "  fonts: $FCMD"
        if ask_yn "  Run this with sudo?" y; then
            soft "installing fonts" env DEBIAN_FRONTEND=noninteractive bash -c "$(printf '%s\n' "$FCMD" | noninteractive)"
            fc-cache -f > /dev/null 2>&1
        fi
        [ "$(fc-list 2> /dev/null | wc -l)" -gt 100 ] || note "Wine sees few fonts: Premiere stops with 'Initialization Failure' unless a broad set (Noto, DejaVu, Liberation) is installed"
    fi
else
    note "skipped (--no-packages)"
fi
if [ "$RAISE_MAPS" = 1 ]; then
    soft "raising vm.max_map_count" sudo sh -c "mkdir -p /etc/sysctl.d && echo 'vm.max_map_count=1048576' > /etc/sysctl.d/99-premierenux.conf && sysctl -w vm.max_map_count=1048576"
fi

step "Wine runner"
RUNNER_V=""
[ -x "$WINE_BIN_DIR/wine" ] && RUNNER_V=$("$WINE_BIN_DIR/wine" --version 2> /dev/null)
case "$RUNNER_V" in "wine-$WINE_VER."*|"wine-$WINE_VER "*) RUNNER_OK=1 ;; *) RUNNER_OK=0 ;; esac
if [ "$RUNNER_OK" = 1 ] && [ "$FORCE" = 0 ]; then
    good "found: $RUNNER_V"
else
    if [ -n "$RUNNER_V" ]; then
        [ "$WINE_BIN_DIR" = "$PRNUX_HOME/runner/bin" ] || die "the runner in $WINE_BIN_DIR is $RUNNER_V; $WINE_VER is needed"
        note "replacing the runner ($RUNNER_V) by $WINE_VER"
        rm -rf "$PRNUX_HOME/runner"
    fi
    fetch "$WINE_URL" "$DL/wine-$WINE_VER.tar.xz" "$WINE_SHA"
    mkdir -p "$PRNUX_HOME/runner"
    run "unpacking the runner" tar -xJf "$DL/wine-$WINE_VER.tar.xz" -C "$PRNUX_HOME/runner" --strip-components=1
    [ -x "$WINE_BIN_DIR/wine" ] || die "the runner has no bin/wine in $WINE_BIN_DIR"
fi
[ -e "$WINE_BIN_DIR/wine64" ] || ln -s wine "$WINE_BIN_DIR/wine64"

# install_mesa dzn|gl: unpacks a prebuilt Mesa package after checking what it holds, and that its libraries load here
install_mesa() {
    local comp=$1 asset sha prefix check file stage parent bad l
    if [ "$comp" = dzn ]; then asset=$DZN_ASSET; sha=$DZN_SHA; prefix=$DZN_PREFIX; check="lib/libvulkan_dzn.so"
    else asset=$GL_ASSET; sha=$GL_SHA; prefix=$PRNUX_GL_PREFIX; check="lib/libEGL.so.1"; fi
    fetch "$MESA_BASE/$asset" "$DL/$asset" "$sha"
    file="$DL/$asset"
    tar --zstd -tf "$file" | grep -qE '^/|(^|/)\.\.(/|$)' && die "$asset holds unsafe file names"
    tar --zstd -tvf "$file" | cut -c1 | grep -qv '[-dl]' && die "$asset holds special files"
    parent=$(dirname "$prefix"); mkdir -p "$parent"
    stage=$(mktemp -d "$parent/.premierenux-unpack.XXXXXX") || die "cannot write in $parent"
    tar --zstd -xf "$file" -C "$stage" || { rm -rf "$stage"; die "cannot unpack $asset"; }
    chmod 755 "$stage"
    for l in $check; do
        [ -f "$stage/$l" ] || { rm -rf "$stage"; die "$asset has no $l"; }
        bad=$(LD_LIBRARY_PATH="$stage/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd -r "$stage/$l" 2>&1 | grep -E 'not found|undefined symbol' | head -n 4 | tr '\n' ';')
        [ -z "$bad" ] || { rm -rf "$stage"; die "$l does not load on this system: $bad"; }
    done
    rm -rf "$prefix"
    mv "$stage" "$prefix"
    printf '%s\n' "$sha" > "$prefix/.asset-sha256"
    [ "$comp" = dzn ] && prnux_write_dzn_icd
    return 0
}
# a package of another build than the pinned one (an older release) is replaced
mesa_current() { # PREFIX SHA
    [ "$(cat "$1/.asset-sha256" 2> /dev/null)" = "$2" ]
}

step "Vulkan driver (dzn)"
if [ "$DZN" = 1 ]; then
    if [ -f "$(prnux_dzn_icd)" ] && [ -f "$DZN_PREFIX/lib/libvulkan_dzn.so" ] && mesa_current "$DZN_PREFIX" "$DZN_SHA" && [ "$FORCE" = 0 ]; then
        good "found: $(prnux_dzn_icd)"
    else
        [ -f "$DZN_PREFIX/lib/libvulkan_dzn.so" ] && note "the installed dzn is not the pinned build; replacing it"
        install_mesa dzn; good "installed: $(prnux_dzn_icd)"
    fi
else
    good "not needed: the host's own Vulkan driver is used"
fi
step "OpenGL driver (Mesa EGL and d3d12)"
if [ "$DZN" = 1 ]; then
    if [ -f "$PRNUX_GL_PREFIX/lib/libEGL.so.1" ] && mesa_current "$PRNUX_GL_PREFIX" "$GL_SHA" && [ "$FORCE" = 0 ]; then
        good "found: $PRNUX_GL_PREFIX"
    else
        [ -f "$PRNUX_GL_PREFIX/lib/libEGL.so.1" ] && note "the installed OpenGL driver is not the pinned build; replacing it"
        install_mesa gl; good "installed: $PRNUX_GL_PREFIX"
    fi
else
    good "not needed: the host's own OpenGL driver is used"
fi

# keep the locations for the other scripts
mkdir -p "$(dirname "$PRNUX_CONFIG")"; touch "$PRNUX_CONFIG"
for kv in "PRNUX_HOME=$PRNUX_HOME" "WINE_BIN_DIR=$WINE_BIN_DIR" "WINEPREFIX=$WINEPREFIX" "PP_DIR=$PP_DIR" "DZN_PREFIX=$DZN_PREFIX" "PRNUX_GL_PREFIX=$PRNUX_GL_PREFIX"; do
    sed -i "/^${kv%%=*}=/d" "$PRNUX_CONFIG"
    printf '%s\n' "$kv" >> "$PRNUX_CONFIG"
done
# With the CUDA bridge visible Premiere picks its GPU renderer, and the Program monitor stays blank (white or black)
sed -i '/^PRNUX_DISABLE_CUDA=/d' "$PRNUX_CONFIG"
[ "$CUDA" = 1 ] || echo "PRNUX_DISABLE_CUDA=1" >> "$PRNUX_CONFIG"

prnux_env
SYS32="$PFX/windows/system32"
SYS64="$PFX/windows/syswow64"

prefix_complete() {
    [ -f "$WINEPREFIX/system.reg" ] && [ -f "$SYS32/kernel32.dll" ] && [ -f "$SYS64/kernel32.dll" ]
}

step "Wine prefix"
if prefix_complete && [ "$FORCE" = 0 ]; then
    good "found: $WINEPREFIX"
else
    if [ -n "$(ls -A "$WINEPREFIX" 2> /dev/null)" ] && ! prefix_complete; then
        mv "$WINEPREFIX" "$WINEPREFIX.unfinished-$(date +%Y%m%d_%H%M%S)" && note "the prefix was incomplete (an interrupted install?); it is kept aside"
    fi
    mkdir -p "$WINEPREFIX"
    run "creating the prefix" wineboot -i
    run "setting Windows 10" wine reg add 'HKCU\Software\Wine' /v Version /d win10 /f
    settle
fi

step "Visual C++ runtime, d3dcompiler, core fonts"
if grep -qx vcrun2022 "$WINEPREFIX/winetricks.log" 2> /dev/null && grep -qx d3dcompiler_47 "$WINEPREFIX/winetricks.log" 2> /dev/null && [ "$FORCE" = 0 ]; then
    good "found"
else
    fetch "$WT_URL" "$DL/winetricks-20250102" "$WT_SHA"
    mkdir -p "$PRNUX_HOME/bin"
    install -m 755 "$DL/winetricks-20250102" "$PRNUX_HOME/bin/winetricks"
    run "winetricks vcrun2022 d3dcompiler_47 (slow)" "$PRNUX_HOME/bin/winetricks" -q vcrun2022 d3dcompiler_47
    # the forum guide asks for corefonts too; the Arial/Times substitutes of the Liberation fonts cover the lookups,
    # so a download problem is not fatal
    soft "winetricks corefonts" "$PRNUX_HOME/bin/winetricks" -q corefonts
    settle
fi

step "DXVK and vkd3d-proton"
if [ -f "$SYS32/dxgi.dll" ] && ! grep -aq "Wine builtin DLL" "$SYS32/dxgi.dll" && [ -f "$SYS32/d3d12.dll" ] && ! grep -aq "Wine builtin DLL" "$SYS32/d3d12.dll" && [ "$FORCE" = 0 ]; then
    good "found"
else
    fetch "$DXVK_URL" "$DL/dxvk-3.0.1.tar.gz" "$DXVK_SHA"
    fetch "$VKD3D_URL" "$DL/vkd3d-proton-3.0.1.tar.zst" "$VKD3D_SHA"
    run "unpacking DXVK" tar -xzf "$DL/dxvk-3.0.1.tar.gz" -C "$DL"
    for dll in d3d9 d3d10core d3d11 dxgi; do
        cp "$DL/dxvk-3.0.1/x64/$dll.dll" "$SYS32/"
        cp "$DL/dxvk-3.0.1/x32/$dll.dll" "$SYS64/"
        run "override $dll" wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$dll" /d "native,builtin" /f
    done
    rm -rf "$DL/vkd3d-proton-3.0.1"
    run "unpacking vkd3d-proton" tar --zstd -xf "$DL/vkd3d-proton-3.0.1.tar.zst" -C "$DL"
    settle
    run "installing vkd3d-proton" bash -c "cd '$DL/vkd3d-proton-3.0.1' && ./setup_vkd3d_proton.sh install"
    settle
fi

step "CUDA bridge"
if [ "$CUDA" = 1 ]; then
    if [ -f "$SYS32/nvcuda.dll" ] && [ "$FORCE" = 0 ]; then
        good "found"
    else
        fetch "$NVLIBS_URL" "$DL/nvidia-libs-v1.0.2.tar.xz" "$NVLIBS_SHA"
        mkdir -p "$WINEPREFIX/nvidia-libs"
        run "unpacking nvidia-libs" tar -xJf "$DL/nvidia-libs-v1.0.2.tar.xz" -C "$WINEPREFIX/nvidia-libs"
        run "installing nvidia-libs" "$WINEPREFIX/nvidia-libs/nvidia-libs-v1.0.2/setup_nvlibs.sh" install
        settle
    fi
else
    good "skipped"
fi

step "Windows components Premiere needs"
# a component comes from the Windows root when it is there; otherwise the copy already in the prefix stays
comp_copy() { # DESCRIPTION SRC DST
    if [ -d "$2" ]; then run "$1 ($(du -sh "$2" 2> /dev/null | cut -f1))" copy_tree "$2" "$3"
    elif [ -d "$3" ]; then good "$1: kept (already in the prefix)"
    else note "$1: not found"; fi
}
# Premiere's start needs the native msxml3 pair of Windows: the Win7 build of winetricks is unloaded again by Wine and
# has no resource DLL (msxml3r.dll)
if [ -f "$MSXML_SRC/System32/msxml3.dll" ] && [ -f "$MSXML_SRC/System32/msxml3r.dll" ]; then
    cp -f "$MSXML_SRC/System32/msxml3.dll" "$MSXML_SRC/System32/msxml3r.dll" "$SYS32/"
    [ -f "$MSXML_SRC/SysWOW64/msxml3.dll" ] && cp -f "$MSXML_SRC/SysWOW64/msxml3.dll" "$MSXML_SRC/SysWOW64/msxml3r.dll" "$SYS64/"
fi
if [ -f "$SYS32/msxml3r.dll" ]; then run "msxml3 override (native, builtin)" wine reg add 'HKCU\Software\Wine\DllOverrides' /v msxml3 /d "native,builtin" /f; fi
# Adobe's fonts: Creative Cloud installs them system-wide on Windows
FONTS="$PFX/windows/Fonts"
mkdir -p "$FONTS"
NF=0
for f in "$WIN"/Windows/Fonts/Adobe*.otf "$WIN"/Windows/Fonts/Minion*.otf "$WIN"/Windows/Fonts/Myriad*.otf \
         "$WIN"/Windows/Fonts/SourceCodePro*.ttf "$WIN"/Windows/Fonts/SourceSansPro*.ttf "$PP_SRC"/pdfl/Fonts/*.otf; do
    [ -f "$f" ] && { cp -f "$f" "$FONTS/"; NF=$((NF + 1)); }
done
good "$NF Adobe font files copied into the prefix"
comp_copy "Adobe Desktop Common (NGL)" "$ADC64_SRC" "$ADC64_DST"
comp_copy "Adobe Desktop Common x86 (IPC broker)" "$ADC32_SRC" "$ADC32_DST"
if [ "$WEBVIEW" = 1 ]; then comp_copy "Edge WebView2 runtime" "$WV_SRC" "$WV_DST"; fi

step "Object Mask models"
if [ "$PP_MAJOR" -lt 25 ]; then
    good "not needed: Object Mask came with Premiere Pro 25"
elif [ -n "$ML_SRC" ] && ! { [ -d "$ML_DST/$ML_ID/ObjectMask" ] && [ "$FORCE" = 0 ]; }; then
    run "copying $(du -sh "$ML_SRC" 2> /dev/null | cut -f1) to the prefix" copy_tree "$ML_SRC" "$ML_DST/$ML_ID/ObjectMask"
elif compgen -G "$ML_DST/*/ObjectMask" > /dev/null; then
    good "found: $ML_DST"
else
    note "Object Mask needs the folder \"$ML_REL/<id>/ObjectMask\" of your Windows files and it was not found"
    say "         run again with --windows DIR (DIR holds \"Program Files\"), or copy that folder to $ML_DST/<id>/"
fi

step "WinRT JsonObject shim"
SHIM_FILE="$HERE/winrt-json/premierenux_json.dll"
if [ "$BUILD_SHIM" = 0 ] && [ "$(sha256sum "$SHIM_FILE" 2> /dev/null | cut -c1-64)" = "$SHIM_SHA" ]; then
    cp -f "$SHIM_FILE" "$SYS32/premierenux_json.dll"
    good "premierenux_json.dll (checked by SHA-256)"
else
    have x86_64-w64-mingw32-gcc || die "building the shim needs the MinGW-w64 cross compiler ($(prnux_pkg_hint mingw-w64))"
    run "building premierenux_json.dll" bash "$HERE/winrt-json/build.sh" "$SYS32/premierenux_json.dll"
fi
run "registering Windows.Data.Json.JsonObject" wine reg add 'HKLM\Software\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Data.Json.JsonObject' /v DllPath /t REG_SZ /d 'C:\windows\system32\premierenux_json.dll' /f
settle

step "Premiere Pro files"
if [ "$PP_SRC" = "$PP_DIR" ] || { [ -f "$PP_DIR/Adobe Premiere Pro.exe" ] && [ "$FORCE" = 0 ]; }; then
    good "already in $PP_DIR"
else
    run "copying $(du -sh "$PP_SRC" 2> /dev/null | cut -f1) to $PP_DIR" copy_tree "$PP_SRC" "$PP_DIR"
fi
# Premiere loads icuin.dll / icuuc.dll; the Windows install only has the versioned names (the forum guide: duplicate, do not rename)
for base in icuin icuuc; do
    src=$(ls "$PP_DIR"/${base}[0-9]*.dll 2> /dev/null | head -n 1)
    [ -n "$src" ] && [ ! -f "$PP_DIR/$base.dll" ] && cp "$src" "$PP_DIR/$base.dll" && good "$(basename "$src") also as $base.dll"
done
chmod -R u+rwX,go+rX "$PP_DIR" 2> /dev/null || true

step "Scripts and menu entry"
mkdir -p "$PRNUX_HOME/scripts"
cp "$HERE"/scripts/*.sh "$PRNUX_HOME/scripts/"
chmod 755 "$PRNUX_HOME"/scripts/*.sh
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$APPS"
cat > "$APPS/premierenux.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$PP_NAME
Comment=Adobe Premiere Pro under Wine (PremiereNux)
Exec=$PRNUX_HOME/scripts/launch_premiere.sh
Icon=video-x-generic
Terminal=false
Categories=AudioVideo;Video;AudioVideoEditing;
StartupWMClass=adobe premiere pro.exe
EOF
good "menu entry: $APPS/premierenux.desktop"

step "Audio"
# Without a sound output Wine reports no device and Premiere stops at a modal box "No output device is available".
# The launcher looks for a server that answers each time it starts (PRNUX_AUDIO_CHECK=0 skips that).
AUDIO=$( prnux_audio_setup; echo "$PRNUX_AUDIO|$PRNUX_AUDIO_INFO" )
case "${AUDIO%%|*}" in
    ok) good "sound server answers: ${AUDIO#*|}" ;;
    none) note "no sound server answers. Start PulseAudio, or PipeWire with its pulse server (pipewire-pulse), before you start Premiere; without one it stops at 'No output device is available'" ;;
    *) note "pactl is not installed, so the sound server was not checked ($(prnux_pkg_hint pactl))" ;;
esac
STILL=$(prnux_libs_missing "libpulse.so.0 libasound.so.2" | tr '\n' ' ')
[ -z "$STILL" ] || note "missing audio libraries: $STILL"

step "Check"
FAIL=0
chk() { if "$@" > /dev/null 2>&1; then good "$CHK_DESC"; else note "$CHK_DESC: FAILED"; FAIL=1; fi; }
CHK_DESC="Wine runner starts"; chk "$WINE_BIN_DIR/wine" --version
[ "$DZN" = 1 ] && { CHK_DESC="dzn driver file"; chk test -f "$DZN_PREFIX/lib/libvulkan_dzn.so"; }
CHK_DESC="Adobe Premiere Pro.exe in the prefix"; chk test -f "$PP_DIR/Adobe Premiere Pro.exe"
CHK_DESC="JSON shim in the prefix"; chk test -f "$SYS32/premierenux_json.dll"
CHK_DESC="Adobe Desktop Common in the prefix"; chk test -d "$ADC64_DST/NGL"
[ "$PP_MAJOR" -ge 25 ] && { CHK_DESC="Object Mask models in the prefix"; chk bash -c 'compgen -G "$1" > /dev/null' _ "$ML_DST/*/ObjectMask"; }
CHK_DESC="fonts visible to Wine (fc-list)"; chk sh -c '[ "$(fc-list | wc -l)" -gt 100 ]'

ELAPSED=$(( $(date +%s) - T0 ))
if [ "$ELAPSED" -lt 90 ]; then head1 "Done in $ELAPSED s"; else head1 "Done in $(( (ELAPSED + 30) / 60 )) min"; fi
say "  Start:      $PRNUX_HOME/scripts/launch_premiere.sh   (or the \"$PP_NAME\" menu entry)"
say "  Problems:   $PRNUX_HOME/scripts/doctor.sh   (prints what a bug report needs)"
say "  Remove:     $PRNUX_HOME/scripts/uninstall.sh"
say "  Log:        $LOG"
[ "$FAIL" = 0 ] || exit 1
