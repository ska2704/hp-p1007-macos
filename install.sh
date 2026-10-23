#!/bin/bash
# Install a working driver for the HP LaserJet P1005 / P1006 / P1007 / P1008 on
# modern macOS (Apple Silicon or Intel), without Rosetta and without disabling SIP.
#
# Run as your normal user:  ./install.sh
# It builds everything in ./build and asks for your password (sudo) only to copy
# the driver into /Library/Printers and to create the print queue.
#
# Copyright (C) 2026 hp-p1007-macos contributors
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

FOO2ZJS_REPO=https://github.com/OpenPrinting/foo2zjs
FOO2ZJS_COMMIT=80499ed5bf6caa2963ad337e37cfda78a80aab1e
# Apple's signed "HP Printer Drivers 5.1.1" package (contains the printer firmware).
APPLE_HP_DMG_URL=https://updates.cdn-apple.com/2020/macos/001-41745-20201210-DBC9B46B-88B2-4032-87D9-449AF1D20804/HewlettPackardPrinterDrivers.dmg
DEST=/Library/Printers/hp-p1007-macos

ROOT=$(cd "$(dirname "$0")" && pwd)
BUILD="$ROOT/build"

MODEL=""; QUEUE=""; PAPER=A4; DMG=""; URI=""; MAKE_QUEUE=1; BUILD_ONLY=0

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  --model MODEL   P1005, P1006, P1007 or P1008 (default: detect the USB printer)
  --uri URI       printer device URI (default: detect the USB printer)
  --queue NAME    print queue name (default: HP_LaserJet_<MODEL>)
  --paper SIZE    default paper: A4 or Letter (default: A4)
  --dmg PATH      use a local copy of Apple's HewlettPackardPrinterDrivers.dmg
                  instead of downloading it (about 580 MB) from Apple
  --no-queue      install the driver but do not create a print queue
  --build-only    build and self-test in ./build, install nothing
  -h, --help      show this help
EOF
}

die()  { echo "error: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL=$(echo "${2:-}" | tr '[:lower:]' '[:upper:]'); shift 2 ;;
    --uri) URI="${2:-}"; shift 2 ;;
    --queue) QUEUE="${2:-}"; shift 2 ;;
    --paper) PAPER="${2:-}"; shift 2 ;;
    --dmg) DMG="${2:-}"; shift 2 ;;
    --no-queue) MAKE_QUEUE=0; shift ;;
    --build-only) BUILD_ONLY=1; MAKE_QUEUE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = Darwin ] || die "this installer is for macOS"
[ "$(id -u)" -ne 0 ] || die "run as your normal user, not with sudo; it asks for your password when needed"
case "$PAPER" in A4|Letter) ;; *) die "--paper must be A4 or Letter" ;; esac
xcode-select -p >/dev/null 2>&1 && command -v cc >/dev/null \
  || die "the Xcode command line tools are needed: run  xcode-select --install"
for t in git curl pkgutil hdiutil cpio lpinfo lpadmin; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done

# ---------------------------------------------------------------- printer
step "Looking for the printer"
if [ -z "$URI" ]; then
  FOUND=$(lpinfo -v 2>/dev/null | awk '{print $2}' | grep -E '^usb://Hewlett-Packard/HP%20LaserJet%20P100[5-8]' || true)
  if [ -n "$MODEL" ]; then
    FOUND=$(echo "$FOUND" | grep "HP%20LaserJet%20$MODEL" || true)
  fi
  case $(echo "$FOUND" | grep -c . || true) in
    1) URI="$FOUND" ;;
    0) if [ $MAKE_QUEUE = 1 ]; then
         die "no HP LaserJet P1005/P1006/P1007/P1008 found on USB. Plug it in and switch it on, or pass --uri / --no-queue"
       fi ;;
    *) echo "$FOUND"; die "more than one printer found; pick one with --uri" ;;
  esac
fi
if [ -z "$MODEL" ]; then
  MODEL=$(echo "$URI" | grep -oE 'P100[5-8]' | head -1 || true)
  [ -n "$MODEL" ] || die "no printer detected to take the model from; pass --model P1005|P1006|P1007|P1008"
fi
case "$MODEL" in
  P1005|P1007) ACL=HP1005.acl; FW=sihpP1005.dl ;;
  P1006|P1008) ACL=HP1006.acl; FW=sihpP1006.dl ;;
  *) die "unsupported model '$MODEL' (P1005, P1006, P1007 or P1008)" ;;
esac
QUEUE=${QUEUE:-HP_LaserJet_$MODEL}
echo "model: HP LaserJet $MODEL"
[ -n "$URI" ] && echo "device: $URI"

