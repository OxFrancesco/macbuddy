# MacBuddy

A small macOS utility (SwiftUI, Swift 6) that does two things:

1. **Projects** — pick a base folder, hit a global shortcut from anywhere, type a name, and MacBuddy creates the subfolder ("project") and opens your terminal of choice inside it, injecting whatever command you want (`claude`, `codex`, `gemini`, …).
2. **Dock Palette** — restyle every app icon pinned in your Dock with a unified palette: Noir (black & white), Tint (any color), Sepia, or Pastel, with an intensity slider and live previews. One click to apply, one click to restore the originals.

## Build

Requires Xcode 26+ and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The `.xcodeproj` is generated, not checked in:

```bash
xcodegen generate
open MacBuddy.xcodeproj        # build & run from Xcode
# or build + install/relaunch /Applications/MacBuddy.app in one go:
scripts/install.sh
```

Add the app to **System Settings → General → Login Items** if you want the shortcut available all the time (the app must be running for the hotkey to work — it also lives in the menu bar).

**Signing matters here.** The Dock Palette needs the **App Management** permission, and macOS ties that grant to the app's code-signing identity. The project therefore signs with a real Apple Development certificate (`DEVELOPMENT_TEAM` in `project.yml` — change it to your own team). With ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`) the grant is keyed to one exact binary, so every rebuild — or a second copy of the app lying around — silently revokes it ("permission gone after Quit & Reopen"). Keep `/Applications/MacBuddy.app` as the only copy you launch; `scripts/install.sh` takes care of that.

## Projects

- **Projects folder** — where new project subfolders are created.
- **Terminal app** — Ghostty, Terminal, iTerm2, Alacritty, kitty, or WezTerm. Terminal/iTerm2 are driven via AppleScript; the others get CLI args through `open -n -b <bundle-id> --args` (Ghostty's officially supported launch path).
- **Command to run** — free text injected into the new terminal, e.g. `claude` or `codex`. It runs in an interactive login shell (your PATH from `~/.zshrc`/`~/.zprofile` applies) and drops back into a shell when the command exits, so the window stays open. Leave it empty to just get a shell in the project folder.
- **Global shortcut** — default is **⌃⌥⌘N**. Recorded with a Carbon hotkey, so no Accessibility permission is needed.

The prompt is a Raycast-style floating panel: type the name (a free `project-N` name is pre-filled), **Return** creates + launches, **Esc** cancels. It doesn't steal focus from the app you were in.

First launch with Terminal/iTerm2 triggers the macOS **Automation** permission prompt ("MacBuddy wants to control Terminal") — allow it.

## Dock Palette

- Reads the apps pinned in your Dock from `com.apple.dock` preferences and shows live styled previews.
- Styles: **Noir** (grayscale), **B&W** (pure two-tone `#FEFEFE`/`#030303`, no gradient), **Tint** (any color), **Sepia**, **Pastel** — plus an intensity slider.
- **Icon collections**: save a generated AI icon set under a name (e.g. "claymation"), then load it back later to re-apply — switch whole dock themes without regenerating. The stacks button in the controls row opens the collections list.
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

No third-party dependencies. Not sandboxed (it needs to script terminals and write icons onto other app bundles), signed with an Apple Development certificate so TCC permissions survive rebuilds.
