# -*- coding: utf-8 -*-
# dmgbuild settings for the SwitchMux drag-to-install DMG.
# Invoked by scripts/make_dmg.sh with:
#   dmgbuild -s scripts/dmg_settings.py -D app=<SwitchMux.app> \
#            -D background=<bg.tiff> [-D icon=<AppIcon.icns>] SwitchMux <out.dmg>
# Icon positions must match the layout drawn by scripts/dmg_background.swift.
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
app_name = os.path.basename(app.rstrip("/"))

format = "UDZO"
filesystem = "HFS+"
files = [app]
# Finder labels a symlink with its own file name (it does not localize it the
# way it does /Applications itself), so name it to match the Chinese artwork.
APPS_LINK = "应用程序"
symlinks = {APPS_LINK: "/Applications"}
# Deliberately no hide_extensions: dmgbuild implements it with SetFile, which
# writes a com.apple.FinderInfo xattr onto the signed bundle root; that makes
# `codesign --verify --strict` reject the app ("Finder information ... not
# allowed") and travels with it into /Applications. Finder hides ".app" by
# default anyway.

_icon = defines.get("icon")  # noqa: F821
if _icon:
    icon = _icon

background = defines["background"]  # noqa: F821

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

# ((x, y), (width, height)) in points. Finder may treat WindowBounds as the
# outer frame (title bar included) or as the content area; the background is
# drawn 428pt tall with the layout inside its top 400pt, so either way the
# whole composition is visible and nothing but plain gradient is cropped.
window_rect = ((200, 160), (660, 428))
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 128

icon_locations = {
    app_name: (170, 200),
    APPS_LINK: (490, 200),
}