mkdir -p "$BUILD"

# ---------------------------------------------------------------- foo2zjs
step "Building foo2xqx and arm2hpdl from OpenPrinting foo2zjs ($FOO2ZJS_COMMIT)"
SRC="$BUILD/foo2zjs"
if [ ! -d "$SRC/.git" ] || [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$FOO2ZJS_COMMIT" ]; then
  rm -rf "$SRC"
  git clone -q "$FOO2ZJS_REPO" "$SRC"
  git -C "$SRC" -c advice.detachedHead=false checkout -q "$FOO2ZJS_COMMIT"
fi
# foo2zjs ships its own copy of JBIG-KIT, so nothing from Homebrew is needed.
cc -O2 -w -o "$BUILD/foo2xqx" "$SRC/foo2xqx.c" "$SRC/jbig.c" "$SRC/jbig_ar.c"
cc -O2 -w -o "$BUILD/arm2hpdl" "$SRC/arm2hpdl.c"

step "Building rastertopbm"
cc -O2 -Wall -Wno-deprecated-declarations -o "$BUILD/rastertopbm" "$ROOT/src/rastertopbm.c" -lcups

# ---------------------------------------------------------------- firmware
step "Preparing printer firmware ($ACL -> $FW)"
if [ ! -s "$BUILD/$FW" ]; then
  if [ -z "$DMG" ]; then
    DMG="$BUILD/HewlettPackardPrinterDrivers.dmg"
    if [ ! -s "$DMG" ]; then
      echo "Downloading Apple's HP Printer Drivers package (about 580 MB) from updates.cdn-apple.com"
      echo "(already have it? press Ctrl-C and rerun with --dmg PATH)"
      curl -fL --progress-bar -o "$DMG.part" "$APPLE_HP_DMG_URL"
      mv "$DMG.part" "$DMG"
    fi
  fi
  [ -s "$DMG" ] || die "not found: $DMG"
  MNT=$(mktemp -d "$BUILD/mnt.XXXXXX")
  EXP="$BUILD/hp-pkg"
  trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
  # (newer macOS prints a deprecation warning for hdiutil attach; harmless)
  hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null 2> >(grep -v deprecated >&2)
  PKG=$(ls "$MNT"/*.pkg 2>/dev/null | head -1)
  [ -n "$PKG" ] || die "no installer package inside $DMG"
  # Only use firmware from a package Apple signed.
  pkgutil --check-signature "$PKG" | grep -q "signed Apple Software" \
    || die "$PKG is not signed by Apple; refusing to use it"
  echo "signature: signed Apple Software"
  rm -rf "$EXP"; pkgutil --expand "$PKG" "$EXP"
  PAYLOAD=$(ls "$EXP"/*.pkg/Payload | grep -v PreInstall | head -1)
  (cd "$BUILD" && gunzip -dc "$PAYLOAD" | cpio -id --quiet \
     "./Library/Printers/hp/laserjet/hplaserjetzjs.bundle/Contents/Resources/$ACL")
  hdiutil detach "$MNT" -quiet; rmdir "$MNT"; trap - EXIT
  rm -rf "$EXP"
  ACLPATH="$BUILD/Library/Printers/hp/laserjet/hplaserjetzjs.bundle/Contents/Resources/$ACL"
  [ -s "$ACLPATH" ] || die "$ACL not found in Apple's package"
  "$BUILD/arm2hpdl" "$ACLPATH" > "$BUILD/$FW"
  rm -rf "$BUILD/Library"
fi
head -c 40 "$BUILD/$FW" | grep -q 'ENTER LANGUAGE=ACL' || die "$BUILD/$FW does not look like a firmware download"
echo "firmware ready: build/$FW ($(wc -c < "$BUILD/$FW" | tr -d ' ') bytes)"

# ---------------------------------------------------------------- PPD
step "Writing the printer description (PPD)"
PPD="$BUILD/HP-LaserJet_$MODEL-hp-p1007-macos.ppd"
# Start from foo2zjs's PPD for this model; replace its Linux-only filter with
# ours, and ask macOS for an 8-bit gray raster at the printer's 1200x600 dpi.
sed -e '/^\*cupsFilter/d' \
    -e '/^\*Resolution 600x400dpi/d' \
    -e '/^\*FoomaticRIPOptionSetting Resolution=/d' \
    -e 's#^\*Resolution 1200x600dpi/1200x600 dpi: .*#*Resolution 1200x600dpi/1200x600 dpi: "<</HWResolution[1200 600]/cupsBitsPerColor 8/cupsColorSpace 18/cupsColorOrder 0>>setpagedevice"#' \
    -e "s/^\\*NickName: .*/*NickName: \"HP LaserJet $MODEL (hp-p1007-macos)\"/" \
    -e "s/^\\*DefaultPageSize: .*/*DefaultPageSize: $PAPER/" \
    -e "s/^\\*DefaultPageRegion: .*/*DefaultPageRegion: $PAPER/" \
    -e "s/^\\*DefaultImageableArea: .*/*DefaultImageableArea: $PAPER/" \
    -e "s/^\\*DefaultPaperDimension: .*/*DefaultPaperDimension: $PAPER/" \
    "$SRC/PPD/HP-LaserJet_$MODEL.ppd" |
  awk -v dest="$DEST" -v fw="$FW" '
    /^\*ModelName/ {
      print "*cupsFilter: \"application/vnd.cups-raster 0 " dest "/p100x-filter\""
      print "*HpP100xFirmware: \"" fw "\""
    }
    { print }' > "$PPD"
grep -q '^\*cupsFilter: "application/vnd.cups-raster' "$PPD" || die "PPD edit failed"
grep -q "^\\*DefaultPageSize: $PAPER" "$PPD" || die "PPD paper size edit failed"

# ---------------------------------------------------------------- self test
step "Self test (renders a test page with macOS's own renderer, nothing is printed)"
STAGE="$BUILD/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "$ROOT/src/p100x-filter" "$BUILD/foo2xqx" "$BUILD/rastertopbm" "$BUILD/$FW" "$STAGE/"
chmod 755 "$STAGE/p100x-filter"
printf 'hp-p1007-macos self test\n\nIf you can read this, rendering works.\n' > "$BUILD/selftest.txt"
cupsfilter -m application/pdf "$BUILD/selftest.txt" > "$BUILD/selftest.pdf" 2>/dev/null \
  || die "could not make a test PDF"
env -i PPD="$PPD" /usr/libexec/cups/filter/cgpdftoraster 1 test test 1 "PageSize=$PAPER" "$BUILD/selftest.pdf" \
  > "$BUILD/selftest.ras" 2>/dev/null || die "macOS raster renderer failed"
# env -i mimics the bare environment CUPS gives filters.
env -i PPD="$PPD" "$STAGE/p100x-filter" 1 test selftest 1 "PageSize=$PAPER" "$BUILD/selftest.ras" \
  > "$BUILD/selftest.prn" 2> "$BUILD/selftest.log" || { cat "$BUILD/selftest.log"; die "filter failed"; }
grep -q 'rastertopbm: 1 page' "$BUILD/selftest.log" || { cat "$BUILD/selftest.log"; die "no page rendered"; }
FWSIZE=$(wc -c < "$BUILD/$FW"); OUTSIZE=$(wc -c < "$BUILD/selftest.prn")
[ "$OUTSIZE" -gt $((FWSIZE + 1000)) ] || die "filter output too small"
echo "ok: firmware + 1 page, $OUTSIZE bytes of printer data"
rm -rf "$STAGE"

if [ $BUILD_ONLY = 1 ]; then
  echo; echo "Build-only: nothing installed. Files are in $BUILD"; exit 0
fi

# ---------------------------------------------------------------- install
step "Installing into $DEST (needs your password)"
sudo mkdir -p "$DEST"
sudo install -o root -g wheel -m 755 "$ROOT/src/p100x-filter" "$BUILD/foo2xqx" "$BUILD/rastertopbm" "$DEST/"
sudo install -o root -g wheel -m 644 "$BUILD/$FW" "$PPD" "$DEST/"

if [ $MAKE_QUEUE = 1 ]; then
  step "Creating print queue $QUEUE"
  # lpadmin warns that "printer drivers are deprecated"; that refers to a future CUPS.
  sudo lpadmin -p "$QUEUE" -E -v "$URI" -P "$DEST/$(basename "$PPD")" \
    -D "HP LaserJet $MODEL" -o PageSize="$PAPER" 2>&1 | grep -v 'deprecated' || true
  lpstat -p "$QUEUE" >/dev/null 2>&1 || die "queue $QUEUE was not created"
  if ! lpstat -d 2>/dev/null | grep -q 'destination:'; then
    sudo lpadmin -d "$QUEUE"
  fi
  lpstat -p "$QUEUE"
fi

echo
echo "Done."
if [ $MAKE_QUEUE = 1 ]; then
  echo "Print a test page:  lp -d $QUEUE $BUILD/selftest.pdf"
  echo "Then print normally with Cmd-P. Do not remove or re-add this printer in"
  echo "System Settings: macOS would pick a generic driver that silently prints nothing."
fi
