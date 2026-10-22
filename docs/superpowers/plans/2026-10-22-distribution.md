# Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let someone who is not the author install a working stalker with `brew install` and `stalker setup`, with no Apple Developer ID and nothing to pay.

**Architecture:** A Homebrew formula in a personal tap compiles from source on the user's own machine, so Gatekeeper never evaluates a downloaded binary. The per-user wiring a formula may not do (signing certificate, shell hook, launchd agents) moves out of `scripts/install.sh` into a new `stalker setup` subcommand. Pure decisions go in `StalkerCore` where the test harness can reach them; the `Process` calls that cannot be tested stay in the `stalker` executable target, which is where `runDoctor` already keeps its own.

**Tech Stack:** Swift 6, SwiftPM, no third-party dependencies. The hand-rolled `T` harness in `Sources/stalker-tests/`, run with `swift run stalker-tests`. Homebrew formula in Ruby.

**Spec:** `docs/superpowers/specs/2026-10-21-distribution-design.md`

## Global Constraints

- macOS 14 floor. `Package.swift` declares `platforms: [.macOS(.v14)]`; the formula declares `depends_on macos: :sonoma`.
- Zero third-party dependencies. The package links `sqlite3` directly and has no SPM dependencies. Do not add one.
- No Developer ID, no notarization, no paid service, no bottles. The source build is what makes this possible.
- **The formula must not declare `depends_on xcode:`.** That requirement is satisfied only by Xcode proper. Verified: `brew config` reports `CLT: 26.6.0.0.1781586589` and `Xcode: N/A` on a machine where `swift build` works. Homebrew already requires the Command Line Tools.
- Build inside the formula with `swift build --disable-sandbox -c release`. Homebrew's sandbox and SwiftPM's own sandboxing conflict.
- Signing identity name `stalker-dev`; sign with `-i stalker` so the designated requirement is `identifier stalker and certificate leaf = H"..."`.
- Agent label `stalker.sample`. `stalker.serve` is reserved for the serve design and is not built here.
- `stalker setup` is idempotent. Re-running it is the documented repair for almost everything.
- No network calls, no telemetry, no install counting.
- Tests use `t.eq` / `t.expect` on the `T` class and are registered by adding a call in `run()` in `Sources/stalker-tests/main.swift`. There is no XCTest.

## Review Focus

Five conditions the spec implies that no task's happy path exercises, most likely first. Each has a test pinned to the task that owns the code.

1. **`~/.zshrc` does not exist.** A friend's Mac may never have had one. `hookEdit` must produce a file rather than fail. (Task 3)
2. **`~/.zshrc` already sources the hook from a path that no longer exists.** The author's own machine points into a clone. It must be corrected in place, not duplicated. (Task 3)
3. **`setup` run twice.** The hook must not appear twice and two agents must not end up registered. (Task 3 for the hook, Task 5 for the agent)
4. **The support directory cannot be found.** If the binary moved, `setup` must fail naming every path it tried, never silently skip installing rules or the hook. (Task 3)
5. **`doctor` on a fresh install with an empty database.** The Accessibility verdict has no evidence either way and must read as "not yet observed", not `FAIL`. A first run that looks broken is the anti-goal in spec §1. (Task 2)

---

### Task 1: `stalker --version`

**Files:**
- Create: `Sources/StalkerCore/Version.swift`
- Modify: `Sources/StalkerCore/Args.swift` (add `.version` to `Command`, handle in `parseArgs`)
- Modify: `Sources/stalker/main.swift` (dispatch `.version`, add to `usage`)
- Test: `Sources/stalker-tests/main.swift` (extend `reportArgsTests`)

**Interfaces:**
- Consumes: nothing.
- Produces: `public let stalkerVersion: String` in `StalkerCore`. `Command.version`.

- [ ] **Step 1: Write the failing test**

Add to `reportArgsTests` in `Sources/stalker-tests/main.swift`:

