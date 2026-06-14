# Plan 003: Validate image URLs returned by fal.ai before fetching them

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: this plan was written against commit `522b5f7`
> **plus uncommitted working-tree changes**. Open `MacBuddy/DockPalette/FalClient.swift`
> and confirm the excerpt below matches lines ~119–132. On mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-test-target-and-verification-baseline.md
- **Category**: security
- **Planned at**: commit `522b5f7` (+ uncommitted working tree), 2026-06-12

## Why this matters

`FalClient` parses JSON responses from fal.ai and then fetches whatever URL
string the response contains, with no scheme or host validation.
`URLSession.shared.data(from:)` happily loads `file://` URLs, so a compromised
or spoofed response could make MacBuddy read arbitrary local files (and a
non-HTTPS URL would fetch over cleartext). The blast radius is small — the
bytes only become a dock icon — but the fix is one guard, and this code runs
with an unsandboxed app's full file access. Defense in depth: accept only the
`data:` URIs that `sync_mode: true` normally returns, and `https:` URLs.

## Current state

- `MacBuddy/DockPalette/FalClient.swift` — `nonisolated enum FalClient`, a
  minimal client for `https://fal.run/<model-id>`. Both `editImage` (line 73)
  and `removeBackground` (line 111) extract an image URL string from response
  JSON and pass it to the private helper at lines 119–132:

  ```swift
  private static func imageData(from urlString: String) async throws -> Data {
      if urlString.hasPrefix("data:") {
          guard let comma = urlString.firstIndex(of: ","),
                let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])) else {
              throw FalError(message: "Couldn't decode the generated image payload.")
          }
          return data
      }
      guard let url = URL(string: urlString) else {
          throw FalError(message: "Invalid image URL in fal.ai response.")
      }
      let (data, _) = try await URLSession.shared.data(from: url)
      return data
  }
  ```

- Error convention in this file: `throw FalError(message: "…")` with a
  user-readable sentence (see `FalError` at lines 8–11).
- Callers validate the fetched bytes decode as an image
  (`CGImageSourceCreateWithData` guards at lines 74–77 and 112–115), and the
  AI pipeline re-renders results through a fresh `CGContext`
  (`AIIconStylist.composedIcon`), so byte-content validation is already
  adequate — only the *fetch destination* is unchecked.
- Test target `MacBuddyTests` exists (plan 001). Tests are hosted in the app.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Regenerate project | `xcodegen generate` | exit 0 |
| Full gate | `scripts/verify.sh` | `** TEST SUCCEEDED **`, exit 0 |

## Scope

**In scope**:
- `MacBuddy/DockPalette/FalClient.swift` (the `imageData(from:)` helper only)
- `MacBuddyTests/FalClientTests.swift` (create)

**Out of scope** (do NOT touch):
- Request building, model-specific body shaping, timeouts, or error-message
  parsing in `FalClient` — behavior must stay byte-identical for valid
  responses.
- `FalKeyStore.swift` — key storage is keychain-backed and correct as is.
- `AIIconStylist.swift`, `DockPaletteModel.swift`.
- Do NOT add a host allowlist (e.g. "only fal.media"). fal.ai's CDN hosts are
  not documented/stable; a wrong allowlist breaks the feature. Scheme
  validation only.

## Git workflow

- Branch: `advisor/003-falclient-url-validation`
- Conventional commits (e.g. `fix: Reject non-HTTPS image URLs in fal.ai responses`)
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Enforce https on fetched response URLs and make the helper testable

In `FalClient.swift`, change `imageData(from:)` from `private static` to
`static` (internal, so the test target can reach it) and add a scheme guard
after the `URL(string:)` guard:

```swift
static func imageData(from urlString: String) async throws -> Data {
    if urlString.hasPrefix("data:") {
        guard let comma = urlString.firstIndex(of: ","),
              let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])) else {
            throw FalError(message: "Couldn't decode the generated image payload.")
        }
        return data
    }
    guard let url = URL(string: urlString) else {
        throw FalError(message: "Invalid image URL in fal.ai response.")
    }
    guard url.scheme?.lowercased() == "https" else {
        throw FalError(message: "Refusing non-HTTPS image URL in fal.ai response.")
    }
    let (data, _) = try await URLSession.shared.data(from: url)
    return data
}
```

No other lines in the file change.

**Verify**: `xcodebuild -project MacBuddy.xcodeproj -scheme MacBuddy
-configuration Debug -derivedDataPath build build` → `** BUILD SUCCEEDED **`.

### Step 2: Unit tests

Create `MacBuddyTests/FalClientTests.swift`. All cases below complete without
network access — the rejections throw before any fetch, and `data:` URIs
decode locally:

```swift
import Foundation
import Testing
@testable import MacBuddy

struct FalClientTests {
    @Test func dataURIDecodes() async throws {
        let payload = Data("hello".utf8)
        let uri = "data:image/png;base64,\(payload.base64EncodedString())"
        let decoded = try await FalClient.imageData(from: uri)
        #expect(decoded == payload)
    }

    @Test func malformedDataURIThrows() async {
        await #expect(throws: FalClient.FalError.self) {
            _ = try await FalClient.imageData(from: "data:image/png;base64")     // no comma
        }
        await #expect(throws: FalClient.FalError.self) {
            _ = try await FalClient.imageData(from: "data:image/png;base64,@@@") // invalid base64
        }
    }

    @Test func nonHTTPSSchemesAreRejected() async {
        for bad in ["http://example.com/icon.png",
                    "file:///etc/hosts",
                    "ftp://example.com/icon.png"] {
            await #expect(throws: FalClient.FalError.self) {
                _ = try await FalClient.imageData(from: bad)
            }
        }
    }

    @Test func unparseableURLThrows() async {
        await #expect(throws: FalClient.FalError.self) {
            _ = try await FalClient.imageData(from: "")
        }
    }
}
```

**Verify**: `scripts/verify.sh` → `** TEST SUCCEEDED **`, the 4 new tests pass.

## Test plan

Covered by step 2: `data:` happy path, two malformed `data:` variants,
`http`/`file`/`ftp` rejection, unparseable string. Model after the plan-001
test files. No test performs a real network fetch — keep it that way.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `scripts/verify.sh` exits 0 with `** TEST SUCCEEDED **`
- [ ] `grep -n "https" MacBuddy/DockPalette/FalClient.swift` shows the new scheme guard in `imageData`
- [ ] `git status --short` shows changes only in `MacBuddy/DockPalette/FalClient.swift` and `MacBuddyTests/FalClientTests.swift`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `MacBuddyTests` doesn't exist (plan 001 not landed).
- The `imageData(from:)` excerpt doesn't match the live code (drift).
- A test fails for a reason other than your own typo after one fix attempt —
  in particular, if `URL(string: "")` does NOT return nil on this toolchain,
  report the actual behavior instead of bending the test.

## Maintenance notes

- If fal.ai responses ever legitimately need another scheme (unlikely), the
  guard's error message will surface it immediately in the generation status —
  that's intended.
- Manual end-to-end check after merge (needs a FAL key): generate one icon in
  the Dock Palette AI style; generation should succeed exactly as before.
- Reviewer focus: confirm `imageData`'s visibility change (`private static` →
  `static`) is the only API surface change.
