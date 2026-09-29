# Activity Tracker — Design

Date: 2026-09-29
Status: design approved, pending spec review
Platform: macOS 26.5.1 (Darwin 25.5.0), Apple silicon

## 1. Purpose

A local tracker that answers, for every 30-minute block of the day, **what I was
doing** — with enough detail to classify each block as work, pet-project, fun, or
whatever categories I add later.

Success criteria:

- I can look at yesterday and see a truthful 30-minute-by-30-minute account.
- Time I was not actually at the machine is not counted as activity.
- Time spent watching a video is counted as watching a video, not as idle.
- When I change my mind about what counts as work, the whole history re-classifies.
- It costs so little CPU and battery that I never think about it.

Non-goals: no cloud sync, no cross-device, no team features, no screenshots,
no keystroke logging, no blocking or nagging.

## 2. Scope decisions

Settled during brainstorming, with reasons, so they are not re-litigated:

| Decision | Choice | Why |
|---|---|---|
| Attention proxy | keyboard focus only | I do not background videos; focus is where my hands are |
| Secondary displays | not tracked separately | follows from the above |
| Context permission | **Accessibility** | one grant covers every app incl. Electron; per-app AppleScript adapters cannot see Slack and are permanent maintenance |
| URL granularity | **host + path**, query strings and fragments stripped at collection | query strings carry tokens, search terms, session IDs and add nothing to classification |
| Terminal attribution | **shell hook** (option C) | Ghostty exposes no tty/cwd to AppleScript; this is the only exact route |
| Storage shape | **intervals**, not raw samples | classification keys on (app, context), which intervals preserve exactly |
| Classification timing | **read time**, never write time | so new rules fix all history |
| Screen Time DB | not used | needs Full Disk Access, undocumented, restructured between releases, no URLs |
| Audio attribution | power assertions, not CoreAudio | assertions land on the main app pid; audio lands on a detached helper |
| Build vs wrap | build | ActivityWatch's Mac watcher is frontmost-only and its data model fights the classifier, which is the actual product |

## 3. Verified feasibility

Every mechanism below was probed on this machine. Numbers are measured, not estimated.

**Free, no permission:**

- `NSWorkspace.frontmostApplication` → app name + bundle id
- `CGEventSource.secondsSinceLastEventType(.hidSystemState, ~0)` → idle seconds.
  Confirmed to be the *union* of input types: `ANY` tracked `min(individual)` on
  every sample. Scroll (`scrollWheel`) and cursor movement (`mouseMoved`) each
  reset it. Cross-checked against `ioreg` HIDIdleTime — agreed to 0.2 s.
- `IOPMCopyAssertionsByProcess` → per-pid power assertions
- `kAudioHardwarePropertyProcessObjectList` → per-process audio output (backup signal)
- Shell `cwd` via process tree, and via the shell hook
- `tmutil addexclusion` → works without sudo

**Confirmed present but blocked until granted:**

- Accessibility: `AXIsProcessTrusted()` returned false; all 11 apps' focused-window
  titles returned `nil`. One checkbox in System Settings unblocks it.

**Confirmed working, already granted:**

- Automation to Chrome and Edge. Chrome returned a live doc URL; Edge returned a
  YouTube URL. Per-app AppleScript to Finder/TextEdit/Notes also reachable —
  their errors were semantic (`-1728`, `-600`, `-1719`), never `-1743`.
- Ghostty responds to Cocoa scripting: `name of front window`, `properties of
  front window` (exposes tabs and selected tab). It does **not** expose tty,
  working directory, or path.

**Measured while a video played in Edge:**

```
frontmost: Microsoft Edge, idle 8.6s
AUDIO   com.microsoft.edgemac.helper pid=2974 producing output
ASSERT  Microsoft Edge [pid 1958] NoIdleSleepAssertion    "Playing audio"
ASSERT  Microsoft Edge [pid 1958] NoDisplaySleepAssertion "Video Wake Lock"
```

**Dead ends, confirmed:**

- `AVAudioSession` — compiler-enforced unavailable on macOS; iOS-only, and even
  there describes only the calling process.
- `knowledgeC.db` (Screen Time) — authorization denied, and holds no URLs.
- `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` — returns only the
  *current Space*. On this machine it saw 2 windows while 130+ existed. Using it
  would have produced a near-empty dataset that looked like a classifier bug.