```swift
t.eq(parseArgs(["--version"]), Command.version, "--version is its own command")
t.eq(parseArgs(["version"]), Command.version, "the bare word works too")
t.expect(!stalkerVersion.isEmpty, "a version string is defined")
t.expect(stalkerVersion.split(separator: ".").count == 3, "the version is three dot-separated parts")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: FAIL to compile, `Command.version` and `stalkerVersion` undefined.

- [ ] **Step 3: Add `stalkerVersion` and `Command.version`**

`Sources/StalkerCore/Version.swift` declares `public let stalkerVersion = "0.1.0"`. A committed constant, bumped when a release is tagged, per spec §7. Add `case version` to `Command` and the two spellings to `parseArgs`.

- [ ] **Step 4: Dispatch it in `Sources/stalker/main.swift`**

`.version` prints `stalker \(stalkerVersion)` and returns 0. Add a `stalker --version` line to `usage`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: PASS, and `swift run stalker --version` prints `stalker 0.1.0`.

- [ ] **Step 6: Commit**

```bash
git add Sources/StalkerCore/Version.swift Sources/StalkerCore/Args.swift Sources/stalker/main.swift Sources/stalker-tests/main.swift
git commit -m "feat: report a version, so a friend's bug report can be placed"
```

---

### Task 2: Accessibility reported from the database, not the calling process

Spec §5. `runDoctor` currently calls `AXIsProcessTrusted()`, which answers for the process tree's responsible process rather than the binary asking. The same signed binary reports granted under launchd and denied from a shell, so the check is wrong in the common case of a person typing `stalker doctor`.

**Files:**
- Create: `Sources/StalkerCore/GrantVerdict.swift`
- Create: `Sources/stalker-tests/GrantTests.swift`
- Modify: `Sources/stalker/main.swift:253-266` (the Accessibility block in `runDoctor`)
- Modify: `Sources/stalker-tests/main.swift` (register `grantTests(t)` in `run()`)

**Interfaces:**
- Consumes: `Interval` and `ContextKind` from `Models.swift`; `Store.intervals(from:to:)`.
- Produces:

```swift
public enum GrantVerdict: Equatable, Sendable {
    case granted(lastSeen: Int)
    case denied(lastSeen: Int)
    case notObserved
}
public func accessibilityVerdict(_ intervals: [Interval], now: Int, window: Int = 86_400) -> GrantVerdict
```

- [ ] **Step 1: Write the failing test**

`Sources/stalker-tests/GrantTests.swift`, as `@MainActor func grantTests(_ t: T)`. Give it a local `func iv(_ at: Int, _ kind: ContextKind) -> Interval` that wraps the existing `Interval(id:kind:startedAt:endedAt:bundleId:appName:contextKind:context:title:samples:active:engaged:)` initialiser, setting `startedAt` and `endedAt` to `at` and `contextKind` to `kind`.

```swift
// .title and .file can only come from Accessibility. .url may come from the
// AppleScript fallback, .cwd from the shell courier, .folder from Finder — so
// none of those three prove the grant is live.
t.eq(accessibilityVerdict([iv(1000, .title)], now: 1000), GrantVerdict.granted(lastSeen: 1000),
     "a title row proves Accessibility answered")
t.eq(accessibilityVerdict([iv(1000, .file)], now: 1000), GrantVerdict.granted(lastSeen: 1000),
     "so does a file row")
t.eq(accessibilityVerdict([iv(1000, .url)], now: 1000), GrantVerdict.notObserved,
     "a url proves nothing, the AppleScript fallback also produces it")
t.eq(accessibilityVerdict([iv(1000, .cwd)], now: 1000), GrantVerdict.notObserved,
     "nor does a cwd, which comes from the shell courier")
t.eq(accessibilityVerdict([iv(1000, .folder)], now: 1000), GrantVerdict.notObserved,
     "nor a Finder folder, which comes from AppleScript")
t.eq(accessibilityVerdict([iv(1000, .denied)], now: 1000), GrantVerdict.denied(lastSeen: 1000),
     "a denied row is a revoked grant")

// The most recent evidence decides, so a grant restored after a denial reads as granted.
t.eq(accessibilityVerdict([iv(1000, .denied), iv(2000, .title)], now: 2000),
     GrantVerdict.granted(lastSeen: 2000), "newer evidence wins over older")
