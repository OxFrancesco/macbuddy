# Plan 001: Create a test target and verification baseline

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: this plan was written against commit `522b5f7`
> **plus uncommitted working-tree changes** (the audit covered the working
> tree). Do not rely on `git diff` against the SHA alone — instead open each
> file cited in "Current state" and confirm the excerpts match the live code.
> On any mismatch, STOP and report.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `522b5f7` (+ uncommitted working tree), 2026-06-12

## Why this matters

MacBuddy has **zero tests** — `project.yml` declares `testTargets: []` and no
test target exists. The riskiest code in the repo is pure string logic that
feeds `NSAppleScript` and generated zsh scripts (`TerminalLauncher`'s quoting
helpers): a quoting bug there mangles or mis-executes user commands. Fuzzy
matching, project naming, and the hotkey persistence codec are also pure,
cheap to test, and currently unverifiable. Every other plan in `plans/`
depends on this one because it creates the only automated way to know a
change didn't break behavior. After this plan lands, `scripts/verify.sh` is
the repo's one-command verification gate.

## Current state

- `project.yml` — XcodeGen spec; the `.xcodeproj` is generated, never edited
  directly. Lines 13–14:

  ```yaml
      scheme:
        testTargets: []
  ```

- `MacBuddy/Projects/TerminalLauncher.swift` — builds AppleScript and zsh
  launch scripts. The functions to test are all `private static` today:
  - `shellLine(directory:command:)` lines 27–30:
    ```swift
    private static func shellLine(directory: URL, command: String) -> String {
        let quotedPath = shellQuoted(directory.path(percentEncoded: false))
        return command.isEmpty ? "cd \(quotedPath)" : "cd \(quotedPath) && \(command)"
    }
    ```
  - `appleScriptQuoted(_:)` lines 55–57:
    ```swift
    private static func appleScriptQuoted(_ string: String) -> String {
        "\"" + string.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }
    ```
  - `writeLaunchScript(directory:command:)` lines 113–130 — writes a
    `#!/bin/zsh` script to the temp directory, chmod `0o755`, returns its path.
  - `shellQuoted(_:)` lines 132–134:
    ```swift
    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacing("'", with: "'\\''") + "'"
    }
    ```
- `MacBuddy/Projects/FuzzyMatcher.swift` — `nonisolated enum FuzzyMatcher`,
  `static func match(_ query: String, in candidate: String) -> Match?`
  (lines 15–44). Scoring: +1 per matched char, +8 if at index 0, +6 if the
  previous char is a separator (`- _ . space /`), +4 if consecutive with the
  previous match. Empty query returns `Match(score: 0, matchedOffsets: [])`;
  unmatched query returns `nil`.
- `MacBuddy/Projects/ProjectNamer.swift` — `suggestedName(in:)` returns the
  first free `project-N` (existing names compared lowercased);
  `createProject(named:in:)` throws `MacBuddyError.projectAlreadyExists(name)`
  if the folder exists, else creates it.
- `MacBuddy/Projects/HotKeySpec.swift` — `nonisolated struct HotKeySpec:
  Codable, Equatable, Hashable` with `keyCode: UInt32`,
  `carbonModifiers: UInt32`; `keycapLabels` emits modifiers in the order
  ⌃ ⌥ ⇧ ⌘ followed by `KeyCodeTranslator.label(for: keyCode)`.
- `MacBuddy/Projects/KeyCodeTranslator.swift` — `label(for:)` consults a fixed
  `specialKeyLabels` table first (lines 55–62: `36: "↩"`, `49: "Space"`,
  `53: "⎋"`, …), then the current keyboard layout. Only the fixed table is
  deterministic across machines — **tests must only assert special keys**.
- Repo conventions: Swift 6, project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION:
  MainActor` (types opt out with explicit `nonisolated`), 4-space indentation,
  `///` doc comments, no third-party dependencies. There are no existing tests
  to model after; use Swift Testing (`import Testing`, `@Test`, `#expect`) —
  the toolchain is Xcode 26.
- Baseline verified during planning: `xcodebuild -project MacBuddy.xcodeproj
  -scheme MacBuddy -configuration Debug -derivedDataPath build build` →
  `** BUILD SUCCEEDED **`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Regenerate project | `xcodegen generate` | exit 0, writes `MacBuddy.xcodeproj` |
