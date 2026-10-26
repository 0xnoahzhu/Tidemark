# dmgbuild settings for Tidemark's installer window: the app on the left, a dashed arrow, the Applications link on
# the right, in a fixed 540 x 380 window with no toolbar, sidebar, path bar or status bar.
#
# scripts/release.sh runs it as:
#   dmgbuild -s scripts/dmg/settings.py -D app=<Tidemark.app> -D background=scripts/dmg/background.tiff \
#            "Tidemark <version>" <output.dmg>
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "ULFO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

# The volume shows the app's own icon in Finder and on the desktop.
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

background = defines["background"]
window_rect = ((200, 120), (540, 380))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

arrange_by = None
icon_size = 80
text_size = 12
label_pos = "bottom"
icon_locations = {
    app_name: (130, 220),
    "Applications": (410, 220),
}