t.eq(accessibilityVerdict([iv(2000, .denied), iv(1000, .title)], now: 2000),
     GrantVerdict.denied(lastSeen: 2000), "and in the other direction too")

// Review Focus 5: a fresh install has no evidence and must not read as failure.
t.eq(accessibilityVerdict([], now: 1000), GrantVerdict.notObserved,
     "an empty database is not a failure")
t.eq(accessibilityVerdict([iv(1000, .title)], now: 1_000_000), GrantVerdict.notObserved,
     "evidence older than the window is ignored")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: FAIL to compile, `accessibilityVerdict` undefined.

- [ ] **Step 3: Implement `accessibilityVerdict` in `Sources/StalkerCore/GrantVerdict.swift`**

Consider only intervals with `startedAt > now - window`. Compare the latest `startedAt` carrying `.denied` against the latest carrying `.title` or `.file`, and return whichever is newer. Neither present means `.notObserved`.

- [ ] **Step 4: Register the suite and wire it into `runDoctor`**

Add `grantTests(t)` to `run()`. In `runDoctor`, replace the `AXIsProcessTrusted()` check with one driven by `accessibilityVerdict` over `store.intervals(from: now - 86_400, to: now)`:

- `.granted` reports `ok`.
- `.denied` reports `FAIL` with the existing System Settings hint.
- `.notObserved` reports `ok` with a hint saying nothing has been observed yet and to re-run after the agent has sampled.

Keep the live `AXIsProcessTrusted()` call, relabelled `Accessibility for this process` and never counted as a problem. It explains a confusing reading rather than causing one, so print its value and a one-line note that a shell-launched check answers for the launching process.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: PASS. Then `swift run stalker doctor` reports Accessibility `ok` on this machine, where the previous check printed `FAIL`.

- [ ] **Step 6: Commit**

```bash
git add Sources/StalkerCore/GrantVerdict.swift Sources/stalker-tests/GrantTests.swift Sources/stalker-tests/main.swift Sources/stalker/main.swift
git commit -m "fix: judge Accessibility by what the agent recorded, not by who launched doctor"
```

---

### Task 3: The pure half of setup

Spec §4 steps 5 to 7, and the parts of §4 a test can reach. Everything here is a decision with no side effect, so it all lives in `StalkerCore`.

**Files:**
- Create: `Sources/StalkerCore/SetupPlan.swift`
- Create: `Sources/stalker-tests/SetupTests.swift`
- Modify: `Sources/stalker-tests/main.swift` (register `setupTests(t)`)

**Interfaces:**
- Consumes: nothing.
- Produces:

```swift
public struct AgentSpec: Equatable, Sendable {
    public let label: String
    public let templateName: String
    public init(label: String, templateName: String)
}
/// Every agent setup installs. `serve` appends one entry here and changes nothing else.
public let stalkerAgents: [AgentSpec]

public struct FileEdit: Equatable, Sendable {
    public let contents: String
    public let changed: Bool
}
public func hookEdit(zshrc: String?, hookPath: String) -> FileEdit
public func hookRemoval(zshrc: String) -> FileEdit
public func renderPlist(template: String, binaryPath: String) -> String
public func resolveSupportDir(executablePath: String, override: String?,
                              exists: (String) -> Bool) -> String?
public func supportDirCandidates(executablePath: String) -> [String]
```

- [ ] **Step 1: Write the failing test**

`Sources/stalker-tests/SetupTests.swift`, as `@MainActor func setupTests(_ t: T)`.

