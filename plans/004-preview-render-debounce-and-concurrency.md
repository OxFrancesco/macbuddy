# Plan 004: Debounce and parallelize Dock preview re-rendering

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: this plan was written against commit `522b5f7`
> **plus uncommitted working-tree changes**. Open the three files cited in
> "Current state" and confirm the excerpts match the live code. On any
> mismatch, STOP and report.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (concurrency change in UI-facing code with limited automated coverage — verify manually per step 3)
- **Depends on**: none (001 recommended first so the build/test gate exists)
- **Category**: perf
- **Planned at**: commit `522b5f7` (+ uncommitted working tree), 2026-06-12

## Why this matters

Every change to the style, tint, or intensity slider restarts a **serial**
re-render of every Dock icon preview. The intensity slider emits continuous
values while dragging, so each tick cancels the previous render pass and
starts over from the first app — on a full Dock most previews never finish
rendering until the user releases the slider, and the work done before each
cancellation is thrown away. Rendering is already off the main actor
(`IconStyler.render` is `@concurrent`), so the fix is to (a) debounce the
restart so drags coalesce, and (b) render all icons concurrently in a task
group instead of one-by-one. Previews then settle near-instantly after the
user pauses, instead of trickling in.

## Current state

- `MacBuddy/DockPalette/DockPaletteView.swift:19` — re-runs the refresh
  whenever any input changes; SwiftUI cancels the previous task automatically:

  ```swift
  .task(id: model.previewKey) { await model.refreshPreviews() }
  ```

- `MacBuddy/DockPalette/DockPaletteControls.swift:29` — continuous slider
  bound straight to the model: `Slider(value: $model.intensity, in: 0.2...1)`.
  `model.previewKey` (DockPaletteModel.swift:66-68) hashes style + tint +
  intensity + an `appsVersion` counter, so each slider tick produces a new id.
- `MacBuddy/DockPalette/DockPaletteModel.swift:126–151` — `refreshPreviews()`.
  The AI branch (lines 127–140) just surfaces cached results — leave it
  untouched. The non-AI branch is the serial loop to replace:

  ```swift
  let tintColor = TintColor(tint)
  for app in apps {
      if Task.isCancelled { return }
      guard let source = app.previewSource else { continue }
      if let styled = await IconStyler.render(source: source, style: style, tint: tintColor, intensity: intensity) {
          withAnimation(.easeInOut(duration: 0.18)) {
              previews[app.id] = styled
          }
      }
  }
  ```

- `MacBuddy/DockPalette/IconStyler.swift:8-9` — the renderer is explicitly
  off-main and safe to call concurrently (`CIContext` is thread-safe and the
  inputs are value types / immutable `CGImage`s):

  ```swift
  @concurrent
  static func render(source: IconBitmap, style: IconStyle, tint: TintColor, intensity: Double) async -> IconBitmap? {
  ```

- `MacBuddy/DockPalette/IconBitmap.swift` — `IconBitmap` is `Sendable`
  (`@unchecked`, documented as sound because `CGImage` is immutable).
- **Isolation context (important):** the project sets
  `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, so `DockPaletteModel` and
  `refreshPreviews()` are MainActor-isolated. `DockApp` (in `DockApp.swift`)
  is a plain struct but MainActor-isolated by that default — do **not**
  capture whole `DockApp` values inside `group.addTask` closures; extract the
  `Sendable` pieces (`String` id + `IconBitmap` source) first, as written in
  step 1. `IconStyle`, `TintColor`, `Double` are Sendable value types.
- Repo conventions: 4-space indent; preview updates animate with
  `withAnimation(.easeInOut(duration: 0.18))` — keep that.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Regenerate project | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -project MacBuddy.xcodeproj -scheme MacBuddy -configuration Debug -derivedDataPath build build` | `** BUILD SUCCEEDED **` |
| Full gate (if plan 001 landed) | `scripts/verify.sh` | `** TEST SUCCEEDED **`, exit 0 |
| Run the app for manual check | `open build/Build/Products/Debug/MacBuddy.app` | app launches |

## Suggested executor toolkit

- If a `swiftui-pro` or `swiftui-expert-skill` skill is available in your
  environment, consult it when reviewing the task-group code in step 1 for
  Swift 6 isolation correctness.

## Scope

**In scope**:
- `MacBuddy/DockPalette/DockPaletteModel.swift` — `refreshPreviews()` only.

**Out of scope** (do NOT touch):
- `DockPaletteView.swift` / `DockPaletteControls.swift` — the `.task(id:)`
  restart mechanism and the direct slider binding are correct; the debounce
  lives inside `refreshPreviews`.
- The AI branch of `refreshPreviews` (lines 127–140) and everything else in
  `DockPaletteModel`.
- `IconStyler.swift` — already concurrent; no changes.
- Do NOT introduce a Combine/timer-based debounce or new dependencies; the
  task-cancellation sleep below is the whole mechanism.

## Git workflow

- Branch: `advisor/004-preview-concurrency`
- Conventional commits (e.g. `perf: Debounce and parallelize Dock preview rendering`)
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Rewrite the non-AI branch of refreshPreviews

