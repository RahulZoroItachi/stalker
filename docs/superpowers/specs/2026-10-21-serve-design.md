# Browser Report (`stalker serve`) — Design

Date: 2026-10-21
Status: design approved in conversation, pending spec review
Builds on: `2026-09-29-activity-tracker-design.md`, `2026-10-01-manual-activity-logging-design.md`

## 1. Purpose

The report only exists while a terminal is printing it. `stalker report` is a
snapshot: it is stale the moment it finishes, and seeing the current day means
retyping the command. The grid makes this worse, because colour is the only signal
its blocks carry, so piping or pasting the report drops the best view it has.

This adds a second surface. A localhost HTTP server renders the same report as a
page, so a bookmarked tab is always there and a Refresh link re-reads the database.

Success criteria:

- A bookmarked `localhost` tab answers at any time, without my having started
  anything first.
- Pressing Refresh shows the database as it is now, and the page says when it was
  read so I never have to guess how stale it is.
- The grid always renders, because a browser always has colour.
- Editing `rules.toml` and pressing Refresh re-classifies history, exactly as
  re-running the report does today.
- The terminal report is unchanged. Byte for byte, proven by its existing tests.

Non-goals: no writes, no categorising by click, no auto-refresh, no polling, no
network exposure, no JavaScript.

## 2. Scope decisions

Settled in conversation, with reasons, so they are not re-litigated.

| Decision | Choice | Why |
|---|---|---|
| Scope | read-only viewer | smallest thing that fixes staleness. Writes need a `rules.toml` write path and a stale-file conflict rule, which is its own design. |
| Lifecycle | always-on launchd agent | a server you must start first has not removed the command from the path, it has renamed it |
| Visual direction | hybrid | monospace where alignment *is* the design, browser chrome for what only a browser can do |
| HTTP stack | hand-rolled POSIX sockets | matches the existing idiom of linking `sqlite3` directly. `swift-nio` would be the project's first dependency and would lengthen every `brew install`, which now compiles on the user's machine. |
| Concurrency | one connection at a time | the workload is one person pressing Refresh. Serialised is the right size, not a compromise. |
| Refresh | a link, not polling | 30-minute buckets mean the timeline is static for half an hour at a time. A link also keeps the page script-free. |
| Labels in the model | untruncated | ellipsizing depends on terminal width, so it belongs in each renderer, not in shared data |
| Grid omission | a renderer decision | ANSI has no colour when piped. A browser always has colour, so HTML always draws it. |
| Rules and notes caching | none, re-read per request | preserves "fix the file, fix the history" from §5 of the logging spec |
| Page scripting | none at all | a Refresh link and `title` tooltips need no JavaScript. For a tool whose pitch is that data never leaves the machine, a script-free page is worth having. |

## 3. The view model

Groundwork, and it lands before any HTML exists.

`Report.swift` is already a clean data layer: `slice()` returns `[Slice]` and
`totals()` returns `[CategoryTotal]`, with no formatting anywhere. The
*report-shaped* decisions are not in there. They sit inside the ANSI renderer as
private functions and local closures, so a second renderer would have to duplicate
them, and the two views would drift.

`Grid.swift` already has the right shape, where `gridBlocks()` computes and
`renderGrid()` formats. Day and week follow it.

### 3.1 What moves

Out of `renderDay` into a new `DayModel.swift` in `StalkerCore`:

- `timelineRows`, currently `private` at `DayReport.swift:98`. The winner-per-bucket
  pick and the merging of away runs.
- `breakdownRows`, currently a closure inside `renderDay`. The indent levels, the
  `prefix(4)` and `prefix(6)` caps, and both kinds of `other` folding.
- `tracked` and `inList`, so the away and rest exclusions that define the
  denominator live in one place.