```swift
// Review Focus 1: a friend's Mac may have no .zshrc at all.
let fresh = hookEdit(zshrc: nil, hookPath: "/opt/share/stalker.zsh")
t.expect(fresh.changed, "a missing .zshrc is created")
t.expect(fresh.contents.contains("source \"/opt/share/stalker.zsh\""), "and sources the hook")

// Review Focus 3: setup is idempotent.
let again = hookEdit(zshrc: fresh.contents, hookPath: "/opt/share/stalker.zsh")
t.expect(!again.changed, "an already-correct .zshrc is left alone")
t.eq(again.contents, fresh.contents, "byte for byte")

// Review Focus 2: an old line pointing into a clone is corrected, not duplicated.
let stale = "# stalker courier hook\nsource \"/Users/someone/code/stalker/scripts/stalker.zsh\"\n"
let fixed = hookEdit(zshrc: stale, hookPath: "/opt/share/stalker.zsh")
t.expect(fixed.changed, "a hook pointing elsewhere is an edit")
t.expect(fixed.contents.contains("/opt/share/stalker.zsh"), "the new path is in")
t.expect(!fixed.contents.contains("/Users/someone"), "and the old one is gone")
t.eq(fixed.contents.components(separatedBy: "stalker.zsh").count - 1, 1,
     "exactly one hook line, never two")

// Unrelated .zshrc content survives both directions.
let withOther = "export EDITOR=vim\n" + stale + "alias ll='ls -l'\n"
t.expect(hookEdit(zshrc: withOther, hookPath: "/opt/share/stalker.zsh").contents
           .contains("export EDITOR=vim"), "other lines are untouched by an edit")
let removed = hookRemoval(withOther)
t.expect(removed.changed, "removal reports a change")
t.expect(!removed.contents.contains("stalker.zsh"), "the hook line is gone")
t.expect(!removed.contents.contains("# stalker courier hook"), "and its comment with it")
t.expect(removed.contents.contains("alias ll='ls -l'"), "other lines survive removal")
t.expect(!hookRemoval("export EDITOR=vim\n").changed, "removing an absent hook is no change")

// The plist template carries a placeholder the installer fills in.
let plist = renderPlist(template: "<string>__BINARY__</string>", binaryPath: "/opt/bin/stalker")
t.eq(plist, "<string>/opt/bin/stalker</string>", "the binary path is substituted")
t.expect(!plist.contains("__BINARY__"), "no placeholder survives")

// Support files are found next to the binary under brew, or in the repo from a clone.
t.eq(resolveSupportDir(executablePath: "/x/bin/stalker", override: "/given", exists: { _ in true }),
     "/given", "an explicit override wins")
t.eq(resolveSupportDir(executablePath: "/opt/homebrew/opt/stalker/bin/stalker", override: nil,
                       exists: { $0 == "/opt/homebrew/opt/stalker/share/stalker" }),
     "/opt/homebrew/opt/stalker/share/stalker", "the brew layout is found")
t.eq(resolveSupportDir(executablePath: "/repo/.build/release/stalker", override: nil,
                       exists: { $0 == "/repo/scripts" }),
     "/repo/scripts", "a clone's scripts directory is found")
// Review Focus 4: nothing found is nil, so the caller can fail loudly naming what it tried.
t.eq(resolveSupportDir(executablePath: "/x/bin/stalker", override: nil, exists: { _ in false }),
     nil, "nothing found is nil, never a silent default")
t.expect(supportDirCandidates(executablePath: "/x/bin/stalker").count >= 2,
         "more than one candidate is reported, for the error message")

// One agent today. serve adds the second without touching setup.
t.eq(stalkerAgents.count, 1, "one agent is installed today")
t.eq(stalkerAgents[0].label, "stalker.sample", "named for the tool, with no username in it")
t.eq(stalkerAgents[0].templateName, "stalker.sample.plist", "and matches the shipped template")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: FAIL to compile, none of these are defined.

- [ ] **Step 3: Implement `Sources/StalkerCore/SetupPlan.swift`**

`hookEdit` recognises an existing hook by any line containing `stalker.zsh`, so a path that has moved is rewritten in place rather than appended beside. `hookRemoval` drops that line and an immediately preceding `# stalker courier hook` comment. `supportDirCandidates` returns, in order, `<execDir>/../share/stalker` for the brew layout and `<execDir>/../../scripts` for a clone built into `.build/release`; `resolveSupportDir` returns the override if given, else the first candidate `exists` accepts, else nil.

- [ ] **Step 4: Register the suite**

