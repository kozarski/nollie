#!/usr/bin/env python3
"""Makes the Mac download's disk image with its window laid out: no toolbar or sidebar, Nollie on the
left, Applications on the right, and the picture from dmg-background.swift behind them.

    dmg-window.py <Nollie.app> <out.dmg> <background.tiff>

Uses dmgbuild, which writes the window's layout itself, so Finder is never asked to and no macOS
permission prompt appears. The caller signs the image afterwards.
"""
import sys

import dmgbuild

WINDOW = (660, 420)
ICON = 112
NOLLIE = (166, 176)
APPLICATIONS = (494, 176)


def settings(app, background):
    return {
        "format": "UDZO",
        "filesystem": "APFS",
        "files": [(app, "Nollie.app")],
        "symlinks": {"Applications": "/Applications"},
        "background": background,
        "window_rect": ((200, 160), WINDOW),
        "default_view": "icon-view",
        "show_toolbar": False,
        "show_sidebar": False,
        "show_status_bar": False,
        "show_pathbar": False,
        "show_tab_view": False,
        "show_icon_preview": False,
        "include_icon_view_settings": True,
        "arrange_by": None,
        "icon_size": ICON,
        "text_size": 12,
        "label_pos": "bottom",
        "icon_locations": {"Nollie.app": NOLLIE, "Applications": APPLICATIONS},
    }


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    app, out, background = argv[1:]
    dmgbuild.build_dmg(out, "Nollie", settings=settings(app, background))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