- `optionAll` — returns 130+ entries including `1x1` phantoms, `1728x33` menubar
  strips, and helpers (`CursorUIViewService`, `AutoFill`, `SentinelAgent`).
  Use `NSWorkspace.runningApplications` filtered to `.regular` instead — it
  returned a clean 11-app list.
- Reading another process's environment — blocked by the OS. No UUID join
  available between Ghostty's focused tab and a shell pid.

## 4. Architecture

Three components. One binary with subcommands, plus a shell snippet.

```
 ┌──────────────┐  push, 0.06ms   ┌──────────────────┐
 │ zsh hook     │────────────────>│ shell/ttys00N    │  courier: 1 line,
 │ preexec/chpwd│                 │ (overwritten)    │  overwritten, 16K total
 └──────────────┘                 └────────┬─────────┘
                                           │ pull, every 30s
 ┌───────────────────────────────────────── ▼ ────────┐
 │ stalker sample   (launchd agent, 30s StartInterval) │
 │   focus · idle · engagement · context               │
 └───────────────────────────┬─────────────────────────┘
                             │ INSERT on open, UPDATE on bump
                   ┌─────────▼──────────┐
                   │ stalker.db         │  THE ARCHIVE. append-only,
                   │ interval table     │  permanent, no categories
                   └─────────┬──────────┘
                             │ read
        ┌────────────────────▼─────────────────┐   ┌──────────────┐
        │ stalker report                       │<──│ rules.toml   │
        │ 30-min buckets + category breakdown  │   │ (your rules) │
        └──────────────────────────────────────┘   └──────────────┘
```

The shell never touches SQLite. The sampler is the only writer, so there is no
multi-writer locking to handle.

Implementation language: Swift. The required APIs (`NSWorkspace`, `AXUIElement`,
`CoreAudio`, `IOKit.pwr_mgt`, `CGEventSource`) are all native, and `swiftc` is
present via Command Line Tools. No third-party dependencies.

## 5. Collection

### 5.1 Cadence

**30 seconds.** Report granularity is 30 minutes, so 60 samples per bucket is
already far more resolution than is ever displayed. 10 s would triple the Apple
Events for precision that gets averaged away. Config value; changeable.

### 5.2 The tick

```
1. frontmost app        → bundle_id, app_name, pid          (~0.1 ms)
2. input_idle_secs      → CGEventSource, ANY event type     (~0.1 ms)
3. screen locked?       → CGSessionCopyCurrentDictionary()
                          ["CGSSessionScreenIsLocked"]
4. if input_idle_secs > IDLE_THRESHOLD:
       engagement check (see 5.4) — only reached here, so it is free
       in normal use. Its result decides kind = 'app' vs 'idle'.
5. capture context (see 5.3) if EITHER:
       - kind == 'app'                  (normal case, every tick), or
       - this tick is the TRANSITION into 'idle'   (capture once)
   otherwise skip — while idle continues, nothing can have changed.
6. reconcile with the open interval (see 6.3)
```

Step 5 is skipped while idle. This is information-preserving, not lossy: with no
input, focus and URL cannot change. Context is captured **once on entering idle**
so the record still shows what was on screen. The one case that breaks the
guarantee is auto-advancing content (a playlist changing URL with no input) —
accepted, as it does not apply to this user.

### 5.3 Context capture — three tiers

| Tier | Mechanism | Covers | Yields |
|---|---|---|---|
| 1 | Accessibility | most apps | `AXURL` → browser URL; `kAXDocument` → file path; `kAXTitle` of focused window → everything else |
| 2 | Shell courier | terminals | focused shell's `cwd` |
| 3 | App identity | PWAs, Electron | nothing extra — the app name *is* the context |

Tier 2 exists because AX cannot identify which terminal tab is focused. Tier 3 is
a freebie: `Google Meet`, `Gmail`, `Google Calendar` register as separate apps.

**Tier 1 details.** Set `AXUIElementSetMessagingTimeout` to 1 s. AX is synchronous
IPC into the target app, so an app with a blocked main thread hangs the call
without it. On timeout or `nil`, record the app with `context_kind = NULL` and
continue. If `AXIsProcessTrusted()` is false, record `context_kind = 'denied'`.

AppleScript remains a fallback for browsers only, with `with timeout of 2 seconds`,
used if AX consistently returns `nil` for a known browser.

**URL normalisation.** Strip scheme, query string, and fragment at collection.
`https://docs.google.com/document/d/1Wkw.../edit?tab=t.0` is stored as
`docs.google.com/document/d/1Wkw.../edit`.

**Tier 2 details.** The zsh hook, builtins only — no subprocess:

