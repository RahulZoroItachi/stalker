# Manual Activity Logging — Design

Date: 2026-10-01
Status: design approved in conversation, pending spec review
Builds on: `2026-09-29-activity-tracker-design.md`

## 1. Purpose

The sampler can only see the laptop. A workout, a commute, a night's sleep and an
episode watched on a TV are all invisible to it, so they land in the report as
`no data`. This adds a way to say what happened, by hand, for the parts of the day
the laptop could not see.

Success criteria:

- A day I have logged shows `sleep` and `travel` in the timeline, not `no data`.
- Workout, anime and reading sit in the same list as work, with percentages, so I
  can compare how I spent the day.
- Sleep does not appear in that list. Seven hours of it would make every other row
  look like a rounding error.
- Logging something can never erase what the laptop actually recorded.
- A mistyped activity name is refused, not quietly filed as a new category.

Non-goals: no reminders, no prompting, no guessing from calendar or location, no
phone app, no retroactive inference.

## 2. Scope decisions

Settled in conversation, with reasons, so they are not re-litigated.

| Decision | Choice | Why |
|---|---|---|
| Storage | a hand-editable text file | `stalker.db` is machine-owned per §6.1 of the base spec. A typed claim is not an observation. |
| Location | `~/.config/stalker/notes.txt` | hand-owned, so it belongs beside `rules.toml`, not in Application Support |
| Format | one line per block | appendable by a command and fixable with a text editor. A mistake needs no undo command, just an edit. |
| Entry | `stalker note` | one line per block, no assumptions about routine |
| Layout | one list, sleep excluded | the user wants to compare work against anime directly; sleep in the same denominator buries everything |
| Percentages | share of logged time | not of 24 h. Unaccounted time is reported as its own figure instead of diluting every row. |
| Conflict rule | the laptop wins when it saw an app | see §5. Chosen after the stricter "gap and locked only" rule was found to break workouts. |
| Classification timing | read time, as everywhere else | a note is re-read on every report, so fixing a line fixes history |
| Activity list | declared up front | "fixed things", in the user's words. An undeclared name is an error. |

## 3. Configuration

Two new keys in `~/.config/stalker/rules.toml`. Plain `key = "value"` strings, so
the existing hand-rolled parser needs no new syntax.

```toml
# Activities logged by hand with `stalker note`. Comma-separated.
activities = "playing, workout, sleep, travel, anime, movies, reading"

# Of those, the ones that are rest rather than something you chose to do.
# Kept out of the main list so they do not dominate the percentages.
rest = "sleep"
```

Names are lowercased and trimmed on read. An entry in `rest` that is not also in
`activities` is a parse error, since it is certainly a typo.

**A name may not contain `/`.** The report already reads `fun/Youtube` as the
subcategory `Youtube` under `fun`, so an activity called `movies/series` would split
into two. Use `movies` and `series`, or `movies-series`. This is why the example above
says `movies` where the original list said "Movies/Series".

**A name shared with a rule category merges into one row.** If `rules.toml` files a
Kindle app as `reading` and `reading` is also a logged activity, the row is the sum of
both, which is almost certainly what you want. Its `active` figure then describes only
the recorded part, since the logged part has no input to measure.

Adding an activity means editing one line. That is deliberate: the list is small
and changes rarely.

## 4. The notes file

```
# stalker notes. One block per line:  DATE  FROM-TO  ACTIVITY
# Hand-editable. Re-read on every report, so a fix here fixes history.
2026-10-01  01:00-08:00  sleep
2026-10-01  08:30-09:00  travel
2026-09-30  23:30-07:00  sleep
```

Whitespace-separated, `#` comments, blank lines ignored. Chosen over TOML because a
command has to append to it and a human has to fix it, and both are easier on one
line than on a four-line table.

**Crossing midnight.** If `TO` is less than or equal to `FROM`, the block ends the
next day. `2026-09-30 23:30-07:00 sleep` runs to 07:00 on 1 October. Sleep normally
crosses midnight, so this is the common case rather than an edge case.

**Parse errors are fatal and reported**, never skipped, for the reason §9 of the base
spec gives for `rules.toml`: a silently ignored line is a silently wrong report.

## 5. Resolution

The one rule, in the user's words: *if the laptop records something keep it, unless
what it recorded is idle, locked or no data.*

| Recorded kind | Claimable by a note | Why |
|---|---|---|
| `app` | **no** | an app had focus. Either there was input, or media was playing. Both are real. |
| `idle` | yes | present but not touching anything, and nothing playing. This is the walked-away case. |
| `locked` | yes | screen locked |
| `gap` | yes | no data at all |

`idle` being claimable is the point of the rule. Walk away from an unlocked laptop
and the sampler records `idle`, not `gap`. Under a gap-and-locked-only rule a
45-minute workout would log almost nothing, because idle would block it. Today's
data already contains 32 minutes of idle, so this is not hypothetical.

### 5.1 Algorithm

For a reported range `[from, to)`:

1. Slice the day's intervals as now.
2. Collect `held` — every second covered by an interval of kind `app`.
3. Take each note in file order. Clip its span to the reported range, then subtract
   `held` and every second an earlier note already claimed. What remains is the time
   that note logged.
4. Claimed seconds are removed from the `idle`, `locked` and `gap` totals.
5. What is left of `locked` and `gap` becomes `unaccounted`. What is left of `idle`
   stays in the list as `idle`, exactly as today.

File order breaking ties between two overlapping notes is arbitrary but
deterministic and explainable. Both get reported as an overlap, so it is visible
rather than silent.

### 5.2 Overlap reporting

Whenever a note's stated span is longer than what it actually claimed, the report
says so beneath the totals:

