# Distribution (`brew install`, `stalker setup`) — Design

Date: 2026-10-21
Status: design approved in conversation, pending spec review
Builds on: `2026-09-29-activity-tracker-design.md`, `2026-10-01-manual-activity-logging-design.md`
Interacts with: `2026-10-21-serve-design.md` (see §9)

## 1. Purpose

There is no way to give this to anyone. `scripts/install.sh` assumes a git clone
and assumes it stays: the `~/.zshrc` hook sources `$REPO/scripts/stalker.zsh` by
absolute path, and the launchd agent runs a binary copied out of `.build`. A friend
would have to clone the repo, keep it forever, and know not to move it.

This adds an install path for people who are not the author. A Homebrew formula in
a personal tap, plus a `stalker setup` command that does the per-user wiring the
formula is not allowed to do.

The hard constraint is that it must cost nothing and involve no Apple account. No
Developer ID, no notarization, no paid anything. That single constraint decides the
channel, and §2 records how.

Success criteria:

- A friend gets a working tracker from two commands, neither of which needs an
  Apple account.
- Accessibility, once granted, stays granted. Including across a `brew upgrade`.
- `doctor` tells the truth about every permission, whatever process launched it.
- A friend can remove everything, including the things `brew uninstall` cannot see.
- A friend can tell what the tool records, and where it goes, before granting
  anything.
- The author's own install keeps working, from a clone, in one command.

Non-goals: no cask, no prebuilt binaries, no notarization, no app bundle, no menu
bar item, no auto-update, no Linux. Not the public `homebrew-core`, which this is
nowhere near ready for and which would not accept a tool needing Accessibility.

Anti-goal: a friend who grants Accessibility, sees `doctor` print `FAIL` next to it,
and concludes the tool is broken. That is worse than not shipping, because it spends
the trust the permission ask needs and returns nothing.

## 2. Scope decisions

Settled in conversation, with reasons, so they are not re-litigated.

| Decision | Choice | Why |
|---|---|---|
| Channel | Homebrew **formula** in a personal tap | the formula compiles on the user's own machine, so the binary is never downloaded, so Gatekeeper never evaluates it. Nothing needs notarizing and nothing costs money. |
| Not a cask | rejected | a cask downloads a prebuilt artifact, which arrives quarantined and needs notarization to launch cleanly. This is precisely the route the no-Developer-ID constraint forbids, and it was the original assumption going in. |
| Toolchain dependency | Command Line Tools, no Xcode | verified on a machine with `xcode-select -p` at `/Library/Developer/CommandLineTools` and no Xcode: Swift 6.3.3 is present and builds this package. Homebrew already requires the CLT, so this costs a friend nothing. |
| No bottles | source build only, for now | a bottle is a prebuilt binary, which reintroduces the signing question the source build avoids. Not ruled out later, because §4 re-signs on the user's machine regardless of how the binary arrived, but it needs CI that does not exist. |
| Signing | a per-machine self-signed certificate, created by `setup` | this is what stands in for a Developer ID, and it is already proven in this repo. An ad-hoc signature's designated requirement is the code hash, so every rebuild is a new program to TCC while System Settings still reads as enabled. Measured: 152 `denied` context rows between 30 Sep and 1 Oct, and zero in the 20 days after the certificate landed on 7 Oct. |
| Install split | `brew` does what is identical on every Mac, `stalker setup` does the rest | forced, not stylistic. A formula must not edit `~/.zshrc`, must not bootstrap launchd agents, and must not prompt for a keychain password, and the current `install.sh` does all three. |
| `setup` is interactive | yes, and that is the point | it is the only place a keychain prompt and an Accessibility instruction can honestly live. |
| Agent wiring | `setup` installs and boots the agents without asking first | the stated audience will push through anything short of impossible, so they want it working, not interviewing them. `uninstall` is the way back out. |
| Agent list | `setup` drives a list of agents, never hardcoded labels | `serve` adds a second agent. A list means it slots in. See §9. |
| `install.sh` | kept, reduced to a thin wrapper that builds then calls `setup` | a contributor from a clone still wants one command, and the per-user logic must not exist twice. |
| `make-signing-cert.sh` | absorbed into `setup`, script deleted | a friend will not find or run a second script, and the logic is identical. |
| Binary the agent runs | a path that does not change between versions | the Cellar path contains the version number, so it changes on every upgrade. Whether a TCC grant survives that is **unverified**. See §10. |
| Upgrade story | re-run `setup` after `brew upgrade`, and `doctor` detects the drift | predictable and self-diagnosing beats a grant that may or may not have survived. A friend should never have to wonder. |
| `doctor`'s Accessibility check | report what the **agent** observed, not what the current process can see | verified: `AXIsProcessTrusted()` answers for the process tree's responsible process, not always the binary asking. The same signed binary reported granted under launchd and denied when run from a shell in this session. The live check stays, relabelled, because it is still true about that process. |
| Default rules | shipped by `brew`, copied by `setup`, an existing file never overwritten | current behaviour, worth preserving explicitly. |
| Default path rules | generic `*/Work/*` and `*/Projects/*`, commented as a guess to edit | they previously keyed off one person's home directory, so a friend's path time would all have fallen through to the default category. Already corrected. |
| Uninstall | `stalker uninstall`, database kept unless `--purge` | a trial needs a visible exit, or people will not start. Deleting someone's history by default is the one unrecoverable thing here. |
| Version | `stalker --version`, from a committed constant bumped at tag time | there is no version flag today, so a friend's report cannot be placed against a build. |
| `--HEAD` support | the formula declares a `head` URL | the point of this release is fast iteration against friends' feedback, and `brew install --HEAD` lets a willing friend track `main` without a tag per fix. |