Replace the serial loop quoted in "Current state" with a debounce + task
group. Target shape:

```swift
// Slider drags restart this task every tick — absorb the burst before
// doing any work, then render all icons concurrently.
try? await Task.sleep(for: .milliseconds(120))
if Task.isCancelled { return }

let tintColor = TintColor(tint)
let style = self.style
let intensity = self.intensity
let work = apps.compactMap { app -> (id: String, source: IconBitmap)? in
    guard let source = app.previewSource else { return nil }
    return (app.id, source)
}
await withTaskGroup(of: (String, IconBitmap?).self) { group in
    for item in work {
        group.addTask {
            (item.id, await IconStyler.render(source: item.source, style: style, tint: tintColor, intensity: intensity))
        }
    }
    for await (id, styled) in group {
        if Task.isCancelled { return }
        guard let styled else { continue }
        withAnimation(.easeInOut(duration: 0.18)) {
            previews[id] = styled
        }
    }
}
```

Notes that are load-bearing:
- The `let style` / `let intensity` locals exist so the `group.addTask`
  closures capture immutable Sendable values, not `self`.
- `work` is built on the main actor *before* the group so no `DockApp` crosses
  an isolation boundary.
- The `for await` body runs on the main actor (the method is
  MainActor-isolated), so the `previews` mutation is safe, exactly like the
  result loop in `runAIGeneration` (DockPaletteModel.swift:236–283) — that
  method is the in-repo exemplar for this pattern.
- Keep the early-return AI branch above this code unchanged.

**Verify**: Build → `** BUILD SUCCEEDED **` with zero new warnings about
Sendable/isolation (check the build log for `warning:` lines mentioning
`DockPaletteModel.swift`).

### Step 2: Automated gate

**Verify**: if `scripts/verify.sh` exists, run it → `** TEST SUCCEEDED **`.
Otherwise run the Build command → `** BUILD SUCCEEDED **`.

### Step 3: Manual verification (required — this is UI behavior)

1. `open build/Build/Products/Debug/MacBuddy.app`, switch to the Dock Palette
   tab. Expected: previews for all non-locked apps appear styled (Noir by
   default) within ~2s.
2. Drag the intensity slider back and forth for a few seconds, then release.
   Expected: UI stays responsive while dragging; within ~0.5s of pausing, all
   previews show the new intensity. No icons stuck unstyled.
3. Switch styles rapidly (Noir → Tint → Sepia → Pastel). Expected: previews
   settle on the final style; no flicker of mixed styles after settling.
4. Switch to the AI style. Expected: behavior unchanged from before this plan
   (cached AI results appear instantly; no regeneration is triggered).

Record the outcome of each check in your report.

## Test plan

The render path itself is covered indirectly: if plan 001 landed, all
existing tests must stay green. UI-timing behavior (debounce, settle) is
verified manually per step 3 — do not attempt to unit-test SwiftUI task
timing. Optional (only if trivially green): add a smoke test asserting
`IconStyler.render` returns a non-nil bitmap for an 8×8 input across all
non-AI styles, in `MacBuddyTests/IconStylerTests.swift`, reusing the
`makeBitmap()` helper pattern from `MacBuddyTests/IconStorageTests.swift`
(plan 002). If it fails for environment reasons (headless CI without a GPU
context), drop the test rather than shipping a flaky one.

## Done criteria

Machine-checkable where possible. ALL must hold:

- [ ] Build exits 0 (`** BUILD SUCCEEDED **`), no new isolation/Sendable warnings in `DockPaletteModel.swift`
- [ ] `scripts/verify.sh` exits 0 (when it exists)
- [ ] `grep -n "withTaskGroup" MacBuddy/DockPalette/DockPaletteModel.swift` shows two sites: `runAIGeneration` and `refreshPreviews`
- [ ] All four manual checks in step 3 pass, recorded in the report
- [ ] `git status --short` shows changes only in `MacBuddy/DockPalette/DockPaletteModel.swift` (plus the optional test file)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The compiler rejects the task-group code with Sendable/isolation errors you
  cannot resolve by following the "load-bearing notes" in step 1 — report the
  exact diagnostics. Do NOT mark types `@unchecked Sendable` or add
  `nonisolated(unsafe)` to make errors disappear.
- Manual check 2 shows previews failing to settle (icons stuck mid-style) —
  that indicates a cancellation/ordering bug; report rather than tune delays.
- `refreshPreviews` in the live code no longer matches the excerpt (drift).

## Maintenance notes

- The 120 ms sleep is the debounce window; if a future change makes sliders
  feel laggy, tune this constant rather than removing the task group.
- If per-app preview sizes change (currently 256 px sources from
  `DockReader.swift:35`), re-check render time per icon; the group currently
  spawns one task per app with no width limit, which is fine at ~10–40 icons
  but should get a bounded-concurrency pattern (like `runAIGeneration`'s
  `addNext()` iterator) if docks with hundreds of items ever matter.
- Reviewer focus: the AI branch must be byte-identical; cancellation must be
  checked both after the sleep and inside the result loop.