```
notes
  sleep 01:00-08:00 claimed 6h 20m of 7h 00m — 40m held by recorded activity (Slack)
```

This is the honest half of the conflict rule. Without it, a note that silently
claimed less than it stated would read as a tracker that lost time.

## 6. Reporting

### 6.1 Day view

```
Thu 1 Oct 2026

01:00 ─ 08:00   sleep
08:00 ─ 08:30   no data
08:30 ─ 09:00   travel
09:00 ─ 09:30   locked
09:30 ─ 10:00   pet-project  iTerm2     ~/Desktop/…/time-to-leave-v2   (33%)
10:00 ─ 10:30   work         Ghostty    ~/…/Analytics_Personalisation  (68%)

YOUR DAY   5h 09m logged
  work         ██████░░░░░░░░░░   1h 48m   35%   active 82%
  workout      ██░░░░░░░░░░░░░░      45m   15%
  anime        ██░░░░░░░░░░░░░░      40m   13%
  idle         ██░░░░░░░░░░░░░░      32m   10%
  travel       ██░░░░░░░░░░░░░░      30m   10%
  reading      █░░░░░░░░░░░░░░░      20m    6%
  pet-project  █░░░░░░░░░░░░░░░      19m    6%
  fun          █░░░░░░░░░░░░░░░      15m    5%

sleep  7h 00m
unaccounted  11h 51m   locked 2h 15m · no data 9h 36m
```

Notes on the layout, all consistent with the day view built on 2026-10-01:

- Logged activities are rows like any other. They carry no `active` figure, because
  there is no input to measure, and the clause is simply absent.
- A bucket's winner is still decided by total seconds. A half-hour holding 28
  minutes of workout and 2 minutes of Slack is a `workout` row.
- Runs of a logged activity collapse the way `locked` and `gap` runs do. Sleep is
  one row, not fourteen.
- `locked` and `gap` stay separate inside `unaccounted`, because gap rows are the
  only evidence of a dead sampler. Base spec §9.
- `rest` activities print below the list. One line each, no bar, no percentage.

### 6.2 Week view

Logged activities become columns like any other category, subject to the same top-5
plus `other` rule. The `tracked` column is renamed `logged`. `rest` activities and
`unaccounted` print as footer lines beneath the table, not as columns, so the table
stays about what was chosen.

## 7. The command

```
stalker note FROM-TO ACTIVITY [--date YYYY-MM-DD]
stalker note --list [--date YYYY-MM-DD]
```

```
$ stalker note 01:00-08:00 sleep
noted: sleep   01:00-08:00  (7h 00m)

$ stalker note --date 2026-09-30 23:30-07:00 sleep
noted: sleep   23:30-07:00  (7h 30m, crosses midnight)

$ stalker note 18:00-19:00 wrkout
unknown activity "wrkout". Declared activities are:
  playing, workout, sleep, travel, anime, movies, reading
Add it to activities in ~/.config/stalker/rules.toml
```

Validation happens before the append, so the file never gains a line the report
cannot read. An unknown activity exits 2, matching the usage-error convention.

There is no delete subcommand. Removing a block means deleting its line, which is
why the format is one line per block.

## 8. Failure modes

| Failure | Symptom | Handling |
|---|---|---|
| Notes file malformed | would silently mis-report | parse error is fatal and named, like `rules.toml` |
| Activity not declared | typo becomes a category | refused at `note` time; a hand-edited file is refused at report time |
| Note overlaps recorded activity | note claims less than stated | reported under `notes`, §5.2 |
| Two notes overlap | arbitrary split | file order wins, both reported as overlapping |
| Note entirely covered by app time | claims nothing | reported as claiming 0 of its stated span |
| Note outside the reported range | invisible | clipped to the range, like any interval |
| `rest` names an undeclared activity | silent exclusion from the list | parse error |

## 9. Testing

The interval arithmetic in §5.1 is the part that can be subtly wrong, so it carries
most of the tests.

- A note over untouched time claims its whole span.
- A note fully covered by `app` time claims nothing.
- A note partly covered claims exactly the remainder. The 28-minutes-workout against
  2-minutes-Slack case, asserted on both the total and the timeline row.
- `idle` is claimed; `app` with no input, meaning media playing, is not.
- A note crossing midnight contributes to both days, clipped to each.
- Two overlapping notes split in file order, and both are reported.
- Claimed time leaves `unaccounted` and appears in the list, with the day's figures
  still summing to the range.
- `rest` activities are excluded from the percentages but printed.
- A week spanning a logged activity totals it across days.
- `note` refuses an undeclared activity, a malformed range, and an impossible date.

## 10. Out of scope

- Any prompting, reminding, or nagging to log.
- Inferring activity from calendar, location, or phone.
- Editing or deleting notes through the CLI. Edit the file.
- Recurring routines, such as "sleep 01:00-08:00 every weeknight". Rejected for now
  because a routine quietly claims hours on every day you forget to override it.
- Sub-day granularity finer than a minute.

## 11. Open items

1. **Whether `series` deserves its own activity, separate from `movies`.** The
   original list said "Movies/Series" as one item, and a name cannot contain `/`
   (§3), so it is `movies` for now and covers both. Splitting it later is a one-line
   config edit. Confirmed separately that `movies` and `anime` stay distinct.
2. **Whether `unaccounted` should break down further.** Right now it is locked plus
   gap. Once sleep is logged nightly, what remains may turn out to be mostly dark
   wake, which is a collection problem rather than a reporting one.
3. **Dark wake fragmentation.** Measured on 2026-10-01: the 01:00-08:00 window holds
   268 `gap` rows and 267 `locked` rows, one pair roughly every 47 seconds. Logging
   sleep hides this in the report without fixing it. Separate piece of work.
