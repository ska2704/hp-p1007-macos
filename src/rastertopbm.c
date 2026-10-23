/*
 * rastertopbm - convert a CUPS raster stream (stdin) into concatenated raw PBM
 * pages (stdout) for foo2xqx.
 *
 * Handles 1-bit black (K) and 8-bit gray (W/SW) rasters; gray is error-diffused
 * (Floyd-Steinberg) to 1 bit.  macOS's cgpdftoraster sends only the imageable
 * area, so each page is padded back to the full sheet; otherwise everything
 * would print shifted toward the top-left corner.
 *
 * Copyright (C) 2026 hp-p1007-macos contributors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <cups/raster.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    cups_raster_t *ras = cupsRasterOpen(0, CUPS_RASTER_READ);
    cups_page_header2_t h;
    int pages = 0;

    if (!ras) { fprintf(stderr, "ERROR: rastertopbm: cannot read raster\n"); return 1; }

    while (cupsRasterReadHeader2(ras, &h)) {
        unsigned w = h.cupsWidth, ht = h.cupsHeight, y, x;
        unsigned xres = h.HWResolution[0], yres = h.HWResolution[1];
        unsigned fullw = h.PageSize[0] * xres / 72, fullh = h.PageSize[1] * yres / 72;
        unsigned left = h.ImagingBoundingBox[0] * xres / 72;
        unsigned top = h.PageSize[1] > h.ImagingBoundingBox[3]
                     ? (h.PageSize[1] - h.ImagingBoundingBox[3]) * yres / 72 : 0;
        if (fullw < w + left || fullh < ht + top) { fullw = w; fullh = ht; left = top = 0; }

        unsigned fbytes = (fullw + 7) / 8, obytes = (w + 7) / 8;
        unsigned char *full = calloc(1, fbytes);
        unsigned char *line = malloc(h.cupsBytesPerLine);
        unsigned char *out = malloc(obytes);
        int *err = calloc(w + 2, sizeof(int)), *nerr = calloc(w + 2, sizeof(int));
        int gray = (h.cupsBitsPerColor == 8 && h.cupsBitsPerPixel == 8);
        int kmono = (h.cupsBitsPerPixel == 1);

        if (!full || !line || !out || !err || !nerr) {
            fprintf(stderr, "ERROR: rastertopbm: out of memory\n"); return 1;
        }
        if (!gray && !kmono) {
            fprintf(stderr, "ERROR: rastertopbm: unsupported raster %u bpc / %u bpp / cspace %u\n",
                    h.cupsBitsPerColor, h.cupsBitsPerPixel, h.cupsColorSpace);
            return 1;
        }
        fprintf(stderr, "DEBUG: rastertopbm: page %d %ux%u in %ux%u at +%u+%u, %ux%u dpi, %u bpp, cspace %u\n",
                pages + 1, w, ht, fullw, fullh, left, top, xres, yres, h.cupsBitsPerPixel, h.cupsColorSpace);

        printf("P4\n%u %u\n", fullw, fullh);
        for (y = 0; y < top; y++) fwrite(full, 1, fbytes, stdout);

        for (y = 0; y < ht; y++) {
            if (cupsRasterReadPixels(ras, line, h.cupsBytesPerLine) != h.cupsBytesPerLine) {
                fprintf(stderr, "ERROR: rastertopbm: short raster read\n"); return 1;
            }
            if (kmono) {
                /* CUPS K: 1 = black, same as PBM.  1-bit W: 1 = white, so invert. */
                int invert = (h.cupsColorSpace != CUPS_CSPACE_K);
                for (x = 0; x < obytes; x++) out[x] = invert ? ~line[x] : line[x];
            } else {
                /* 8-bit gray.  W/SW: 255 = white.  K: 255 = black. */
                int inv = (h.cupsColorSpace == CUPS_CSPACE_K);
                memset(out, 0, obytes);
                memset(nerr, 0, (w + 2) * sizeof(int));
                for (x = 0; x < w; x++) {
                    int v = inv ? 255 - line[x] : line[x];
                    int want = v + err[x + 1] / 16, got;
                    if (want < 128) { out[x >> 3] |= 0x80 >> (x & 7); got = 0; } else got = 255;
                    int e = want - got;
                    err[x + 2] += e * 7;          /* right */
                    nerr[x] += e * 3;             /* below-left */
                    nerr[x + 1] += e * 5;         /* below */
                    nerr[x + 2] += e * 1;         /* below-right */
                }
                int *t = err; err = nerr; nerr = t;
            }
            /* shift the row right by `left` pixels into the full-width line */
            memset(full, 0, fbytes);
            for (x = 0; x < w; x++)
                if (out[x >> 3] & (0x80 >> (x & 7))) { unsigned X = x + left; full[X >> 3] |= 0x80 >> (X & 7); }
            if (fwrite(full, 1, fbytes, stdout) != fbytes) {
                fprintf(stderr, "ERROR: rastertopbm: write failed\n"); return 1;
            }
        }
        memset(full, 0, fbytes);
        for (y = top + ht; y < fullh; y++) fwrite(full, 1, fbytes, stdout);
        free(full); free(line); free(out); free(err); free(nerr);
        pages++;
    }
    cupsRasterClose(ras);
    fprintf(stderr, "DEBUG: rastertopbm: %d page(s)\n", pages);
    return pages ? 0 : 1;
}
