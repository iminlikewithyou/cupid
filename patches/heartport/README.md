# Heartport's Wine patches

Heartport's own changes to Wine: the Mac driver (`dlls/winemac.drv`), Media Foundation's source
reader (`dlls/mfreadwrite`) and CoreMessaging (`dlls/coremessaging`). They apply to the
CodeWeavers Wine 26.3.0 `sources/wine` tree **after** Recall's set (`../recall/`, in the order its
README gives), in this order:

1. `wine-winemac-dock-identity.patch`
2. `wine-winemac-native-fullscreen.patch`
3. `wine-winemac-fullscreen-normal-level.patch` (from heartport-20261012.5)
4. `wine-mfreadwrite-shared-textures.patch` (from heartport-20261012.5)
5. `wine-coremessaging-dispatcher-queue.patch` (from heartport-20261012.5)

`scripts/runtime/build_portable_runtime.py` checks each patch's sha256 (`HEARTPORT_PATCHES`),
applies them with `git apply` and keeps a copy of each applied patch in the source tree
(`.heartport-own-patches/`, with `applied.json`). A rerun skips what is already applied; a
patch that changed is reversed from its stored copy (with every later one) and the current one
applied, so the Wine step only rebuilds the driver. Recall's marker (`.heartport-patches.json`)
is not involved.

The driver patches are inert unless their environment variables are set; with none set the
driver behaves exactly as Recall's. Heartport sets them for every Wine process (docs/PHASE2.md,
launch contract). The other two change behaviour for every program (see below).

The patches are `git diff`s made against a copy of the folder they change as the earlier patches
leave it. To change one: copy that folder into a scratch git repository, commit, apply the earlier
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

The Dock tile's hover label is **not** this name: for a bundled application the Dock shows the
bundle's display name, which is its folder name (`xdt`) unless the bundle carries a localized
display name. Iteration 5 checked it with test programs: LSDisplayName set before or after the
process becomes regular, toggling the activation policy, and LaunchServices' `CFBundleName` item
all leave the label alone (System Events' Dock item name, which is the hover label, stays the
executable's or bundle's file name). So Heartport's `GameModeBundle` (core, bundle version 3)
gives `xdt.app` `CFBundleDisplayName = xdt`, `LSHasLocalizedDisplayName = true` and
`Contents/Resources/en.lproj/InfoPlist.strings` with `CFBundleDisplayName = "Heartopia"` (Finder's
rule: the localized name is used while the folder name equals the plain display name). The Dock
then says Heartopia. WINEMAC_APP_NAME still names the running application for Cmd-Tab and the
application menu.

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

## wine-winemac-fullscreen-normal-level.patch

`WINEMAC_FULLSCREEN_NORMAL_LEVEL=<exe>[;<exe>...]` (matched like `WINEMAC_NATIVE_FULLSCREEN`, which
wins if both list the program). A listed program's fullscreen window (borderless, covering a
screen, not Recall's canvas) keeps `NSNormalWindowLevel` while the application is active instead
of `NSStatusWindowLevel + 1`, and while such a window is the key window the application sets
`NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideDock` (the options it
had before come back when the window stops being key or fullscreen, or the application is
deactivated). No Space: the window keeps covering the whole panel (1728 x 1117 on a 16-inch
MacBook Pro, camera housing included), notification banners draw over it, and the menu bar and
Dock appear when the pointer reaches the edge. `-[WineApplicationController
updateFullscreenPresentation]` updates its state before calling `setPresentationOptions:`, which
re-enters it (a first version without that saved the auto-hide options as "the previous ones"
and never restored them).

## wine-mfreadwrite-shared-textures.patch

Unity's video player (Heartopia's logo video `heartopia.mp4` and its cutscenes) reads every frame
through `IMFDXGIBuffer::GetResource`, `IDXGIResource::GetSharedHandle` and
`ID3D11Device::OpenSharedResource` (UnityPlayer.dll; it reports "Got null handle from
IDXGIResource::GetSharedHandle." otherwise and draws nothing). On Windows the source reader hands
out the decoder's or video processor's own textures, which are shareable. Wine's reader copies
each frame into samples from its own allocator, which made shareable textures only when the
application set `MF_SA_D3D11_SHARED(_WITHOUT_MUTEX)` on the reader, so every frame's shared handle
was NULL and the video stayed black although it decoded completely. With the patch the reader's
allocator uses `MF_SA_D3D11_SHARED_WITHOUT_MUTEX` (`D3D11_RESOURCE_MISC_SHARED`) unless the
application chose either attribute. DXMT implements shared textures (mach-port backed), so no
DXMT change was needed.

## wine-coremessaging-dispatcher-queue.patch

A minimal `Windows.System.DispatcherQueue` in coremessaging.dll (registered in `classes.idl`, so
`wineboot -u` adds its WinRT activation entry; Heartport runs that whenever the runtime changes):

- `IDispatcherQueueStatics::GetForCurrentThread` returns the calling thread's queue, or NULL with
  S_OK when the thread has none (as Windows does).
- A queue belongs to one thread and owns a message-only window there; `TryEnqueue` and
  `TryEnqueueWithPriority` post the handler to it (priorities are ignored), so it runs when that
  thread pumps messages. `IDispatcherQueue2::HasThreadAccess`; `CreateTimer` is not implemented;
  `ShutdownStarting`/`ShutdownCompleted` registrations are accepted and never fire.
- `CreateDispatcherQueueController` (current thread or a dedicated thread, which runs a message
  loop, in an STA when asked) and `DispatcherQueueController.CreateOnDedicatedThread` create real
  queues; `get_DispatcherQueue` returns it; `ShutdownQueueAsync` takes the queue off its thread
  (later `TryEnqueue` returns FALSE) and ends a dedicated thread.

Why: right after the logo, GameAssembly.dll (the Vuplex 3D WebView code that draws the game's
two-button dialog) asks for `Windows.System.DispatcherQueue` thousands of times and Wine answered
"Failed to find library"; libcef.dll was never loaded.
