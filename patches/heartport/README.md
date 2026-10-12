# Heartport's Wine patches

Heartport's own changes to Wine's Mac driver (`dlls/winemac.drv`). They apply to the CodeWeavers
Wine 26.3.0 `sources/wine` tree **after** Recall's set (`../recall/`, in the order its README
gives), in this order:

1. `wine-winemac-dock-identity.patch`
2. `wine-winemac-native-fullscreen.patch`

`scripts/runtime/build_portable_runtime.py` checks each patch's sha256 (`HEARTPORT_PATCHES`),
applies them with `git apply` and keeps a copy of each applied patch in the source tree
(`.heartport-own-patches/`, with `applied.json`). A rerun skips what is already applied; a
patch that changed is reversed from its stored copy (with every later one) and the current one
applied, so the Wine step only rebuilds the driver. Recall's marker (`.heartport-patches.json`)
is not involved.

Both are inert unless their environment variables are set; with none set the driver behaves
exactly as Recall's. Heartport sets them for every Wine process (docs/PHASE2.md, launch contract).

The patches are `git diff`s made against a copy of `dlls/winemac.drv` as Recall's patches leave
it. To change one: copy that folder into a scratch git repository, commit, apply the earlier
Heartport patches and commit, make the change, `git diff` it into the patch file, update its
sha256 in `HEARTPORT_PATCHES` and rerun the Wine step.

## wine-winemac-dock-identity.patch

The name and icon the Dock (and Cmd-Tab) show for a Wine process.

- `WINEMAC_APP_NAME=<name>`: once the process has become a regular application (the driver's
  `transformProcessToForeground:`, where it builds the main menu and sets the application icon),
  the running application's display name is set through LaunchServices' private
  `_LSSetApplicationInformationItem(kLSDefaultSessionID, _LSGetCurrentApplicationASN(),
  _kLSDisplayNameKey, name, NULL)`, as Qt and the JDK do. The three symbols are looked up with
  `dlsym` when the driver loads (`setup_app_identity`, macdrv_main.c); if one is missing the name
  is left alone and a `+macdrv` TRACE says so. `lsappinfo info -only name <pid>` shows the result.
- `WINEMAC_APP_ICON=<path to .icns or .png>`: the file becomes `[NSApp setApplicationIconImage:]`
  at the same point, and `macdrv_set_application_icon` (the icon Wine takes from the exe or its
  windows) does nothing while the variable is set, so the exe's icon never replaces it. A file
  that does not load as an image leaves the exe's icon.

Why: the game runs from `xdt.app` (Recall's Game Mode re-exec), whose Info.plist says
"Heartopia", but ntdll's `setprogname("xdt.exe")` and the exe's icon (drawn edge to edge, so it
looks oversized next to other Dock icons) win in the Dock.

## wine-winemac-native-fullscreen.patch

`WINEMAC_NATIVE_FULLSCREEN=<exe>[;<exe>...]` (case-insensitive, matched against the process's
main module like `WINEMAC_MOUSELOOK`). A listed program's "fullscreen window" (borderless,
covering a screen, the kind Unity's Fullscreen Window mode makes) goes into its own macOS
fullscreen Space at the normal window level, instead of floating above everything at
`NSStatusWindowLevel + 1` (which hides notification banners and keeps the game out of Mission
Control and Space switching).

- Enters (`toggleFullScreen:` once, with `NSWindowCollectionBehaviorFullScreenPrimary`) when
  such a window is visible and the application is active; re-checked when the application
  becomes active.
- While in the Space, the Space owns the frame. On a display with a camera housing it is the
  area below it (1728 x 1084 points of the 16-inch MacBook Pro's 1728 x 1117), and Wine is told
  that frame, as for any native fullscreen window, so the program sees a resize. A program that
  asks for the whole screen again gets the Space's frame back; if it insists (more than four
  times in two seconds) the window leaves the Space and floats as before.
- Leaves the Space (then applies the new frame) when the program gives the window a frame that
  no longer covers a screen, or hides it; a destroyed window closes with its Space. The Window
  menu's Exit Full Screen also leaves; the window then floats as before until the program next
  leaves fullscreen or the player enters again.
- Minimize requests while in the Space are refused, as for any native fullscreen window in
  Wine; Recall's "stays minimized until you come back" hold (`macdrv_v1_canvas_held`) never
  applies to a window in a native fullscreen Space (Spaces handle switching away).
- Unlisted programs, titled windows, child windows and Recall's fullscreen canvas (exclusive
  fullscreen) are unchanged.