- `worthShowing`, the 60-second floor.
- `hasLogged`, which chooses between `TOTALS tracked` and `YOUR DAY logged`.
- The `locked` and `gap` footer, including the `away` versus `unaccounted` switch.
- The short-notes section, with its `heldBy` blame and `prefix(3)`.
- The category order from `colorMap`, so a category keeps one colour across both
  renderers and across days.
- `gridBlocks()` output and the switch count, which `main.swift:103` currently
  composes onto the table by hand.

### 3.2 What stays in the ANSI renderer

Everything that depends on terminal width: the column constants, the `labelEnd`
alignment pass, `bar()` and its block characters, `padded`, `rightAligned`,
`column`, `ellipsizeLabel`, and the colour codes.

### 3.3 Shape

```swift
public struct DayModel: Sendable {
    public let dayStart: Int
    public let timeline: [TimelineRow]       // start, end, category, appName, label, share
    public let categories: [CategoryBlock]   // each with breakdown: [BreakdownRow]
    public let tracked: Int
    public let hasLogged: Bool
    public let rest: [RestTotal]
    public let away: AwayTotal?              // locked, gap, label
    public let shortNotes: [ShortNote]
    public let grid: [String]                // one category per ten-minute block
    public let switches: Int
    public let categoryOrder: [String]       // stable colour assignment
}
```

`BreakdownRow` carries `indent`, `label` and `seconds`. Labels are **untruncated**.
`renderDay` keeps calling `ellipsizeLabel`. HTML truncates in CSS and puts the whole
string in a `title`. This is a direct upgrade: a Google Doc that reads
`docs.google.com/document/d/17O94YR31cOCAnhv1a…/edit` in the terminal is readable in
full on hover.

`WeekModel` gets the same treatment over `renderWeek`: the per-day `catsFor`, the
`weekColumnLimit` of 6 with its `other` column, and the summed total row.

### 3.4 The guarantee

`ReportTests` and `GridTests` pass **completely unchanged** after the extraction.
Not adjusted, not re-baselined. They assert exact ANSI output, so if they still pass,
code moved without changing what the terminal prints.

## 4. The HTTP layer

### 4.1 Routes

| Request | Response |
|---|---|
| `GET /` | today's day view |
| `GET /?date=YYYY-MM-DD` | that day |
| `GET /week` | the current calendar week |
| `GET /week?date=YYYY-MM-DD` | the week containing that date |
| `GET` anything else | 404, including `/favicon.ico` |
| any other method | 405 |

CSS is inline in a `<style>` block rather than its own route. One page, one request,
no asset serving to write.

### 4.2 Parsing

Read until the blank line, cap the whole request at 8 KB and reject anything larger.
Take the request line and the `Host` header, ignore the rest. No bodies, no chunked
encoding, no keep-alive. Every response carries `Connection: close` and
`Cache-Control: no-store`. The point of the feature is freshness, so a browser
serving a Refresh from cache would defeat it.

### 4.3 Security

1. Bind `127.0.0.1` explicitly, never `0.0.0.0`. Nothing on the network can reach it.
2. Validate `Host` against `127.0.0.1:PORT` and `localhost:PORT`. This blocks DNS
   rebinding: a hostile site can resolve a domain it owns to 127.0.0.1, at which
   point its page is same-origin with this server and can read the whole activity
   history. Those requests arrive with the attacker's `Host`, so the check rejects
   them.
3. Send no CORS headers at all. The default same-origin policy then stops other
   pages reading responses even when they can issue requests.

Accepted trade: a second local user account on this Mac could reach the port, where
it cannot read `~/Library/Application Support/stalker` directly. On a single-user
laptop this is moot. If it stops being moot, the fix is a token in the URL, which is
what the first write endpoint would need anyway.

### 4.4 Structure

```swift
public struct Request  { let method, path: String; let query: [String: String]; let host: String? }
public struct Response { let status: Int; let contentType: String; let body: [UInt8] }

public func parseRequest(_ bytes: [UInt8]) -> Request?
public func route(_ req: Request, allowedHosts: Set<String>, source: ModelSource) -> Response
```