Add `setupTests(t)` to `run()` in `Sources/stalker-tests/main.swift`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/StalkerCore/SetupPlan.swift Sources/stalker-tests/SetupTests.swift Sources/stalker-tests/main.swift
git commit -m "feat: decide the setup edits in testable code, apart from their side effects"
```

---

### Task 4: `stalker setup`, the filesystem and signing half

Spec §4 steps 1 to 6. The `Process` work has no seam a test can use, which is why Task 3 took the decisions out of it. Verification here is running it.

**Files:**
- Create: `Sources/stalker/Setup.swift`
- Modify: `Sources/StalkerCore/Args.swift` (add `.setup`)
- Modify: `Sources/stalker/main.swift` (dispatch, usage)
- Delete: `scripts/make-signing-cert.sh` (absorbed, per spec §2)

**Interfaces:**
- Consumes: `resolveSupportDir`, `hookEdit`, `stalkerAgents` from Task 3; `Paths.standard(home:)`.
- Produces: `func runSetup(supportDirOverride: String?) -> Int32` in the `stalker` target. `Command.setup(supportDir: String?)`.

- [ ] **Step 1: Add the command and its parsing**

`Command.setup(supportDir: String?)`, parsed from `setup` with an optional `--support-dir PATH`. Add to `usage`. Extend the arg test in `Sources/stalker-tests/main.swift`:

```swift
t.eq(parseArgs(["setup"]), Command.setup(supportDir: nil), "setup takes no arguments")
t.eq(parseArgs(["setup", "--support-dir", "/x"]), Command.setup(supportDir: "/x"),
     "and accepts an explicit support directory")
t.eq(parseArgs(["setup", "--support-dir"]), Command.usageError, "with no value it is an error")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: FAIL to compile, `Command.setup` undefined.

- [ ] **Step 3: Implement the certificate and signing steps in `Sources/stalker/Setup.swift`**

Port `scripts/make-signing-cert.sh` verbatim in behaviour: a 20-year self-signed `codeSigning` certificate named `stalker-dev` via `openssl`, imported to the login keychain with `-T /usr/bin/codesign` so signing does not prompt every time, and `security add-trusted-cert -r trustRoot -p codeSign` in the user trust domain **only if** `security find-identity -v -p codesigning` cannot already see it. Skip entirely when the identity exists. Then `codesign -f -s stalker-dev -i stalker` the binary at its own `Bundle.main.executableURL`, which under the primary specification is the one Homebrew installed.

The 20-year expiry is deliberate: this signs one local binary for one user, and an expiry landing mid-use would silently invalidate the TCC grants the certificate exists to protect.

- [ ] **Step 4: Implement the filesystem steps**

Resolve the support directory, and on nil print every path tried and return non-zero (Review Focus 4). Then create `paths.dataDir`, `paths.courierDir` and the `.config/stalker` directory; `tmutil addexclusion` the data directory; copy `rules.toml.default` to `paths.rulesPath` only when absent; and apply `hookEdit` to `~/.zshrc`, writing only when `changed`.

- [ ] **Step 5: Verify by running it**

Run: `swift build && swift run stalker setup`
Expected: exits 0. Then confirm, and these are the pass conditions:
- `security find-identity -v -p codesigning | grep stalker-dev` finds it.
- `codesign -d -r- $(swift build --show-bin-path)/stalker` prints `identifier stalker and certificate leaf = H"..."` with no `cdhash`.
- `tmutil isexcluded "$HOME/Library/Application Support/stalker"` prints `[Excluded]`.
- `grep -c stalker.zsh ~/.zshrc` prints exactly `1`, before and after a second `stalker setup` run (Review Focus 3).

- [ ] **Step 6: Bring `doctor` in line, per spec §5**