## 3. The tap and the formula

Two public GitHub repositories under `RahulZoroItachi`, neither of which exists yet:
`stalker` itself, and `homebrew-stalker` holding `Formula/stalker.rb` and nothing
else. Both must be public, because `brew install` from a private tap would make every
friend authenticate. Friends then run:

```
brew install RahulZoroItachi/stalker/stalker
stalker setup
```

Prerequisites, since the repository is today a single local branch with no remote and
no tags: push `stalker`, merge the work to `main`, and cut the first tag. The
identifying data that was baked into the test fixtures has already been replaced, so
publishing is no longer blocked on it.

The formula:

- `depends_on macos: :sonoma` or newer, matching `platforms: [.macOS(.v14)]` in
  `Package.swift`. Stated, so an older Mac fails at install with a clear reason
  rather than mid-compile.
- **No Xcode dependency is declared.** `depends_on xcode:` is satisfied only by
  Xcode proper, so declaring it would push a friend into a multi-gigabyte download
  for a toolchain they already have. Verified on the reference machine: `brew config`
  reports `CLT: 26.6.0.0.1781586589` and `Xcode: N/A`, and `swift build` works there.
  Homebrew already requires the CLT, so the dependency is implicit and stating it
  would be actively harmful.
- Builds with `swift build --disable-sandbox -c release`. The flag is required:
  Homebrew's build sandbox and SwiftPM's own sandboxing conflict. The package has
  no dependencies, so the build needs no network.
- Installs the executable, plus `rules.toml.default`, `stalker.zsh`, and both plist
  templates into the formula's share directory. `setup` reads them from there, which
  is how the `~/.zshrc` hook stops pointing into somebody's clone.
- `caveats` says exactly one thing: run `stalker setup`.
- Architecture needs no special handling. Compiling on the target machine produces
  whatever that machine is, so Apple Silicon and the Intel Macs that run Sonoma are
  both covered for free.

Releases are a git tag plus a formula `sha256` bump, done by hand. At this scale
automation would be the larger task.

## 4. `stalker setup`

The per-user half of today's `install.sh`, moved into Swift so it ships with the
binary instead of with a clone. Idempotent, safe to re-run, and re-running it is
the documented fix for almost everything.

In order:

1. Find or create the `stalker-dev` code signing certificate, doing what
   `make-signing-cert.sh` does today: a 20-year self-signed `codeSigning`
   certificate via `openssl`, imported to the login keychain with `-T` scoped to
   `/usr/bin/codesign`, and marked trusted in the user trust domain only if
   `codesign` cannot already see it.
2. Sign the installed binary in place, at the stable path from §10, with that
   certificate and `-i stalker`, so its designated requirement becomes
   `identifier stalker and certificate leaf = H"..."` instead of a code hash. Under
   the primary specification this means signing the binary Homebrew installed, inside
   the Cellar it owns. `brew upgrade` replaces that file with a fresh ad-hoc one,
   which is the condition re-running `setup` exists to repair.
3. Create the data and config directories and the courier directory.
4. Exclude the data directory from Time Machine.
5. Install `rules.toml` if absent, leaving an existing one untouched.
6. Add the hook line to `~/.zshrc`, sourcing `stalker.zsh` from the formula's share
   directory, and recognise an existing line pointing at an old location so a
   migrating install is corrected rather than duplicated.
7. For each agent in the list: render the plist from its template, `plutil -lint`
   it, boot out the old label explicitly, bootstrap the new one. Booting out the old
   label is load-bearing, or two samplers run at once.
8. Trigger the Automation prompts that launchd has nobody to answer, one per
   AppleScript target, which is what `doctor` already does for Finder today.
9. Print the remaining manual step, which is the Accessibility grant, naming the
   exact path to add. Then print the privacy summary from §8 and point at `doctor`.

Steps 1, 2, 6 and 7 are the ones a formula may not do, and they are why this command
exists.

## 5. `doctor`

`doctor` is the only thing a friend has to diagnose with, so its honesty is the
feature. Changes:

- **Accessibility, rewritten.** The current check calls `AXIsProcessTrusted()` and
  reports on the calling process. That answer depends on what launched the process,
  which makes it wrong in the common case of a person typing `stalker doctor`. The
  authoritative check reads recent rows instead and reports whether the agent is
  recording `denied` as a context kind. The agent is the thing that needs the grant,
  and the database is the record of whether it has it. The live call stays, worded as
  being about this process, because it explains a confusing `FAIL` rather than
  causing one.
- **Upgrade drift.** Under the primary specification there is only one binary, so
  the drift after `brew upgrade` is that it has reverted to an ad-hoc signature. The
  existing `cdhash` check already detects exactly that, so it needs no new logic,
  only a hint that now reads "run `stalker setup`". A version comparison between two
  binaries is needed solely under the §10 fallback, and is specified there.
- **Signature.** Assert the certificate exists and that the agent's binary names it
  in its designated requirement. The existing `cdhash` check already catches the
  ad-hoc case and stays as it is.
- **Agents.** Each agent in the list is registered. Reported, with a hint, never
  bootstrapped. This matches the rule already settled in the serve design.
- **Hints.** Every "run `scripts/install.sh`" becomes "run `stalker setup`", because
  a friend has no `scripts/` directory.

## 6. `stalker uninstall`

Removes what `brew uninstall` cannot see, in the reverse order of §4: boot out every
agent and delete its plist, remove the hook line from `~/.zshrc`, delete the signed
binary at the stable path, and delete the directories.

- The database is **kept** unless `--purge` is passed, and the command prints where
  it was left. So is `rules.toml`, for the same reason: a friend may have spent real
  time tuning it, and a tuned rules file is not the installer's to throw away.
- The certificate is kept, since it is harmless and removing it needs a keychain
  prompt to do nothing useful.
- Finishes by printing `brew uninstall stalker`, because this command cannot and
  should not do that itself.
- It cannot revoke the TCC grants. Nothing can, except a person in System Settings.
  So it prints where to go and remove the entry.

## 7. `stalker --version`

A committed constant, bumped when a release is tagged, printed by `--version` and
included in `doctor`'s output. SwiftPM has no version mechanism, and generating one
at build time would mean the formula patching a source file, which is more moving
parts than a constant that is already wrong in the same way a forgotten tag is.

## 8. The readme, and the privacy ask