| Build | `xcodebuild -project MacBuddy.xcodeproj -scheme MacBuddy -configuration Debug -derivedDataPath build build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild test -project MacBuddy.xcodeproj -scheme MacBuddy -configuration Debug -derivedDataPath build` | `** TEST SUCCEEDED **` |

Run all commands from the repo root. Note: tests are hosted in the app, so the
test run briefly launches MacBuddy.app — this is expected and harmless.

## Scope

**In scope** (the only files you should modify or create):
- `project.yml` (add test target, fill in `testTargets`)
- `MacBuddy/Projects/TerminalLauncher.swift` (visibility change ONLY — `private static` → `static` on the four helpers above; no logic changes)
- `MacBuddyTests/` (new directory: all test files)
- `scripts/verify.sh` (create)

**Out of scope** (do NOT touch):
- Any behavior in `TerminalLauncher` — if a test reveals a quoting bug, record
  it in your report; do not fix it in this plan.
- `MacBuddy/DockPalette/**` — covered by plans 002–004.
- `scripts/install.sh`, signing settings (`DEVELOPMENT_TEAM`,
  `CODE_SIGN_IDENTITY`) — the App Management TCC permission is keyed to the
  signing identity; changing these breaks the user's permission grants.

## Git workflow

- Branch: `advisor/001-test-baseline`
- Commit style: conventional commits, matching `git log` (e.g.
  `feat: Add MacBuddyTests target and verification script`)
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the test target to project.yml

In `project.yml`, change the `scheme` block of the `MacBuddy` target from
`testTargets: []` to:

```yaml
    scheme:
      testTargets:
        - MacBuddyTests
```

and add a sibling target under `targets:`:

```yaml
  MacBuddyTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: MacBuddyTests
    dependencies:
      - target: MacBuddy
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.francescooddo.macbuddy.tests
        SWIFT_VERSION: "6.0"
        SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
        SWIFT_APPROACHABLE_CONCURRENCY: YES
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Apple Development"
        DEVELOPMENT_TEAM: G2442WAF29
```

Create `MacBuddyTests/` with a placeholder `MacBuddyTests/SmokeTests.swift`:

```swift
import Testing
@testable import MacBuddy

struct SmokeTests {
    @Test func moduleImports() {
        #expect(true)
    }
}
```

**Verify**: `xcodegen generate` → exit 0; `xcodebuild -project
MacBuddy.xcodeproj -list` → output lists both `MacBuddy` and `MacBuddyTests`
under Targets. Then run the Test command → `** TEST SUCCEEDED **`.

If the test bundle fails to link with errors about the host app or
`@testable import MacBuddy`, add these two lines to the `MacBuddyTests`
settings block and regenerate (XcodeGen usually sets them automatically from
the app dependency; this is the manual fallback):

```yaml
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/MacBuddy.app/Contents/MacOS/MacBuddy
        BUNDLE_LOADER: $(TEST_HOST)
```

### Step 2: Make TerminalLauncher's helpers testable

In `MacBuddy/Projects/TerminalLauncher.swift`, change `private static func` to
`static func` for exactly these four functions: `shellLine(directory:command:)`,
`appleScriptQuoted(_:)`, `writeLaunchScript(directory:command:)`,
`shellQuoted(_:)`. Change nothing else in the file.

**Verify**: Build command → `** BUILD SUCCEEDED **`.

### Step 3: TerminalLauncher tests

Create `MacBuddyTests/TerminalLauncherTests.swift`. Cases (use raw strings
`#"..."#` to keep escapes readable):

