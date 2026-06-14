# Plan 005: Add CLAUDE.md, pin build tooling, and document verification

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: this plan was written against commit `522b5f7`
> **plus uncommitted working-tree changes**. Confirm the README excerpt below
> still matches `README.md`, and check whether `scripts/verify.sh` exists
> (plan 001). On README mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (references plan 001's `scripts/verify.sh` if present)
- **Category**: dx
- **Planned at**: commit `522b5f7` (+ uncommitted working tree), 2026-06-12

## Why this matters

This repo will keep being modified by coding agents (these plans included),
and it has unusually sharp platform edges that are documented only in scattered
comments: the `.xcodeproj` is generated and must never be edited directly; the
App Management TCC grant dies if the signing identity changes; `killall Dock`
is a side effect of normal operation; a paid API key lives in the keychain and
must never be printed. An agent that doesn't know these facts can silently
break the user's permission grants or leak a key into logs. A short
`CLAUDE.md` makes every future agent session start with this knowledge. While
here: pin the only build dependency (`xcodegen`) via a `Brewfile` and surface
the verification command in the README.

## Current state

- No `CLAUDE.md`, `AGENTS.md`, or `Brewfile` exists in the repo root.
- `README.md` lines 8–17 (the Build section to extend):

  ```markdown
  ## Build

  Requires Xcode 26+ and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The `.xcodeproj` is generated, not checked in:

  ```bash
  xcodegen generate
  open MacBuddy.xcodeproj        # build & run from Xcode
  # or build + install/relaunch /Applications/MacBuddy.app in one go:
  scripts/install.sh
  ```
  ```

- `project.yml` — signing block (lines 29–37) carries the critical comment
  about App Management TCC being keyed to the signing identity; deployment
  target macOS 15, Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`.
- `scripts/install.sh` — Release build + install to `/Applications` (the
  canonical signed copy), re-applies the app's own icon, restarts the Dock.
- `scripts/verify.sh` — exists only if plan 001 has landed.
- Source layout: `MacBuddy/App` (entry, settings, tabs, menu bar, theme),
  `MacBuddy/Projects` (Carbon hotkey, prompt panel, terminal launching,
  project search), `MacBuddy/DockPalette` (dock reading, Core Image styling,
  AI restyling via fal.ai, icon apply/restore, collections).
- The fal.ai API key is stored via `MacBuddy/DockPalette/FalKeyStore.swift`
  in the login keychain (service `dev.francescooddo.macbuddy.fal`), with a
  `FAL_KEY` env-var fallback; the UI never displays it after save.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Tool check | `brew bundle check` (after creating Brewfile) | exit 0, "dependencies are satisfied" |
| Full gate (if plan 001 landed) | `scripts/verify.sh` | `** TEST SUCCEEDED **`, exit 0 |
| Fallback gate | `xcodegen generate && xcodebuild -project MacBuddy.xcodeproj -scheme MacBuddy -configuration Debug -derivedDataPath build build` | `** BUILD SUCCEEDED **` |

## Suggested executor toolkit

- If an `agents-md` skill is available, invoke it before writing `CLAUDE.md`
  and follow its conciseness guidance — but the content below is already
  scoped to fit it; do not pad.

## Scope

**In scope**:
- `CLAUDE.md` (create, repo root)
- `Brewfile` (create, repo root)
- `README.md` (Build section only)

**Out of scope** (do NOT touch):
- `project.yml`, `scripts/install.sh`, any Swift source.
- Do not create CI workflows (`.github/`) — the user hasn't asked for CI.
- Do not duplicate README content into CLAUDE.md beyond what's specified.

## Git workflow

- Branch: `advisor/005-agent-docs-tooling`
- Conventional commits (e.g. `docs: Add CLAUDE.md and pin xcodegen via Brewfile`)
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create CLAUDE.md

Create `CLAUDE.md` at the repo root with exactly this content (adjust the
xcodegen version in step 2's Brewfile note if yours differs):

```markdown
# MacBuddy — agent guide

macOS utility (SwiftUI, Swift 6, macOS 15+). Two features: **Projects**
(global hotkey → floating prompt → create folder → open terminal with a
command) and **Dock Palette** (restyle Dock icons via Core Image or fal.ai,
apply/restore custom icons on app bundles).

## Build & verify

- `.xcodeproj` is GENERATED. Never edit it; edit `project.yml`, then
  `xcodegen generate`.
- Verify changes: `scripts/verify.sh` (xcodegen + build + tests).
- Install for real use: `scripts/install.sh` (Release build →
  `/Applications/MacBuddy.app`). Don't run it just to verify a change — it
  kills and relaunches the app and restarts the Dock.

## Sharp edges — read before touching

- **Signing is load-bearing.** The App Management TCC grant is keyed to the
  code-signing identity (`Apple Development`, team in `project.yml`). Never
  switch to ad-hoc signing, change `DEVELOPMENT_TEAM`, or leave extra copies
  of MacBuddy.app around — each silently revokes the user's permission grant.
  `/Applications/MacBuddy.app` is the only copy that should launch.
- **The fal.ai API key is a secret.** It lives in the login keychain
  (`FalKeyStore`); `FAL_KEY` env var is a fallback. Never print, log, or
  display it, and never write it to disk or UserDefaults.
- **Applying icons mutates other apps' bundles** (Finder custom-icon
  mechanism) and runs `killall Dock`. Don't trigger `applyToDock`/
  `restoreOriginalIcons`/`relaunchDock` from tests or scripts.