In `runDoctor` in `Sources/stalker/main.swift`:
- Add a check that `security find-identity -v -p codesigning` lists `stalker-dev`, hinting `stalker setup` when absent.
- Change every hint that still reads `run scripts/install.sh` to `run stalker setup`, because a friend installing from Homebrew has no `scripts/` directory. There are three, at `main.swift:207`, `:210`, and in the ad-hoc signature hint at `:250`.
- Leave the existing `cdhash` check alone. It already detects the one drift that matters after `brew upgrade`, which is the binary reverting to an ad-hoc signature, so it needs no new logic.
- Print `stalkerVersion` from Task 1 in the header, so a friend pasting `doctor` output says which build it was.

- [ ] **Step 7: Commit**

```bash
git add Sources/stalker/Setup.swift Sources/StalkerCore/Args.swift Sources/stalker/main.swift Sources/stalker-tests/main.swift
git rm scripts/make-signing-cert.sh
git commit -m "feat: stalker setup takes over the certificate, the directories and the hook"
```

---

### Task 5: `stalker setup`, the launchd half, and `install.sh` reduced to a wrapper

Spec §4 steps 7 to 9, and the `install.sh` decision in §2.

**Files:**
- Modify: `Sources/stalker/Setup.swift`
- Modify: `scripts/install.sh`
- Modify: `Sources/stalker-tests/main.swift:797-805` (the install-artefacts assertions)

**Interfaces:**
- Consumes: `stalkerAgents`, `renderPlist` from Task 3.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

The installer is now a wrapper, so assert that rather than its old contents. Extend the Task 15 install-artefacts block:

```swift
if let sh = try? String(contentsOfFile: repo + "/scripts/install.sh", encoding: .utf8) {
    t.expect(sh.contains("swift build -c release"), "the wrapper still builds")
    t.expect(sh.contains("stalker setup"), "and delegates the per-user half to setup")
    t.expect(!sh.contains("launchctl bootstrap"),
             "launchd wiring lives in setup now, not in two places")
    t.expect(!sh.contains("openssl"), "and so does the certificate")
} else {
    t.expect(false, "installer is readable")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: FAIL, `install.sh` still contains `launchctl bootstrap` and `openssl`.

- [ ] **Step 3: Implement the agent steps in `Sources/stalker/Setup.swift`**

For each entry in `stalkerAgents`: read its template from the support directory, `renderPlist` it with the signed binary's path, write it to `~/Library/LaunchAgents/<label>.plist`, `plutil -lint` it, `launchctl bootout "gui/<uid>/<label>"` ignoring failure, then `launchctl bootstrap`. Booting out first is load-bearing (Review Focus 3): a label left registered keeps firing on its own schedule and two samplers would write to one database.

- [ ] **Step 4: Trigger the Automation prompts, then print what is left**

Call `FinderFolderProbe().folder()` and `BrowserAppleScriptProbe().url(bundleId:)` once per entry in `browserBundleIds`, discarding results. Under launchd nobody can answer these prompts, so they have to be raised from a terminal once; this is the same trick `runDoctor` already uses for Finder. Then print the Accessibility instruction naming the exact binary path, the privacy summary from spec §8, and a pointer to `stalker doctor`.

- [ ] **Step 5: Reduce `scripts/install.sh`**

It keeps steps 1 and 2 only: `swift build -c release`, copy the binary to `$HOME/.local/bin/stalker`, then exec `"$BINARY" setup --support-dir "$REPO/scripts"`. Everything else is deleted, because it now exists once, in `setup`.

- [ ] **Step 6: Run tests and verify for real**

Run: `swift run stalker-tests` → PASS.
Run: `./scripts/install.sh` → exits 0.
Expected, and these are the pass conditions:
- `launchctl print gui/$UID/stalker.sample` reports `program = ...` and a `state`.
- Running `./scripts/install.sh` a second time still leaves exactly one registered agent and one hook line.
- After two minutes, `sqlite3 "$HOME/Library/Application Support/stalker/stalker.db" "select max(id) from interval;"` has advanced.

- [ ] **Step 7: Add the agent check to `doctor`, per spec §5**

For each entry in `stalkerAgents`, check `launchctl print gui/<uid>/<label>` exits zero, and report with a hint naming `stalker setup` when it does not. An agent is now something that can be silently dead, so it needs a check. It reports and hints and never bootstraps anything itself, which is the rule every other check in `runDoctor` follows and which the serve design settled independently.

- [ ] **Step 8: Commit**

```bash
git add Sources/stalker/Setup.swift scripts/install.sh Sources/stalker/main.swift Sources/stalker-tests/main.swift
git commit -m "feat: setup owns the launchd agents, install.sh becomes a build wrapper"
```

---

### Task 6: `stalker uninstall`

Spec §6. A trial needs a visible exit or people will not start one.

**Files:**
- Modify: `Sources/stalker/Setup.swift`
- Modify: `Sources/StalkerCore/Args.swift`
- Modify: `Sources/stalker/main.swift`
- Test: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `hookRemoval`, `stalkerAgents` from Task 3.
- Produces: `func runUninstall(purge: Bool) -> Int32`. `Command.uninstall(purge: Bool)`.

- [ ] **Step 1: Write the failing test**

```swift
t.eq(parseArgs(["uninstall"]), Command.uninstall(purge: false), "uninstall keeps data by default")
t.eq(parseArgs(["uninstall", "--purge"]), Command.uninstall(purge: true), "--purge opts into deletion")
t.eq(parseArgs(["uninstall", "--wat"]), Command.usageError, "an unknown flag is an error")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: FAIL to compile, `Command.uninstall` undefined.