```swift
import Foundation
import Testing
@testable import MacBuddy

struct TerminalLauncherTests {
    @Test func shellQuotedPlain() {
        #expect(TerminalLauncher.shellQuoted("plain") == "'plain'")
    }

    @Test func shellQuotedEmbeddedSingleQuote() {
        #expect(TerminalLauncher.shellQuoted("it's") == #"'it'\''s'"#)
    }

    @Test func shellQuotedNeutralizesExpansion() {
        // $(...), backticks, spaces, newlines all stay inert inside single quotes.
        #expect(TerminalLauncher.shellQuoted("a $(rm -rf ~) `x` b") == #"'a $(rm -rf ~) `x` b'"#)
        #expect(TerminalLauncher.shellQuoted("line1\nline2") == "'line1\nline2'")
    }

    @Test func appleScriptQuotedEscapesQuotesAndBackslashes() {
        #expect(TerminalLauncher.appleScriptQuoted(#"say "hi""#) == #""say \"hi\"""#)
        #expect(TerminalLauncher.appleScriptQuoted(#"back\slash"#) == #""back\\slash""#)
    }

    @Test func shellLineWithAndWithoutCommand() {
        let dir = URL(filePath: "/tmp/My Folder")
        #expect(TerminalLauncher.shellLine(directory: dir, command: "") == "cd '/tmp/My Folder'")
        #expect(TerminalLauncher.shellLine(directory: dir, command: "claude") == "cd '/tmp/My Folder' && claude")
    }

    @Test func launchScriptContents() throws {
        let dir = URL(filePath: "/tmp/My Folder")
        let path = try TerminalLauncher.writeLaunchScript(directory: dir, command: "claude")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        #expect(lines[0] == "#!/bin/zsh")
        #expect(lines[1] == "cd '/tmp/My Folder' || exit 1")
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        #expect(lines[2] == "exec \(shell) -i -l -c " + TerminalLauncher.shellQuoted("claude; exec \(shell) -i -l"))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o755)
    }

    @Test func launchScriptEmptyCommandDropsToShell() throws {
        let path = try TerminalLauncher.writeLaunchScript(directory: URL(filePath: "/tmp"), command: "")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        #expect(contents.contains("exec \(shell) -i -l"))
        #expect(!contents.contains(" -c "))
    }
}
```

**Verify**: Test command → `** TEST SUCCEEDED **`, the new tests listed as passed.

### Step 4: FuzzyMatcher tests

Create `MacBuddyTests/FuzzyMatcherTests.swift`. The expected scores below are
derived from the scoring rules in "Current state" — they are exact:

```swift
import Testing
@testable import MacBuddy

struct FuzzyMatcherTests {
    @Test func emptyQueryMatchesEverythingWithZeroScore() {
        let match = FuzzyMatcher.match("", in: "anything")
        #expect(match?.score == 0)
        #expect(match?.matchedOffsets.isEmpty == true)
    }

    @Test func unmatchedQueryReturnsNil() {
        #expect(FuzzyMatcher.match("xyz", in: "project") == nil)
        #expect(FuzzyMatcher.match("projects", in: "project") == nil) // query longer than hits
    }

    @Test func prefixAndConsecutiveBonuses() {
        // p@0: 1+8; r@1: 1+4; o@2: 1+4 → 19
        let match = FuzzyMatcher.match("pro", in: "project")
        #expect(match?.score == 19)
        #expect(match?.matchedOffsets == [0, 1, 2])
    }

    @Test func postSeparatorBonus() {
        // b@2 follows "-": 1+6 → 7
        let match = FuzzyMatcher.match("b", in: "a-b")
        #expect(match?.score == 7)
        #expect(match?.matchedOffsets == [2])
    }

    @Test func subsequenceAcrossSeparators() {
        // p@0: 9; n@8 follows "-": 7 → 16
        let match = FuzzyMatcher.match("pn", in: "project-new")
        #expect(match?.score == 16)
        #expect(match?.matchedOffsets == [0, 8])
    }

    @Test func caseInsensitive() {
        #expect(FuzzyMatcher.match("PRO", in: "Project") != nil)
    }
}
```

Note: `FuzzyMatcher.Match` has no `Equatable`; compare fields as shown, and
`match == nil` works because the function returns an optional.

**Verify**: Test command → `** TEST SUCCEEDED **`.

### Step 5: ProjectNamer tests

Create `MacBuddyTests/ProjectNamerTests.swift`. Use a unique temp directory
per test; clean up in `defer`:

```swift
import Foundation
import Testing
@testable import MacBuddy

struct ProjectNamerTests {
    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "macbuddy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func suggestsFirstFreeProjectNumber() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ProjectNamer.suggestedName(in: folder) == "project-1")
        try FileManager.default.createDirectory(at: folder.appending(path: "project-1"), withIntermediateDirectories: false)
        #expect(ProjectNamer.suggestedName(in: folder) == "project-2")
    }

    @Test func suggestionIsCaseInsensitive() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "PROJECT-1"), withIntermediateDirectories: false)
        #expect(ProjectNamer.suggestedName(in: folder) == "project-2")
    }

    @Test func createProjectCreatesAndRefusesDuplicates() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let created = try ProjectNamer.createProject(named: "alpha", in: folder)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: created.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(throws: MacBuddyError.self) {
            try ProjectNamer.createProject(named: "alpha", in: folder)
        }
    }
}
```

