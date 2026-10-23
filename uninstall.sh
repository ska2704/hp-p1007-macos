#!/bin/bash
# Remove the hp-p1007-macos driver and every print queue that uses it.
#
# Copyright (C) 2026 hp-p1007-macos contributors
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail
DEST=/Library/Printers/hp-p1007-macos

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user; it asks for your password" >&2; exit 1; }

# Queue PPDs are readable only by root, so check them with sudo.
for q in $(lpstat -v 2>/dev/null | sed -n 's/^device for \([^:]*\):.*/\1/p'); do
  if sudo grep -q "$DEST/p100x-filter" "/private/etc/cups/ppd/$q.ppd" 2>/dev/null; then
    echo "removing print queue $q"
    sudo lpadmin -x "$q"
  fi
done

if [ -d "$DEST" ]; then
  echo "removing $DEST"
  sudo rm -rf "$DEST"
fi
echo "Done. The ./build folder (if any) can be deleted by hand."