```zsh
zmodload zsh/datetime
_stalker() { print -r -- "$EPOCHSECONDS $PWD" > ~/Library/Application\ Support/stalker/shell/${TTY:t} }
autoload -Uz add-zsh-hook
add-zsh-hook preexec _stalker
add-zsh-hook chpwd   _stalker
```

Measured at **0.0587 ms** per command. The naive `sqlite3` version measured
4.91 ms — 84x slower and noticeable at the prompt.

The sampler reads every file in `shell/` and takes the one with the **newest
timestamp** as the focused shell's cwd. This is the attribution rule; it replaces
the tty-focus API macOS does not offer. Known failure mode: running a quick
command in one directory while a long command runs in another flips attribution
until the next command. Bounded, occasional, and visible in the report.

Stale courier files (from closed terminals) are ignored if older than 24 h.

### 5.4 Idle and engagement

Terminology: `input_idle_secs` is the raw reading from `CGEventSource`.
`kind = 'idle'` is the *conclusion*, which additionally requires that nothing is
playing. They are not the same thing and the code should not share a name for them.

```
kind = 'idle'  =  input_idle_secs > IDLE_THRESHOLD
         AND frontmost pid holds no NoDisplaySleepAssertion
         AND frontmost pid holds no NoIdleSleepAssertion named "Playing audio"
```

`IDLE_THRESHOLD` default **180 s**. Safe because scroll and cursor movement both
count as input (verified), so 3 minutes of nothing genuinely means hands off.