- **Swift isolation**: the project builds with
  `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`. Types opt out with explicit
  `nonisolated`; off-main work is marked `@concurrent`. Match this — don't
  add `@MainActor` annotations (redundant) or `nonisolated(unsafe)` (banned).

## Layout

- `MacBuddy/App` — entry point, settings, tab shell, menu bar, theme.
- `MacBuddy/Projects` — Carbon hotkey (no Accessibility permission needed),
  prompt panel, terminal launchers (AppleScript for Terminal/iTerm2; launch
  scripts via `open --args` for Ghostty/Alacritty/kitty/WezTerm), fuzzy
  project search.
- `MacBuddy/DockPalette` — Dock reading (`com.apple.dock` prefs), Core Image
  styling, fal.ai client + AI icon pipeline, icon stores (originals /
  generated / collections under `~/Library/Application Support/MacBuddy/`),
  apply/restore.
- `MacBuddyTests` — Swift Testing (`@Test`/`#expect`). Pure logic only; no
  test may write outside temp dirs or touch other apps' bundles.

## Conventions

- No third-party dependencies; keep it that way unless asked.
- Conventional commits (`feat:`, `fix:`, `docs:`…), 4-space indent, `///` doc
  comments that explain *why*.
- Errors surface to users via `statusMessage`/alerts — don't swallow with
  `try?` in new code; log via `os.Logger(subsystem: "dev.francescooddo.macbuddy", …)`.
- `plans/` holds advisor-written implementation plans (`plans/README.md` is
  the index); update plan status there when you execute one.
```

If `scripts/verify.sh` does not exist yet (plan 001 not landed), replace that
bullet with the fallback gate command from "Commands you will need".

**Verify**: `test -f CLAUDE.md && head -3 CLAUDE.md` → prints the heading.

### Step 2: Create the Brewfile and pin the toolchain expectation

Create `Brewfile` at the repo root:

```ruby
brew "xcodegen"
```

Then record the currently-working version for humans: run `xcodegen version`
and note the output — you'll embed it in the README in step 3.

**Verify**: `brew bundle check` → exit 0 (xcodegen already installed satisfies it).

### Step 3: Extend the README Build section

In `README.md`, inside the Build section code block, add the verification
command after the `scripts/install.sh` line:

```bash
# verify a change (build + tests) without installing:
scripts/verify.sh
```

and change the requirements sentence to mention the Brewfile and tested
version, e.g.:

```markdown
Requires Xcode 26+ and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew bundle` installs it; tested with xcodegen <version from step 2>). The
`.xcodeproj` is generated, not checked in:
```

Skip the `scripts/verify.sh` line (keep the sentence change) if plan 001
hasn't landed; note that in your report.

**Verify**: `grep -n "brew bundle" README.md` → 1 match;
`grep -n "verify.sh" README.md` → 1 match (when plan 001 landed).

### Step 4: Gate

**Verify**: run the full gate (or fallback gate) — `** TEST SUCCEEDED **` /
`** BUILD SUCCEEDED **`. Docs changes can't break the build; this confirms
you didn't accidentally touch anything else.

## Test plan

No code changes — the done criteria below are the test. The real test is the
next agent session reading `CLAUDE.md` before touching `project.yml`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `CLAUDE.md` exists and contains the "Sharp edges" section (`grep -c "Sharp edges" CLAUDE.md` → 1)
- [ ] `CLAUDE.md` contains no secret values (`grep -ci "fal_key=" CLAUDE.md` → 0; key *names* are fine)
- [ ] `Brewfile` exists; `brew bundle check` exits 0
- [ ] README Build section mentions `brew bundle` (and `verify.sh` when plan 001 landed)
- [ ] Build/verify gate passes
- [ ] `git status --short` shows only `CLAUDE.md`, `Brewfile`, `README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- A `CLAUDE.md` or `AGENTS.md` appears in the repo root before you start
  (someone else created one — reconcile, don't overwrite).
- The README Build section no longer matches the excerpt (drift).
- `brew` is unavailable in your environment — create the Brewfile anyway,
  skip the `brew bundle check` verification, and note it in your report.

## Maintenance notes

- When the test target, scripts, or signing setup change, update `CLAUDE.md`
  in the same PR — a stale agent guide is worse than none.
- If the project ever adds CI, the Brewfile is the place CI should install
  tooling from.
- Reviewer focus: the "Sharp edges" claims must stay factually aligned with
  `project.yml` and `FalKeyStore.swift`.
