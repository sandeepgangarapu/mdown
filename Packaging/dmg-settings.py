# dmgbuild settings for MDown.dmg: the app on the left, Applications on the right,
# and a background with an arrow between them, so installing is one drag.
# Used by Packaging/make-dmg.sh; run that instead of calling dmgbuild directly.
import os

app = defines["app"]
packaging = os.path.dirname(os.path.abspath(defines["background"]))

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

background = defines["background"]
window_rect = ((200, 140), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 128
text_size = 13
icon_locations = {
    "MDown.app": (160, 205),
    "Applications": (480, 205),
}
# Do not set hide_extensions: dmgbuild writes com.apple.FinderInfo onto the
# signed app bundle, which makes codesign --verify --deep --strict fail.