The engagement check **must be scoped to the frontmost app's pid.** Probing found
five permanent system assertions (`powerd`, `coreaudiod`, `caffeinate`,
WindowServer's `UserIsActive`); an unscoped check would report engagement 24/7.

Backup signal, if assertions ever prove unreliable: per-process audio output via
`kAudioProcessPropertyIsRunningOutput`, attributed by **bundle-id prefix**
(`com.microsoft.edgemac.helper` → `com.microsoft.edgemac`). Not by `ppid` — the
ppid walk failed on the real audio helper, which Chromium launches detached.

## 6. Storage

### 6.1 Layout

```
~/Library/Application Support/stalker/
├── stalker.db          SQLite, WAL. permanent archive. Time Machine-excluded.
└── shell/
    ├── ttys000         courier. one line, overwritten, never grows.
    └── ttys001

~/.config/stalker/
└── rules.toml          your rules. hand-edited, safe to git.

~/Library/LaunchAgents/
└── stalker.sample.plist
```

Config and data are separated deliberately: `rules.toml` is hand-owned and
version-controllable, `stalker.db` is machine-owned and never hand-edited.

### 6.2 Schema

```sql
CREATE TABLE interval (
  id           INTEGER PRIMARY KEY,
  kind         TEXT    NOT NULL,  -- 'app' | 'idle' | 'locked' | 'gap'
  started_at   INTEGER NOT NULL,  -- unix seconds
  ended_at     INTEGER NOT NULL,  -- bumped in place while unchanged
  bundle_id    TEXT,              -- com.google.Chrome
  app_name     TEXT,              -- Google Chrome  (required for PWAs)
  context_kind TEXT,              -- 'url'|'cwd'|'file'|'folder'|'title'|'denied'|NULL
  context      TEXT,              -- docs.google.com/...  or  ~/Work/PM_Assistant
  title        TEXT,
  samples      INTEGER NOT NULL,  -- ticks in this interval
  active       INTEGER NOT NULL,  -- of those, how many had input
  engaged      INTEGER NOT NULL   -- of those, how many had video/audio playing
);
CREATE INDEX ix_interval_time ON interval(started_at);

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);  -- schema_version, etc.
```

**There is no `category` column, by design.** Categories are computed at read
time so that a rule added in March re-classifies January.

`context_kind = 'denied'` is distinct from `NULL`. `NULL` means the app has no
context to read; `'denied'` means the permission was refused. Collapsing them
would make a revoked Accessibility grant silently indistinguishable from normal
operation.

The three counters characterise a block in a way a single duration cannot:

```
samples=60 active=51 engaged=0    → typing. real work.
samples=60 active=2  engaged=58   → watched a video. real fun.
samples=60 active=1  engaged=0    → left it open and walked away. count nothing.
```

### 6.3 Interval lifecycle

The interval **key** is `(kind, bundle_id, context)`.

- Key unchanged → `UPDATE` the open row: bump `ended_at`, increment `samples`,
  and `active` / `engaged` as applicable.
- Key changed → `UPDATE` the open row's final `ended_at`, then `INSERT` a new one.

`INSERT` happens at open, not at close, and each tick `UPDATE`s. A killed sampler
therefore loses at most one tick, not the whole open interval.

Expected volume: ~400 rows/day at roughly 200 bytes — **under 30 MB/year.**

### 6.4 Gap detection

On every tick, and on startup:

```
if now - last_row.ended_at > 2 * SAMPLE_PERIOD:
    close the open interval at its last known ended_at
    INSERT a 'gap' row covering the span
```

Without this, closing the lid at 18:00 and opening it at 09:00 produces one
fifteen-hour interval of whatever was last in focus. `gap` rows are also the only
way a dead sampler is distinguishable from a quiet afternoon.

## 7. Classification

### 7.1 rules.toml

```toml
default = "unclear"

[[rule]]
app = "com.google.Chrome"
category = "work"

[[rule]]
app = "com.microsoft.edgemac"
category = "fun"

[[rule]]
app_name = "Google Meet"        # PWA bundle ids are opaque install-specific
category = "work"               # hashes — match on name instead

[[rule]]
context = "*/Casey/Work/*"      # app-independent: covers terminal cwd,
category = "work"               # Finder folders, and open documents alike

[[rule]]
context = "*/Casey/Projects/*"
category = "pet-project"
```

A rule has an optional `app` (bundle id), an optional `app_name`, an optional
`context` glob, and a required `category`. `category` is a free string, not an
enum, so new categories need no migration.

`app_name` matching is required because PWA bundle ids are unreadable and
reinstall-fragile — verified: `Google Meet` is
`com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan`.

Because Meet/Gmail/Calendar are separate apps, `Chrome = work` does **not** cover
them; they need their own rules. This is desirable — Meet is work regardless of
which browser launched it.

Glob matching uses `fnmatch(3)` from libc. No custom matcher, no dependency.

**Parsing.** A hand-rolled parser for the exact subset above: `key = "value"`
lines, `[[rule]]` array-of-table headers, `#` comments. ~40 lines, no
dependency. The supported subset is exactly what is shown; anything else is an
error rather than silently ignored. If the rule language ever outgrows this,
swap in a real TOML library then.

### 7.2 Precedence

Most specific wins, by tier. Within a tier, file order.

| Tier | Matches on |
|---|---|
| 1 | app (or app_name) **and** context |
| 2 | context only |
| 3 | app (or app_name) only |

Auto-sorting by tier means rules cannot be broken by being written in the wrong
order — the usual footgun of first-match-wins lists.

### 7.3 Unmatched time

Anything unmatched is `unclear` — never guessed into work or fun. A tracker that
quietly guesses flatters you, which defeats the purpose.

## 8. Reporting

`stalker report [--today | --date YYYY-MM-DD]`

Intervals are sliced at 30-minute boundaries; an interval spanning a boundary
contributes to each bucket in proportion to its overlap.

```
09:30 ─ 10:00   work          Ghostty  ~/Work/PM_Assistant
10:00 ─ 10:30   fun           Edge     youtube.com/watch
10:30 ─ 11:00   work          Chrome   docs.google.com/document/...
11:00 ─ 11:30   idle          —

TOTALS
  work          5h 10m
    docs.google.com/document           2h 05m
    ~/Work/Analytics_Personalisation   1h 40m
    youtube.com/watch                    40m      <- drift, worth a rule
  fun           1h 20m
  pet-project     35m
  unclear         45m   (write rules for these)
    com.tinyspeck.slackmacgap            30m
    com.apple.Notes                      15m
  idle          1h 05m
  gap             20m   <- no data: sampler down or machine asleep
```

Two deliberate features of this output:

- **Per-category context breakdown.** `Chrome = work` is a habit, not a fact. The
  breakdown surfaces `youtube.com/watch` sitting inside `work` so the drift is
  visible rather than hidden inside a flattering total.
- **Ranked `unclear`.** The report doubles as a to-do list for rules, ordered by
  how much time each gap is costing. The rule file grows on demand instead of
  requiring an upfront taxonomy.

## 9. Failure modes

| Failure | Symptom | Detection |
|---|---|---|
| Sampler dies | no rows written | `gap` rows |
| Machine sleeps | no rows written | `gap` rows (same path) |
| Accessibility revoked | context unreadable | `context_kind = 'denied'` |
| App main thread blocked | AX call would hang | 1 s messaging timeout; `context_kind = NULL` |
| Browser busy | AppleScript would hang | 2 s timeout; app still recorded |
| Terminal closed | stale courier file | ignored if older than 24 h |
| `frontmostApplication` nil (login/logout) | no app to record | treated as `gap` |
| Rule file malformed | silent misclassification | parse errors are fatal and reported, never skipped |

## 10. Performance budget

Measured on this machine.

| Item | Cost |
|---|---|
| AppleScript → Chrome URL | 90 ms |
| AX call | unverified — expected 1–5 ms |
| SQLite insert (in-process) | ~0.05 ms |
| SQLite insert (`sqlite3` spawn) | 12.3 ms — avoided |
| zsh hook | 0.0587 ms per command |
| `lsof` tree walk | 561 ms — **avoided entirely** by the shell hook |
| frontmost + idle | ~0.2 ms |

Daily totals at 30 s cadence (2,880 ticks):

```
with AppleScript   ~137 CPU-seconds/day   = 0.16% of one core
with AX (expected)  ~12 CPU-seconds/day   = 0.014% of one core
```

The 137 figure assumes a browser is frontmost for roughly half of all ticks
(1,440 x 90 ms + 1,440 x 5 ms). Heavier browser use scales it toward 260
CPU-seconds/day; lighter use toward 15. The AX figure is insensitive to this,
which is a further argument for making AX primary.

For scale, `JamfDaemon` on this machine averages 27.9% of a core — about
24,100 CPU-seconds/day, or ~175x the AppleScript figure.

Battery, bounded rather than measured: 137 CPU-seconds at a generous 5 W is
~0.19 Wh/day, roughly 0.3% of a ~70 Wh battery. Nothing runs while asleep.

## 11. Privacy

- Entirely local. No network code in the binary at all.
- Query strings and fragments are dropped at collection, never written to disk.
- `stalker.db` is excluded from Time Machine at install via `tmutil addexclusion`
  (verified to work without sudo; sets
  `com.apple.metadata:com_apple_backup_excludeItem`).
- `Application Support` is never iCloud-synced. `Desktop & Documents` sync is
  currently off on this machine.
- No screenshots, no keystroke content, no window contents. Window *titles* are
  stored, which can incidentally include document names.

## 12. Install

1. Build: `swiftc -O src/*.swift -o ~/.local/bin/stalker`
2. `mkdir -p "$HOME/Library/Application Support/stalker/shell" ~/.config/stalker`
3. `tmutil addexclusion "$HOME/Library/Application Support/stalker"`
   (note: `"~/..."` inside double quotes does **not** expand — use `$HOME`)
4. Write the default `rules.toml`
5. Add the zsh hook to `~/.zshrc`
6. Install and load `~/Library/LaunchAgents/stalker.sample.plist`
   (`StartInterval` 30)
7. Grant Accessibility to the `stalker` binary in System Settings → Privacy &
   Security → Accessibility
8. `stalker doctor` — verifies each permission, times an AX call, confirms the
   courier directory is writable, and confirms the Time Machine exclusion

Note on permissions: the launchd binary gets its **own** grants. Automation
approval already held by Ghostty does not transfer. Expect one Accessibility
prompt and, if the AppleScript fallback is ever used, one Automation prompt per
browser.

## 13. Open items

Carried forward deliberately; none blocks implementation.

1. **AX call latency is unverified** — needs the permission granted. The whole
   cost profile depends on it. Time it in step 8 of install. If AX turns out
   slower than AppleScript's 90 ms, revisit tier 1's primary mechanism.
2. **Whether AX exposes Slack's channel.** Slack is Electron; its AX title may
   read only "Slack". If it yields the channel, Slack context comes free. The
   agreed scope is app-level Slack, so this is upside, not a requirement.
3. **Whether AX exposes more of Ghostty than AppleScript does.** Ghostty renders
   via Metal, so its AX tree is likely near-empty. If it surprises us, tier 2
   could be simplified or dropped.
4. **Chrome's 90 ms AppleScript cost with more than 21 tabs** — untested, and
   irrelevant if AX is primary.

## 14. Out of scope

Explicitly not built, to keep the first version small:

- Multi-display attribution (keyboard focus is the agreed proxy)
- Raw per-sample log (intervals lose nothing that classification needs)
- Screen Time DB import (locked, undocumented, no URLs)
- Conflict resolution between overlapping rules beyond the three tiers
- Any GUI — `stalker report` is a CLI
- Retention or pruning policy — under 30 MB/year does not warrant one yet