`parseRequest` and `route` are pure and live in `StalkerCore`. `ModelSource` supplies
a `DayModel` or `WeekModel` for a range, so tests inject a stub and assert on status
and body with no socket and no database. The socket loop does nothing but accept
bytes and hand them to those two functions.

## 5. The page

Mockup B, validated against real data on 2026-10-21.

- Top bar: Day and Week tabs, the date, `read at 15:42`, and the Refresh link.
- Previous and next day arrows, which are links to `/?date=…`. Better than the CLI,
  where moving a day means retyping a flag.
- The timeline, monospace, as it reads today.
- Totals with CSS bars in place of `████░░░░`, labels truncated in CSS with the full
  string in `title`.
- The grid as 144 blocks with hour dividers, each titled `14:30 – 14:40  work`.
- The away footer and the switch count.

`read at 15:42` is rendered server-side at request time. Rather than pretending the
page is live, it states exactly how old what you are reading is.

### 5.1 Escaping

**Every interpolated value is HTML-escaped.** Context strings are window titles and
browser URLs, and titles come from web pages, so they are attacker-influenced. A page
titled `<img src=x onerror=…>` would otherwise inject script into the one report you
trust. One `esc()` helper, applied to every interpolation, with a test that proves a
context containing `<script>` comes out inert.

### 5.2 Renderer

`renderDayHTML(DayModel, options) -> String` in `StalkerCore`, beside `renderDay`.
String building, no template engine, matching how the ANSI renderer works.

## 6. The command and the agent

- `stalker serve [--port N]` runs in the foreground. launchd runs it that way, and it
  stays runnable by hand for debugging. Default port 7777.
- A second launchd plist beside the existing one: `KeepAlive` true instead of
  `StartInterval`, plus `ThrottleInterval` so a bound port backs off rather than
  spinning.
- `install.sh` installs it and prints the URL to bookmark.
- `doctor` gains a check that the server is listening and answering. It is now
  something that can be silently dead.
- The usage text gains the command.

## 7. Failure modes

| Condition | Behaviour |
|---|---|
| `rules.toml` has a typo | 500 whose body is the exact parse error. Loud and visible is the existing contract from §9 of the base spec, and browsers render a 500 body fine. |
| database locked | the existing 3-second `busy_timeout` applies. If it still fails, an error page, and the server survives. |
| client connects and sends nothing | socket read timeout of a couple of seconds. With serialised handling one hung connection would block every later request, so this is load-bearing. |
| client disconnects mid-write | logged, connection dropped, accept loop continues. One bad connection must never kill the server. |
| port already bound | exit with a clear message. `ThrottleInterval` keeps launchd from spinning on it. |
| restart hits `TIME_WAIT` | `SO_REUSEADDR` on the listener. |
| no activity in range | the same "no activity recorded" the renderers already produce. |

## 8. Testing

- `ReportTests` and `GridTests` pass unchanged. The extraction's proof.
- New model tests over `dayModel` and `weekModel`.
- `parseRequest`: valid, malformed, oversized, non-GET.
- `route`: every route, `?date` handling, a rejected `Host`, 404, 405, and a broken
  `rules.toml` producing 500 with the parse error in the body.
- The escaping test from §5.1.
- One real socket round trip on an ephemeral port, as a smoke test. Everything else
  needs no network.

## 9. Out of scope

No writes and no click-to-categorise. No auto-refresh or polling. No `--since`
route, which the CLI keeps. No HTTPS. No static HTML export, since `serve` removes
the reason for one. No menu bar item and no app bundle.

## 10. Open items

- The new plist's label. The existing one is `stalker.sample`, which is personal
  and already slated to be renamed before the project is shared. The server plist
  should take the neutral identifier from the start rather than add a second
  personal one.
- Whether `doctor` should offer to bootstrap the agent when it finds it missing, or
  only report it.
