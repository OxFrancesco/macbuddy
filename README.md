# MacBuddy

A small macOS utility (SwiftUI, Swift 6) that does two things:

1. **Projects** — pick a base folder, hit a global shortcut from anywhere, type a name, and MacBuddy creates the subfolder ("project") and opens your terminal of choice inside it, injecting whatever command you want (`claude`, `codex`, `gemini`, …).
2. **Dock Palette** — restyle every app icon pinned in your Dock with a unified palette: Noir (black & white), Tint (any color), Sepia, or Pastel, with an intensity slider and live previews. One click to apply, one click to restore the originals.

## Build

Requires Xcode 26+ and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The `.xcodeproj` is generated, not checked in:

```bash
xcodegen generate
open MacBuddy.xcodeproj        # build & run from Xcode
# or from the CLI:
xcodebuild -project MacBuddy.xcodeproj -scheme MacBuddy -configuration Release -derivedDataPath build build
```

Copy `build/Build/Products/Release/MacBuddy.app` to `/Applications` and add it to **System Settings → General → Login Items** if you want the shortcut available all the time (the app must be running for the hotkey to work — it also lives in the menu bar).

## Projects

- **Projects folder** — where new project subfolders are created.
- **Terminal app** — Ghostty, Terminal, iTerm2, Alacritty, kitty, or WezTerm. Terminal/iTerm2 are driven via AppleScript; the others get CLI args through `open -n -b <bundle-id> --args` (Ghostty's officially supported launch path).
- **Command to run** — free text injected into the new terminal, e.g. `claude` or `codex`. It runs in an interactive login shell (your PATH from `~/.zshrc`/`~/.zprofile` applies) and drops back into a shell when the command exits, so the window stays open. Leave it empty to just get a shell in the project folder.
- **Global shortcut** — default is **⌃⌥⌘N**. Recorded with a Carbon hotkey, so no Accessibility permission is needed.

The prompt is a Raycast-style floating panel: type the name (a free `project-N` name is pre-filled), **Return** creates + launches, **Esc** cancels. It doesn't steal focus from the app you were in.

First launch with Terminal/iTerm2 triggers the macOS **Automation** permission prompt ("MacBuddy wants to control Terminal") — allow it.

## Dock Palette

- Reads the apps pinned in your Dock from `com.apple.dock` preferences and shows live styled previews.
- **Apply to Dock** writes a custom icon onto each app bundle (the standard Finder custom-icon mechanism, like Pictogram/LiteIcon), then restarts the Dock.
- **Restore Originals** removes the custom icons and restarts the Dock.

Caveats:

- Apps under `/System` (Safari, Finder, …) are on the read-only system volume and are skipped — they show a lock badge.
- Writing a custom icon adds Finder metadata to the bundle; some apps may re-trigger a Gatekeeper check on next launch. App updates typically overwrite the custom icon — just re-apply.
- On macOS 26, system icon theming (dark/tinted icons) can take precedence over custom icons for apps that ship Icon Composer assets.

## Project layout

```
MacBuddy/
  App/            app entry, settings, tab shell, menu bar
  Projects/       hotkey (Carbon), shortcut recorder, floating prompt panel,
                  terminal launch strategies, project folder creation
  DockPalette/    dock reading, Core Image styling, icon apply/restore, grid UI
```

No third-party dependencies. Not sandboxed (it needs to script terminals and write icons onto other app bundles), signed to run locally.
