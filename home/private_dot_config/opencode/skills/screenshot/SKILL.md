---
name: Screenshot
description: Take a screenshot when the user asks to capture, see, or look at the screen, display, or an app window, or asks for visual confirmation of something on screen
---

This workstation runs GNOME on Wayland. GNOME does not implement
`wlr-screencopy`, so `grim`-style tools cannot work here, and
`org.gnome.Shell.Screenshot` refuses foreign callers. The working path is the
freedesktop screenshot portal, wrapped by this skill's script.

## Workflow

1. Capture the full screen:
   ```sh
   bash ~/.config/opencode/skills/screenshot/scripts/capture.sh
   ```
   The script prints the output path (default: timestamped PNG under
   `/tmp/opencode/`). Pass an explicit path as the first argument to control
   the filename.
2. Read the resulting PNG with the file-reading tool so you can see the image
   yourself, then report the path to the user.

The script handles the session environment itself
(`XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`), so it works from plain agent
shells. It fails with a clear message when no graphical session or portal is
available; a first-ever request may require the user to approve a one-time
portal permission dialog.

## Notes

- The portal writes its own copy (typically `~/Pictures/`); the script copies
  the result to the requested path — leave the script's output path as the one
  you report.
- Only full-screen capture is scripted. For "just this window/region", take
  the full screen and crop it yourself from image coordinates.
- Keep all captures under `/tmp/opencode/`; do not litter the home directory.