**Verify**: Test command → `** TEST SUCCEEDED **`.

### Step 6: HotKeySpec and KeyCodeTranslator tests

Create `MacBuddyTests/HotKeySpecTests.swift`. Only assert key labels from the
fixed `specialKeyLabels` table (layout-independent):

```swift
import Carbon
import Foundation
import Testing
@testable import MacBuddy

struct HotKeySpecTests {
    @Test func codableRoundTrip() throws {
        let spec = HotKeySpec(keyCode: 36, carbonModifiers: UInt32(cmdKey | optionKey))
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(HotKeySpec.self, from: data)
        #expect(decoded == spec)
    }

    @Test func keycapLabelsOrderAndSpecialKey() {
        let spec = HotKeySpec(keyCode: 36, carbonModifiers: UInt32(cmdKey | controlKey))
        #expect(spec.keycapLabels == ["⌃", "⌘", "↩"])
    }

    @Test func specialKeyTable() {
        #expect(KeyCodeTranslator.label(for: 36) == "↩")
        #expect(KeyCodeTranslator.label(for: 49) == "Space")
        #expect(KeyCodeTranslator.label(for: 53) == "⎋")
    }
}
```

Delete `MacBuddyTests/SmokeTests.swift` (the placeholder from step 1) and run
`xcodegen generate` again so the project picks up the final file list.

**Verify**: Test command → `** TEST SUCCEEDED **`; output shows tests from all
four test files.

### Step 7: One-command verification script

Create `scripts/verify.sh`:

```zsh
#!/bin/zsh
# One-command verification: regenerate the project, build, run all tests.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild test -project MacBuddy.xcodeproj -scheme MacBuddy \
  -configuration Debug -derivedDataPath build
```

Make it executable: `chmod +x scripts/verify.sh`.

**Verify**: `scripts/verify.sh` → exits 0, ends with `** TEST SUCCEEDED **`.

## Test plan

This plan IS the test plan — it adds ~17 tests across 4 files covering:
shell/AppleScript quoting (the injection-sensitive code), launch-script
generation, fuzzy match scoring and edge cases, project naming/collision, and
the hotkey persistence codec. There is no existing test to model after; the
files created here become the repo's pattern.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodegen generate` exits 0
- [ ] `scripts/verify.sh` exits 0 with `** TEST SUCCEEDED **`
- [ ] `xcodebuild -project MacBuddy.xcodeproj -list` shows target `MacBuddyTests`
- [ ] `git status --short` shows changes ONLY in: `project.yml`,
      `MacBuddy/Projects/TerminalLauncher.swift`, `MacBuddyTests/`,
      `scripts/verify.sh`
- [ ] `grep -n "private static func shellQuoted" MacBuddy/Projects/TerminalLauncher.swift` returns no matches
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `xcodegen` is not installed (`command -v xcodegen` fails) — report; do not
  attempt to install anything.
- The test bundle still fails to build after applying the `TEST_HOST` /
  `BUNDLE_LOADER` fallback in Step 1 (report the exact linker/compiler error).
- Any test in Steps 3–6 fails because the **production code** behaves
  differently than the expected values — that is a real finding about the
  quoting/scoring logic. Report which expectation failed and the actual value;
  do NOT change production logic to make tests pass, and do NOT weaken the
  expectation.
- The excerpts in "Current state" don't match the live files (drift).

## Maintenance notes

- Every future plan (002–005) uses `scripts/verify.sh` as its gate; keep it
  green.
- If a future change adds an Xcode target, remember `.xcodeproj` is generated:
  edit `project.yml` and re-run `xcodegen generate` — direct project edits are
  lost.
- Hosted unit tests launch the app briefly (it registers global hotkeys).
  If that ever becomes a problem in CI, split pure-logic files into a
  framework target tests can import without a host app — deferred, not needed
  now.
- Reviewer focus: the visibility changes in `TerminalLauncher.swift` must be
  visibility-only (`git diff` should show `private static func` → `static
  func` on exactly four lines).
