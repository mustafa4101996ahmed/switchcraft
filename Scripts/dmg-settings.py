# dmgbuild settings for the Switchcraft installer window. Used by Scripts/release.sh.
# Icon positions must match Scripts/make-dmg-background.swift.
app = defines.get("app", "build/Switchcraft.app")  # noqa: F821 (dmgbuild injects `defines`)
background = defines.get("background", "build/dmg/background.tiff")  # noqa: F821

files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"  # volume icon
format = "ULFO"  # LZFSE: smaller, macOS 10.11+

window_rect = ((200, 140), (660, 460))  # frame incl. title bar; content area ≈ 400 pt
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {"Switchcraft.app": (170, 160), "Applications": (490, 160)}
hide_extensions = ["Switchcraft.app"]
