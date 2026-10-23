# HP LaserJet P1005 / P1006 / P1007 / P1008 on modern macOS

A working print driver for the HP LaserJet P1005, P1006, P1007 and P1008 on
current macOS, including Apple Silicon. No Rosetta, no disabling System
Integrity Protection, and no Ghostscript.

HP never shipped an Apple Silicon driver for these printers, and Apple's last
HP driver package (5.1.1, 2020) is Intel-only and refuses to install on macOS
newer than 12. macOS then sets the printer up with a generic PCL driver. These
printers cannot read PCL, so jobs report "completed" and nothing comes out.

## Install

You need the Xcode command line tools (`xcode-select --install`) and the
printer connected by USB and switched on.

```sh
git clone https://github.com/ska2704/hp-p1007-macos.git
cd hp-p1007-macos
./install.sh
```

Run it as your normal user; it asks for your password only to copy the driver
into `/Library/Printers/hp-p1007-macos` and to create the print queue. Then print
normally with Cmd-P to the **HP_LaserJet_P100x** queue.

The installer downloads Apple's HP Printer Drivers package (about 580 MB) to get
the printer's firmware. If you already have `HewlettPackardPrinterDrivers.dmg`,
pass it instead:

```sh
./install.sh --dmg ~/Downloads/HewlettPackardPrinterDrivers.dmg
```

Options:

```
--model MODEL   P1005, P1006, P1007 or P1008 (default: detect the USB printer)
--uri URI       printer device URI (default: detect the USB printer)
--queue NAME    print queue name (default: HP_LaserJet_<MODEL>)
--paper SIZE    default paper, A4 or Letter (default: A4)
--dmg PATH      local copy of Apple's HewlettPackardPrinterDrivers.dmg
--no-queue      install the driver only
--build-only    build and self-test in ./build, install nothing
```

To remove the driver and its print queues:

```sh
./uninstall.sh
```

**Do not remove and re-add the printer in System Settings.** macOS would pick
the generic driver again. If that happens, run `./install.sh` again.

## Status

Early release. Reports, either way, are welcome as issues.

Verified on macOS 27 (Apple Silicon) with a P1007 over USB: the driver
pipeline in this repository (same filter, converter, foo2xqx options and
firmware) prints A4 documents correctly, centred, with normal margins. For the
same page, the installer's build produces byte-identical printer data apart from
a job timestamp.

Not yet verified on real hardware:

- a fresh run of `install.sh` through to queue creation (the pipeline above was
  installed by hand; the installer's build and self-test steps are tested)
- the P1005, P1006 and P1008
- Letter paper
- Intel Macs and macOS versions before 27

The installer builds and self-tests all four models and both paper sizes, but a
self-test is not a printed page.

## How it works

These are host-based printers: the Mac must turn every page into a compressed
bitmap, and the printer needs its firmware sent from the Mac each time it is
switched on.

1. macOS's own `cgpdftoraster` renders each page as 8-bit gray at the
   printer's 1200x600 dpi.
2. `rastertopbm` (in `src/`) dithers that to 1 bit and pads it back to the full
   sheet, because macOS sends only the printable area.
3. [`foo2xqx`](https://github.com/OpenPrinting/foo2zjs) encodes the pages in the
   printer's XQX format.
4. The filter `src/p100x-filter` sends the firmware, then the pages.

Why not Ghostscript, like foo2zjs on Linux? macOS runs CUPS filters in a
sandbox that cannot run programs from `/opt/homebrew` or `/usr/local`. A filter
that calls Homebrew's `gs` works when you test it by hand and fails inside CUPS
with "Operation not permitted". Using macOS's own renderer avoids that, and
avoids bundling a copy of Ghostscript.

### Firmware

The firmware belongs to HP and is not included in this repository. The
installer extracts it from Apple's HP Printer Drivers package on your Mac
(`HP1005.acl` for the P1005/P1007, `HP1006.acl` for the P1006/P1008), checks
that the package is signed by Apple, and converts it with foo2zjs's
`arm2hpdl`.

## Troubleshooting

- **Nothing prints, the job says completed.** The queue is probably using
  a generic driver. Check with `lpstat -l -p` and System Settings; run
  `./install.sh` again.
- **The paper roller turns but nothing prints.** The firmware was sent but
  page rendering failed. Look at the job's lines in
  `/private/var/log/cups/error_log`.
- **`lpadmin` warns that "printer drivers are deprecated".** This refers to a
  future version of CUPS. It works on current macOS, but a future macOS
  release may stop accepting drivers like this one.

## Credits

- [foo2zjs](https://github.com/OpenPrinting/foo2zjs) by Rick Richardson,
  maintained by OpenPrinting, which does the actual printer encoding.
- [hp-p1102-macos](https://github.com/cragkhit/hp-p1102-macos), the same idea
  for the P1102, which documents the same CUPS sandbox problem.

## Licence

GPL-2.0-or-later, the same as foo2zjs. See [LICENSE](LICENSE).