- [ ] **Step 3: Implement `runUninstall(purge:)`**

The reverse of Task 5 then Task 4: boot out every agent and delete its plist, apply `hookRemoval` to `~/.zshrc`, delete the signed binary. Keep the database **and** `rules.toml` unless `purge`, printing where each was left. Keep the certificate, since removing it needs a keychain prompt to achieve nothing. A missing file at any step is not an error, because uninstall must work on a half-finished install.

Finish by printing `brew uninstall stalker`, which this cannot do for itself, and the System Settings path for removing the Accessibility entry, which nothing but a person can revoke.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: PASS.

- [ ] **Step 5: Verify the round trip**

Run: `swift run stalker uninstall`, then `./scripts/install.sh`.
Expected: uninstall leaves `launchctl print gui/$UID/stalker.sample` reporting no such service and `grep -c stalker.zsh ~/.zshrc` printing `0`, the database still present, and the reinstall returns to a working agent. Run `stalker uninstall` twice in a row and confirm the second is still exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/stalker/Setup.swift Sources/StalkerCore/Args.swift Sources/stalker/main.swift Sources/stalker-tests/main.swift
git commit -m "feat: stalker uninstall, keeping the database and the rules by default"
```

---

### Task 7: The formula

Spec §3. The canonical formula lives here so it is reviewed and tested with the code; the tap repository holds a copy.

**Files:**
- Create: `packaging/stalker.rb`
- Test: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: the `setup` command from Tasks 4 and 5.
- Produces: nothing in code.

- [ ] **Step 1: Write the failing test**

Assert the constraints that are easy to regress and expensive to discover on someone else's Mac:

```swift
if let f = try? String(contentsOfFile: repo + "/packaging/stalker.rb", encoding: .utf8) {
    // depends_on xcode: is satisfied only by Xcode proper, which would push a friend
    // into a multi-gigabyte download for a toolchain Homebrew already requires.
    t.expect(!f.contains("depends_on xcode"), "no Xcode dependency is declared")
    t.expect(f.contains("depends_on macos:"), "the macOS floor is declared")
    t.expect(f.contains("--disable-sandbox"),
             "swift build runs with the sandbox off, or Homebrew's own sandbox fights SwiftPM")
    t.expect(f.contains("stalker setup"), "the caveats tell the user the one remaining step")
    t.expect(f.contains("head "), "a --HEAD install is offered, for friends tracking main")
    for name in ["rules.toml.default", "stalker.zsh", "stalker.sample.plist"] {
        t.expect(f.contains(name), "the formula installs \(name)")
    }
} else {
    t.expect(false, "formula is readable")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: FAIL, "formula is readable".

- [ ] **Step 3: Write `packaging/stalker.rb`**

A standard formula: `desc`, `homepage` and `url` pointing at `https://github.com/RahulZoroItachi/stalker`, `license`, `head`, `depends_on macos: :sonoma`, an `install` block running `swift build --disable-sandbox -c release` and installing the binary plus the three support files into `pkgshare`, and a `caveats` block whose only instruction is to run `stalker setup`. No `bottle` block and no `depends_on xcode`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: PASS.

- [ ] **Step 5: Verify the formula actually builds**

This needs the repository published first, which is a prerequisite recorded in spec §3: push `stalker` under `RahulZoroItachi`, merge to `main`, and tag. Then create the `homebrew-stalker` repository, copy `packaging/stalker.rb` to `Formula/stalker.rb`, and run:

```bash
brew tap RahulZoroItachi/stalker
brew install --build-from-source RahulZoroItachi/stalker/stalker
brew audit --strict --formula RahulZoroItachi/stalker/stalker
```

Expected: installs cleanly on a machine with Command Line Tools and no Xcode, and `brew audit` reports no errors.

- [ ] **Step 6: Settle spec §10, the open item**

The one question the design could not answer: whether a TCC Accessibility grant survives the binary's path changing. Grant Accessibility to `/opt/homebrew/opt/stalker/bin/stalker`, confirm `stalker doctor` reports `granted` from Task 2, then bump the version, re-tag, `brew upgrade stalker`, and `stalker setup`. Wait for the agent to sample and read the verdict again.

- `granted` means the stable symlink is enough and the primary specification stands.
- `denied` means the grant is path-keyed. Implement the §10 fallback: `setup` copies the binary to a fixed path under the data directory, points the agent there, and `doctor` gains the version comparison between the two copies that §10 specifies.

Record the answer in spec §10 either way, replacing the open item.

- [ ] **Step 7: Commit**

```bash
git add packaging/stalker.rb Sources/stalker-tests/main.swift docs/superpowers/specs/2026-10-21-distribution-design.md
git commit -m "feat: a homebrew formula that builds from source, needing no developer id"
```

---

### Task 8: The readme

Spec §8. The hard half of this project is asking a friend to grant Accessibility, which lets a program read the window contents of every app they run, to a tool a friend of theirs wrote.

**Files:**
- Create: `README.md`
- Test: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: every command from Tasks 1 through 7.
- Produces: nothing in code.

- [ ] **Step 1: Write the failing test**

The readme drifting away from the commands that exist is the regression worth catching:

```swift
if let r = try? String(contentsOfFile: repo + "/README.md", encoding: .utf8) {
    t.expect(r.contains("brew install RahulZoroItachi/stalker/stalker"), "the install command is given")
    t.expect(r.contains("stalker setup"), "and the second step")
    t.expect(r.contains("stalker uninstall"), "and the way out, which a trial needs")
    t.expect(r.contains("rules.toml"), "and the first thing to edit")
    t.expect(r.contains("Accessibility"), "the permission is named, not glossed")
    t.expect(r.contains("14") || r.lowercased().contains("sonoma"), "the macOS floor is stated")
} else {
    t.expect(false, "readme is readable")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: FAIL, "readme is readable".

- [ ] **Step 3: Write `README.md`**

Lead with the privacy ask, before the install instructions, covering the four points in spec §8: what it records (frontmost app, a URL or working directory or window title, whether input is idle, every 30 seconds); where it goes (one SQLite file under `~/Library/Application Support/stalker`, on their machine); what never happens (no network calls, no telemetry, no account, no upload); and why Accessibility specifically, including what refusing it costs, which is that browsers still work through the AppleScript fallback while apps like Slack lose their context entirely.

Then the two install commands, then editing `rules.toml` as the first thing to do, with the reason: the shipped path rules are a guess, and until they point at the user's own directories most of their time files under the default category. Then `stalker report`, `stalker note`, `stalker doctor`, and `stalker uninstall`. State the macOS 14 floor and that the first install compiles and so takes a few minutes.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add README.md Sources/stalker-tests/main.swift
git commit -m "docs: a readme that earns the accessibility grant before asking for it"
```
