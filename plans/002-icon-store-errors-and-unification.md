# Plan 002: Stop swallowing icon-store I/O errors and unify the persistence plumbing

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: this plan was written against commit `522b5f7`
> **plus uncommitted working-tree changes**. Open each file cited in
> "Current state" and confirm the excerpts match the live code. On any
> mismatch, STOP and report.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/001-test-target-and-verification-baseline.md
- **Category**: bug + tech-debt
- **Planned at**: commit `522b5f7` (+ uncommitted working tree), 2026-06-12

## Why this matters

AI icon generations cost minutes and real API money per icon, and the three
stores that persist them swallow every disk error with `try?`. If a write
fails (disk full, permissions, sandbox path issues), the app tells the user
"Generated N icons" or "Saved collection" while nothing reached disk — the
icons silently vanish on relaunch. Separately, `IconCollectionStore.save`
skips icons whose PNG encoding fails but still lists them in the manifest, so
a loaded collection can report phantom icons. The same SHA256-naming +
directory-creation + PNG encode/decode plumbing is copy-pasted across three
files, which is why the error handling diverged in the first place. This plan
extracts one shared `IconStorage` helper, makes failures propagate, and
surfaces persistence failures in the existing status message.

## Current state

- `MacBuddy/DockPalette/GeneratedIconStore.swift` — persists the latest AI
  icon per app. Lines 12–16 (both `try?` swallow failures; caller can't tell):

  ```swift
  static func save(_ bitmap: IconBitmap, forAppAt path: String) {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let rep = NSBitmapImageRep(cgImage: bitmap.image)
      try? rep.representation(using: .png, properties: [:])?.write(to: cacheURL(forAppAt: path))
  }
  ```

  Lines 31–35 — the SHA256 cache-URL helper duplicated in all three stores:

  ```swift
  private static func cacheURL(forAppAt path: String) -> URL {
      let digest = SHA256.hash(data: Data(path.utf8))
      let name = digest.map { String(format: "%02x", $0) }.joined()
      return directory.appending(path: "\(name).png")
  }
  ```

- `MacBuddy/DockPalette/OriginalIconStore.swift` — caches pristine icons
  before styling. Lines 15–25: same `try?` pattern on `createDirectory` and
  the PNG write inside `ensureCached(appPaths:styledPaths:)`. Same
  `cacheURL(forAppAt:)` helper at lines 38–42.
- `MacBuddy/DockPalette/IconCollectionStore.swift` — named snapshots, one
  folder per collection (`manifest.json` + PNGs). Lines 57–69 inside `save`:

  ```swift
  do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for (path, bitmap) in icons {
          let rep = NSBitmapImageRep(cgImage: bitmap.image)
          guard let png = rep.representation(using: .png, properties: [:]) else { continue }
          try png.write(to: iconURL(in: folder, appPath: path))
      }
      let manifest = Manifest(name: name, prompt: prompt, createdAt: createdAt, appPaths: icons.keys.sorted())
      try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
  } catch {
      try? FileManager.default.removeItem(at: folder)
      return nil
  }
  ```

  The bug: the `guard … else { continue }` skips a failed PNG encode, but the
  manifest still lists **all** `icons.keys` — manifest and files drift apart.
  Same SHA256 helper at lines 102–106 (`iconURL(in:appPath:)`).
- `MacBuddy/DockPalette/DockPaletteModel.swift` — the only caller that matters:
  - Line 268 (inside `runAIGeneration`, on each success):
    `GeneratedIconStore.save(bitmap, forAppAt: path)` — result ignored.
  - Lines 288–297 build the end-of-run status message from
    `succeeded` / `failures` and call `withAnimation { statusMessage = … }`.
  - Lines 404–407 (`loadCollection`): `GeneratedIconStore.deleteAll()` then a
    loop of `GeneratedIconStore.save(bitmap, forAppAt: path)` — results ignored.
  - Line 385 (`saveCollection`): already handles `IconCollectionStore.save`
    returning `nil` by setting `statusMessage = "Couldn't save the collection."`.
- `MacBuddy/DockPalette/IconBitmap.swift` — `nonisolated struct IconBitmap:
  @unchecked Sendable { let image: CGImage }`.
- Conventions: all three stores are `enum` namespaces with `static` members;
  `OriginalIconStore`/`GeneratedIconStore` are implicitly MainActor (project
  default), `IconCollectionStore`'s `IconCollection` struct is `nonisolated`.
  4-space indent, `///` doc comments. **There is no logging anywhere in the
  repo today** — this plan introduces `os.Logger` as the convention.
- Test target `MacBuddyTests` and `scripts/verify.sh` exist (created by plan
  001). If they don't, STOP — plan 001 has not landed.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Regenerate project | `xcodegen generate` | exit 0 |
| Full gate | `scripts/verify.sh` | `** TEST SUCCEEDED **`, exit 0 |

## Scope

**In scope** (the only files you should modify or create):
- `MacBuddy/DockPalette/IconStorage.swift` (create)
- `MacBuddy/DockPalette/GeneratedIconStore.swift`
- `MacBuddy/DockPalette/OriginalIconStore.swift`
- `MacBuddy/DockPalette/IconCollectionStore.swift`
- `MacBuddy/DockPalette/DockPaletteModel.swift` (only `runAIGeneration` and
  `loadCollection`, as specified in steps 4–5)
- `MacBuddyTests/IconStorageTests.swift` (create)

**Out of scope** (do NOT touch):
- `DockIconApplier.swift` — writing icons onto app bundles is a different
  mechanism with its own verification/rollback; already handled.
- The store APIs' *call shapes* beyond what steps 3–5 specify — e.g. do not
  convert stores to protocols/classes or add dependency injection.
- UI files (`DockPaletteControls`, `IconCollectionsPopover`, …).
- `FalClient.swift` / `AIIconStylist.swift` — plan 003 territory.

## Git workflow

- Branch: `advisor/002-icon-store-errors`
- Conventional commits (e.g. `fix: Propagate icon persistence failures to the UI`)
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create the shared IconStorage helper

Create `MacBuddy/DockPalette/IconStorage.swift`:

```swift
import AppKit
import CryptoKit
import os

/// Shared plumbing for the icon stores: Application Support directories,
/// SHA256-keyed PNG filenames, and PNG encode/decode. Failures are thrown so
/// callers can surface them — the stores must not silently lose icons.
nonisolated enum IconStorage {
    static let log = Logger(subsystem: "dev.francescooddo.macbuddy", category: "IconStorage")

    enum StorageError: LocalizedError {
        case pngEncodingFailed

        var errorDescription: String? {
            "Couldn't encode the icon as PNG."
        }
    }

    /// `~/Library/Application Support/MacBuddy/<name>`.
    static func directory(named name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "MacBuddy/\(name)", directoryHint: .isDirectory)
    }

    /// Stable PNG filename for an app path: SHA256 hex + ".png".
    static func hashedPNGName(forAppPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    /// Encodes and writes the bitmap, creating the parent directory if needed.
    static func writePNG(_ bitmap: IconBitmap, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rep = NSBitmapImageRep(cgImage: bitmap.image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw StorageError.pngEncodingFailed
        }
        try png.write(to: url)
    }

    /// Reads a PNG back as an IconBitmap, nil if missing or unreadable.
    static func readBitmap(at url: URL, pixelSize: Int) -> IconBitmap? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return IconRenderer.bitmap(from: image, pixelSize: pixelSize)
    }
}
```

Run `xcodegen generate` so the new file joins the target.

**Verify**: build via `xcodebuild -project MacBuddy.xcodeproj -scheme MacBuddy
-configuration Debug -derivedDataPath build build` → `** BUILD SUCCEEDED **`.

### Step 2: Route the three stores through IconStorage

- `GeneratedIconStore`: replace the `directory` computed property body with
  `IconStorage.directory(named: "GeneratedIcons")`; replace `cacheURL`'s body
  with `directory.appending(path: IconStorage.hashedPNGName(forAppPath: path))`;
  rewrite `save` as:

  ```swift
  /// Returns false when the icon couldn't be persisted (the in-memory result
  /// still works for this session, but won't survive relaunch).
  @discardableResult
  static func save(_ bitmap: IconBitmap, forAppAt path: String) -> Bool {
      do {
          try IconStorage.writePNG(bitmap, to: cacheURL(forAppAt: path))
          return true
      } catch {
          IconStorage.log.error("Couldn't persist generated icon for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
          return false
      }
  }
  ```

  and replace `bitmap(forAppAt:)`'s body with
  `IconStorage.readBitmap(at: cacheURL(forAppAt: path), pixelSize: 1024)`.
- `OriginalIconStore`: same `directory`/`cacheURL` replacement (directory name
  `"OriginalIcons"`). In `ensureCached`, replace the two `try?` writes with a
  `do { try IconStorage.writePNG(…) } catch { IconStorage.log.error(…) }`
  per app (keep iterating — a single failed snapshot must not stop the rest).
  Remove the now-unneeded standalone `createDirectory` call (`writePNG`
  creates it). In `originalBitmap(forAppAt:pixelSize:)`, replace the
  `NSImage(contentsOf:)` + `IconRenderer.bitmap` pair with
  `IconStorage.readBitmap(at:pixelSize:)`, keeping the live-icon fallback.
- `IconCollectionStore`: replace `iconURL(in:appPath:)`'s hash code with
  `folder.appending(path: IconStorage.hashedPNGName(forAppPath: appPath))`;
  in `save`, replace the encode-and-write pair with
  `try IconStorage.writePNG(bitmap, to: iconURL(in: folder, appPath: path))` —
  this **deletes the `guard … else { continue }`**, so a failed encode now
  throws, hits the existing `catch`, cleans up the folder, and returns `nil`
  (the manifest can no longer drift from the files). Replace the
  `NSImage`+`IconRenderer` pairs in `icons(for:)` and `thumbnails(for:limit:pixelSize:)`
  with `IconStorage.readBitmap(at:pixelSize:)` (keep the `compactMap`/`continue`
  behavior there — missing icons in a *load* should skip, not fail).
- Remove `import CryptoKit` from any store that no longer uses it.

**Verify**: `scripts/verify.sh` → `** TEST SUCCEEDED **` (plan-001 tests still
pass; nothing else changed behavior).

### Step 3: Surface persistence failures in the AI-run status message

In `DockPaletteModel.runAIGeneration` (currently lines 225–301): add
`var persistFailures = 0` next to the existing counters. At the success branch
(line 266–268 today):

```swift
case .success(let bitmap):
    succeeded += 1
    aiResults[path] = bitmap
    hasUnsavedAIResults = true
    if !GeneratedIconStore.save(bitmap, forAppAt: path) {
        persistFailures += 1
    }
```

After the existing failure sentence in the summary block (lines 288–294),
append:

```swift
if persistFailures > 0 {
    parts.append("\(persistFailures) \(persistFailures == 1 ? "icon" : "icons") couldn't be saved to disk and won't survive a relaunch.")
}
```

**Verify**: build succeeds; `grep -n "persistFailures" MacBuddy/DockPalette/DockPaletteModel.swift`
shows both the counter and the message.

### Step 4: Surface persistence failures when loading a collection

In `DockPaletteModel.loadCollection` (currently lines 398–430), replace the
write-back loop:

```swift
GeneratedIconStore.deleteAll()
var persistFailures = 0
for (path, bitmap) in icons {
    if !GeneratedIconStore.save(bitmap, forAppAt: path) {
        persistFailures += 1
    }
}
```

and, where the status `parts` are assembled at the end of the function, add:

```swift
if persistFailures > 0 {
    parts.append("\(persistFailures) couldn't be saved as the working set.")
}
```

**Verify**: build succeeds.

### Step 5: Unit tests for IconStorage

Create `MacBuddyTests/IconStorageTests.swift`:

```swift
import AppKit
import Foundation
import Testing
@testable import MacBuddy

struct IconStorageTests {
    private func makeBitmap() -> IconBitmap {
        let ctx = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return IconBitmap(image: ctx.makeImage()!)
    }

    @Test func hashedNameIsStableHexPNG() {
        let name = IconStorage.hashedPNGName(forAppPath: "/Applications/Safari.app")
        #expect(name == IconStorage.hashedPNGName(forAppPath: "/Applications/Safari.app"))
        #expect(name.hasSuffix(".png"))
        #expect(name.count == 64 + 4) // 64 hex chars + ".png"
        #expect(name != IconStorage.hashedPNGName(forAppPath: "/Applications/Mail.app"))
    }

    @Test func writeAndReadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "macbuddy-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "icon.png")
        try IconStorage.writePNG(makeBitmap(), to: url)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        let read = IconStorage.readBitmap(at: url, pixelSize: 8)
        #expect(read != nil)
    }

    @Test func readMissingOrGarbageReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "macbuddy-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(IconStorage.readBitmap(at: dir.appending(path: "missing.png"), pixelSize: 8) == nil)
        let garbage = dir.appending(path: "garbage.png")
        try Data("not a png".utf8).write(to: garbage)
        #expect(IconStorage.readBitmap(at: garbage, pixelSize: 8) == nil)
    }

    @Test func writeToUnwritableLocationThrows() {
        // Root of the read-only system volume — createDirectory must fail.
        let url = URL(filePath: "/System/macbuddy-test-\(UUID().uuidString)/icon.png")
        #expect(throws: (any Error).self) {
            try IconStorage.writePNG(makeBitmap(), to: url)
        }
    }
}
```

(`IconBitmap` comparison isn't possible — assert non-nil; `readBitmap` runs
through `IconRenderer.bitmap(from:pixelSize:)` which is the production path.)

**Verify**: `scripts/verify.sh` → `** TEST SUCCEEDED **` including the 4 new tests.

## Test plan

- New: `MacBuddyTests/IconStorageTests.swift` (step 5) — hash stability,
  write/read round-trip, nil on missing/garbage, throw on unwritable path.
- Model after the plan-001 test files (same `struct` + `@Test` + `#expect`
  style, temp-dir-per-test with `defer` cleanup).
- The store-level behavior (status message wording) is exercised manually:
  not unit-testable without refactoring `DockPaletteModel`, which is out of
  scope (see plans/README.md, deferred god-object finding).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `scripts/verify.sh` exits 0 with `** TEST SUCCEEDED **`
- [ ] `grep -rn "try? rep.representation" MacBuddy/DockPalette/` returns no matches
- [ ] `grep -rn "SHA256" MacBuddy/DockPalette/ --include="*.swift" -l` returns only `IconStorage.swift`
- [ ] `grep -c "else { continue }" MacBuddy/DockPalette/IconCollectionStore.swift` — the PNG-encode `continue` in `save` is gone (the loads in `icons(for:)`/`thumbnails` may still skip)
- [ ] `git status --short` shows changes only in the in-scope file list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `MacBuddyTests` or `scripts/verify.sh` doesn't exist (plan 001 not landed).
- The excerpts in "Current state" don't match the live code (drift — in
  particular if `DockPaletteModel.runAIGeneration` or `loadCollection` have
  been restructured).
- Changing `GeneratedIconStore.save`'s signature breaks callers other than
  the two named in steps 3–4 (`grep -rn "GeneratedIconStore.save" MacBuddy/`
  should show exactly those two call sites; if there are more, report them).
- `IconStorage.writePNG`'s isolation causes compile errors at the store call
  sites (the stores are MainActor by project default, `IconStorage` is
  `nonisolated` — if the compiler objects, report the exact diagnostic rather
  than sprinkling `await`/`nonisolated` ad hoc).

## Maintenance notes

- `IconStorage` is now the single place for icon persistence policy — future
  features (compression, alternate formats, cache eviction) belong there.
- The `os.Logger` subsystem `dev.francescooddo.macbuddy` introduced here is
  the repo's first logging; reuse it (new categories per module) rather than
  `print`.
- Reviewer focus: `IconCollectionStore.save` must now be all-or-nothing
  (manifest written only if every PNG wrote), and `loadCollection` /
  `runAIGeneration` must still update UI state identically when nothing fails.
- Deferred: making the stores' root directory injectable for store-level unit
  tests — revisit if the stores grow logic beyond pathing + IconStorage calls.