The packaging is the easy half. The hard half is that this asks a friend to grant
Accessibility, which lets a program read the window contents of every app they run,
to a tool a friend of theirs wrote. The readme has to earn that in plain words,
before the install instructions:

- The first thing to do after installing, which is to edit `rules.toml`. The two
  path rules in the shipped defaults are a guess at a directory layout, and until a
  friend points them at their own directories most of their time files under the
  default category. This is the single most likely reason a friend's first report
  looks useless, so it belongs in the readme rather than being discovered.
- What it records: frontmost app, a URL or working directory or window title, and
  whether input is idle. Sampled every 30 seconds.
- Where it goes: one SQLite file under `~/Library/Application Support/stalker`, on
  their machine.
- What never happens: no network calls, no telemetry, no account, no upload. The
  `serve` page in the companion design is deliberately script-free, which is worth
  saying out loud here.
- Why Accessibility specifically, and what refusing it costs: browsers still work
  through the AppleScript fallback, and apps like Slack lose their context entirely.

Also stated: the macOS 14 floor, that the first build takes a few minutes because it
compiles, and that `stalker uninstall` exists.

## 9. Relationship to the serve design

`2026-10-21-serve-design.md` §6 assigns `install.sh` four jobs: install both agents,
rename `stalker.sample` to `stalker.sample`, print the URL to bookmark,
and gain a `doctor` check for a dead server. This design moves all of that into
`setup`, so whichever lands first, the installer logic is written once.

If this design lands first, `serve` adds one entry to `setup`'s agent list, one
plist template to the formula, and one check to `doctor`, and touches nothing else.
That is the reason §2 specifies a list rather than named labels. The label rename is
specified in the serve design and happens wherever the agent wiring lives at the
time.

## 10. Open items

One, and it is the only thing in this design that is not settled.

**Does a TCC Accessibility grant survive the binary's path changing?** It decides
where §4 step 2 puts the binary, and getting it wrong means every friend re-grants
Accessibility on every upgrade, which is the exact failure this project already hit
once and already fixed once.

The primary specification is `/opt/homebrew/opt/stalker/bin/stalker`, the stable
per-formula symlink, which does not change between versions even though the Cellar
path behind it does. The grant is given to that path and the agent runs that path.

**Implemented, and by decision rather than by luck.** `Bundle.main.executableURL`
does not resolve symlinks, which was verified: a binary invoked through a symlink
reports the symlink's own path. So typing `stalker` happens to arrive at
`/opt/homebrew/bin/stalker`, which is stable, but an invocation through a Cellar path
would have arrived as one and pinned both the agent and the `~/.zshrc` hook to a
version directory `brew cleanup` deletes. `setup` therefore rewrites a Cellar path to
the `opt` path (`canonicalBrewPath`), falling back to the original when
`opt/<formula>` is absent, as it is for an unlinked formula (`stableBinaryPath`).
Both branches were exercised against a simulated Cellar layout.

This could not be tested in the design conversation. Reading the TCC database needs
Full Disk Access, and the obvious shortcut of granting a binary and re-running it
from a new path does not work, because a shell-launched check reports on the
responsible process rather than the binary, which is the same finding that drove §5.
Testing it needs a real grant and a real version bump, with the result read out of
the database as a `denied` row or its absence, exactly as §5 specifies.

Fallback if the grant does not survive: `setup` copies the binary to a private fixed
path under the data directory and points the agent there. The cost is a second copy
whose version can lag the formula's, so the fallback adds one `doctor` check that
compares the two and says to re-run `setup`. The design is complete under either
answer, which is why this is an open item rather than a blocker.

## 11. Out of scope

No cask, no bottles, no notarization, no Developer ID, no `homebrew-core`
submission. No auto-update and no update check, since `brew` is the update
mechanism. No GUI installer, no app bundle, no `.pkg`. No telemetry, including any
count of how many friends installed it, which would contradict §8. No Intel-specific
work and no cross-compilation, both of which the source build makes unnecessary.
No migration tooling for the author's existing install beyond what step 6 and step 7
of §4 already handle.
