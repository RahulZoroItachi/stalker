import Foundation
import StalkerCore

/// Tests for hand-logged activities: span arithmetic, the notes file, resolution
/// against recorded time, and the reporting that follows.

@MainActor func spanTests(_ t: T) {
    // --- normalized: one canonical form for any set of spans ---
    t.eq(normalized([]), [], "an empty set normalizes to empty")
    t.eq(normalized([Span(10, 20)]), [Span(10, 20)], "a single span is unchanged")
    t.eq(normalized([Span(30, 40), Span(10, 20)]), [Span(10, 20), Span(30, 40)],
         "spans come back sorted by start")
    t.eq(normalized([Span(10, 20), Span(15, 30)]), [Span(10, 30)], "overlapping spans merge")
    // Touching spans merge too. Leaving [10,20) and [20,30) separate would make the
    // arithmetic depend on how the input happened to be split.
    t.eq(normalized([Span(10, 20), Span(20, 30)]), [Span(10, 30)], "touching spans merge")
    t.eq(normalized([Span(10, 20), Span(25, 30)]), [Span(10, 20), Span(25, 30)],
         "spans with a hole between them stay separate")
    t.eq(normalized([Span(10, 10)]), [], "an empty span is dropped")
    t.eq(normalized([Span(20, 10)]), [], "a backwards span is dropped rather than negated")
    t.eq(normalized([Span(10, 50), Span(20, 30)]), [Span(10, 50)],
         "a span wholly inside another is absorbed")

    // --- totalSeconds ---
    t.eq(totalSeconds([]), 0, "nothing is zero seconds")
    t.eq(totalSeconds([Span(0, 60), Span(120, 180)]), 120, "disjoint spans sum")
    // Counted after normalising, so double-counting an overlap is impossible.
    t.eq(totalSeconds([Span(0, 60), Span(30, 90)]), 90, "an overlap is counted once")

    // --- subtracting ---
    t.eq(subtracting([Span(0, 100)], []), [Span(0, 100)], "subtracting nothing changes nothing")
    t.eq(subtracting([Span(0, 100)], [Span(200, 300)]), [Span(0, 100)],
         "subtracting a disjoint span changes nothing")
    t.eq(subtracting([Span(0, 100)], [Span(0, 100)]), [], "subtracting itself leaves nothing")
    t.eq(subtracting([Span(0, 100)], [Span(0, 200)]), [], "a larger cut leaves nothing")
    t.eq(subtracting([Span(0, 100)], [Span(0, 40)]), [Span(40, 100)], "a cut at the start")
    t.eq(subtracting([Span(0, 100)], [Span(60, 100)]), [Span(0, 60)], "a cut at the end")
    // The case the whole feature rests on: 40 minutes of Slack in the middle of a
    // seven-hour sleep leaves sleep on both sides of it, not one side.
    t.eq(subtracting([Span(0, 100)], [Span(40, 60)]), [Span(0, 40), Span(60, 100)],
         "a cut in the middle splits the span in two")
    t.eq(subtracting([Span(0, 100)], [Span(10, 20), Span(30, 40)]),
         [Span(0, 10), Span(20, 30), Span(40, 100)], "two cuts leave three pieces")
    t.eq(subtracting([Span(0, 50), Span(100, 150)], [Span(25, 125)]),
         [Span(0, 25), Span(125, 150)], "one cut can span the hole between two spans")

    // --- intersecting ---
    t.eq(intersecting([Span(0, 100)], [Span(40, 60)]), [Span(40, 60)], "the inner span survives")
    t.eq(intersecting([Span(0, 100)], [Span(200, 300)]), [], "disjoint spans intersect to nothing")
    t.eq(intersecting([Span(0, 100)], []), [], "intersecting with nothing yields nothing")
    t.eq(intersecting([Span(0, 50), Span(100, 150)], [Span(25, 125)]),
         [Span(25, 50), Span(100, 125)], "an intersection can produce several pieces")
    t.eq(intersecting([Span(0, 100)], [Span(0, 100)]), [Span(0, 100)], "identical spans intersect whole")

    // --- clippedTo, the day-boundary helper ---
    t.eq(clipped([Span(0, 100)], to: Span(20, 80)), [Span(20, 80)], "a span is clipped to the window")
    t.eq(clipped([Span(0, 10)], to: Span(20, 80)), [], "a span outside the window disappears")
    // A note crossing midnight has to contribute to each day separately, which is
    // exactly this clip applied twice with different windows.
    t.eq(clipped([Span(50, 150)], to: Span(0, 100)), [Span(50, 100)],
         "the first day gets the part before the boundary")
    t.eq(clipped([Span(50, 150)], to: Span(100, 200)), [Span(100, 150)],
         "the second day gets the part after it")
}

@MainActor func activityConfigTests(_ t: T) {
    func parse(_ extra: String) -> RuleSet? {
        try? parseRules("""
        default = "unclear"
        \(extra)

        [[rule]]
        app = "com.test.a"
        category = "work"
        """, homeDirectory: "/Users/alex")
    }

    // --- the declared list ---
    let rs = parse("""
    activities = "playing, workout, sleep, travel, anime, movies-series, reading"
    rest = "sleep"
    """)
    t.expect(rs != nil, "a rules file with activities parses")
    t.eq(rs?.activities.count, 7, "all seven activities are read")
    t.eq(rs?.activities.first, "playing", "declared order is preserved for error messages")
    t.eq(rs?.activities.contains("movies-series"), true, "a hyphenated name survives intact")
    t.eq(rs?.rest, Set(["sleep"]), "rest names the activities that are rest")

    // Trimmed and lowercased, so "Workout" and " workout " are the same activity and a
    // note typed either way matches.
    let cased = parse("activities = \"  Workout , SLEEP \"\nrest = \"Sleep\"")
    t.eq(cased?.activities, ["workout", "sleep"], "names are trimmed and lowercased")
    t.eq(cased?.rest, Set(["sleep"]), "rest is lowercased to match")

    // --- absent keys are fine; most rule files will never declare an activity ---
    let none = parse("")
    t.eq(none?.activities, [], "activities defaults to empty")
    t.eq(none?.rest, Set([]), "rest defaults to empty")

    // --- the mistakes worth refusing ---
    func rejects(_ extra: String, _ name: String) {
        t.expect(parse(extra) == nil, name)
    }
    // A rest entry that is not a declared activity is certainly a typo, and silently
    // ignoring it would quietly put sleep back into the percentages.
    rejects("activities = \"workout\"\nrest = \"sleep\"",
            "a rest entry that is not a declared activity is refused")
    // A slash would be read as a subcategory, the way work/Meeting puts Meeting inside
    // work, so the one activity would split into two rows.
    rejects("activities = \"movies/series\"",
            "an activity name containing a slash is refused")
    rejects("activities = \"workout, , sleep\"", "an empty activity name is refused")
    rejects("activities = \"workout, workout\"", "a duplicated activity is refused")
    rejects("rest = \"sleep\"", "rest without any activities declared is refused")

    // Inside a [[rule]] these keys are meaningless and must not be silently ignored.
    let inRule = try? parseRules("""
    default = "unclear"

    [[rule]]
    app = "com.test.a"
    category = "work"
    activities = "workout"
    """, homeDirectory: "/Users/alex")
    t.expect(inRule == nil, "activities inside a [[rule]] is refused")
}

@MainActor func notesFileTests(_ t: T) {
    let utc = TimeZone(identifier: "UTC")!
    let declared = Set(["sleep", "travel", "workout"])
    // 2026-10-01 00:00 UTC
    let oct1 = 1_790_812_800

    func parse(_ text: String) -> [Note]? {
        try? parseNotes(text, activities: declared, timeZone: utc)
    }

    // --- the ordinary line ---
    let one = parse("2026-10-01  01:00-08:00  sleep")
    t.eq(one?.count, 1, "one line yields one note")
    t.eq(one?.first?.activity, "sleep", "the activity is read")
    t.eq(one?.first?.span, Span(oct1 + 3600, oct1 + 28800), "the span is absolute unix seconds")
    t.eq(one?.first?.line, 1, "the line number is kept, for error messages")

    // --- comments, blanks, and loose whitespace ---
    let messy = parse("""
    # a comment
    2026-10-01   01:00-08:00   sleep

      2026-10-01  08:30-09:00  travel   # trailing comment
    """)
    t.eq(messy?.count, 2, "comments and blank lines are skipped, indentation ignored")
    t.eq(messy?.last?.activity, "travel", "the second line is read")
    t.eq(messy?.last?.span, Span(oct1 + 30600, oct1 + 32400), "08:30-09:00 is half an hour")

    // --- crossing midnight ---
    // Sleep normally crosses midnight, so this is the common case, not an edge case.
    let night = parse("2026-09-30  23:30-07:00  sleep")
    t.eq(night?.first?.span.seconds, 27000, "23:30-07:00 is 7h 30m, ending the next day")
    t.eq(night?.first?.span.end, oct1 + 25200, "and it ends at 07:00 on the following day")

    // --- an activity is matched case-insensitively against the declared list ---
    t.eq(parse("2026-10-01  01:00-02:00  SLEEP")?.first?.activity, "sleep",
         "the activity is lowercased to match the declared list")

    // --- the mistakes worth refusing ---
    func rejects(_ text: String, _ name: String) {
        t.expect((try? parseNotes(text, activities: declared, timeZone: utc)) == nil, name)
    }
    rejects("2026-10-01  01:00-08:00", "a line missing the activity is refused")
    rejects("2026-10-01  01:00-08:00  sleep  extra", "a line with a fourth field is refused")
    rejects("2026-10-01  sleep", "a line missing the range is refused")
    rejects("2026-13-01  01:00-08:00  sleep", "an impossible month is refused")
    rejects("2026-02-30  01:00-08:00  sleep", "a date that does not exist is refused")
    rejects("01-10-2026  01:00-08:00  sleep", "a non-ISO date is refused")
    rejects("2026-10-01  0100-0800  sleep", "a range without a colon is refused")
    rejects("2026-10-01  25:00-26:00  sleep", "an hour beyond 23 is refused")
    rejects("2026-10-01  01:60-02:00  sleep", "a minute beyond 59 is refused")
    rejects("2026-10-01  01:00-08:00  napping", "an undeclared activity is refused")
    // A zero-length block logs nothing, so it is a mistake rather than a no-op. Left
    // in the file it would read as a block that mysteriously claims no time.
    rejects("2026-10-01  08:00-08:00  sleep", "a zero-length range is refused")

    // --- an empty file is not an error ---
    t.eq(parse(""), [], "an empty notes file yields no notes")
    t.eq(parse("# only a comment\n"), [], "a file of only comments yields no notes")

    // --- the line a command appends round-trips through the parser ---
    // The writer and the reader must agree, or `stalker note` could append a line that
    // the next report refuses to read.
    let line = noteLine(date: "2026-10-02", from: "01:30", to: "08:30", activity: "sleep")
    t.eq(line, "2026-10-02  01:30-08:30  sleep", "the appended line has the documented shape")
    let round = parse(line)
    t.eq(round?.count, 1, "the line it writes is a line it can read")
    t.eq(round?.first?.span.seconds, 25200, "and it means the seven hours intended")
}

@MainActor func resolutionTests(_ t: T) {
    let rules = RuleSet(defaultCategory: "unclear", rules: [
        Rule(app: "com.test.work", appName: nil, context: nil, category: "work"),
    ], activities: ["sleep", "workout"], rest: Set(["sleep"]))
    let day = Span(0, 86400)

    func note(_ from: Int, _ to: Int, _ activity: String, line: Int = 1) -> Note {
        Note(activity: activity, span: Span(from, to), line: line)
    }

    // --- a note over time nothing recorded claims all of it ---
    let gapOnly = [mkInterval(0, 3600, kind: .gap, samples: 0, active: 0)]
    let r1 = resolveNotes(intervals: gapOnly, notes: [note(0, 3600, "sleep")], range: day)
    t.eq(r1.claims.count, 1, "the note produces a claim")
    t.eq(r1.claims.first?.stated, 3600, "it stated an hour")
    t.eq(r1.claims.first?.claimed, 3600, "and claimed the whole hour")
    t.eq(r1.intervals.filter { $0.kind == .gap }.count, 0, "the gap it covered is gone")

    // --- app time is never claimable ---
    let appOnly = [mkInterval(0, 3600, bundle: "com.test.work", app: "Ghostty", ctx: "/a",
                              samples: 120, active: 120)]
    let r2 = resolveNotes(intervals: appOnly, notes: [note(0, 3600, "sleep")], range: day)
    t.eq(r2.claims.first?.stated, 3600, "the note still states an hour")
    t.eq(r2.claims.first?.claimed, 0, "but claims none of it, because an app had focus")
    t.eq(r2.intervals.count, 1, "the recorded interval survives untouched")
    t.eq(r2.intervals.first?.endedAt, 3600, "at its full length")

    // --- the case the rule exists for: a 30-minute block with 2 minutes recorded ---
    // 28 minutes of workout, interrupted by 2 minutes of real app use in the middle.
    let interrupted = [
        mkInterval(0, 840, kind: .idle, samples: 28, active: 0),
        mkInterval(840, 960, bundle: "com.test.work", app: "Ghostty", ctx: "/a",
                   samples: 4, active: 4),
        mkInterval(960, 1800, kind: .idle, samples: 28, active: 0),
    ]
    let r3 = resolveNotes(intervals: interrupted, notes: [note(0, 1800, "workout")], range: day)
    t.eq(r3.claims.first?.stated, 1800, "the note stated thirty minutes")
    t.eq(r3.claims.first?.claimed, 1680, "and claimed twenty-eight, the part nothing held")
    t.eq(r3.claims.first?.spans.count, 2,
         "claimed on both sides of the interruption, not truncated at it")
    t.eq(r3.intervals.filter { $0.kind == .idle }.count, 0, "both idle stretches are consumed")
    t.eq(r3.intervals.filter { $0.kind == .app }.count, 1, "the recorded two minutes remain")

    // --- idle and locked are claimable, in the user's words ---
    for kind in [Kind.idle, Kind.locked, Kind.gap] {
        let ivs = [mkInterval(0, 600, kind: kind, samples: 20, active: 0)]
        let r = resolveNotes(intervals: ivs, notes: [note(0, 600, "sleep")], range: day)
        t.eq(r.claims.first?.claimed, 600, "\(kind.rawValue) time is claimable")
    }

    // --- two notes over the same time: the first in file order wins ---
    // Arbitrary but deterministic, and the second reports claiming less than it stated
    // so the overlap is visible rather than silent.
    let r4 = resolveNotes(intervals: [mkInterval(0, 3600, kind: .gap, samples: 0, active: 0)],
                          notes: [note(0, 1800, "sleep", line: 1),
                                  note(0, 3600, "workout", line: 2)],
                          range: day)
    t.eq(r4.claims.first?.claimed, 1800, "the first note claims its half hour")
    t.eq(r4.claims.last?.stated, 3600, "the second stated an hour")
    t.eq(r4.claims.last?.claimed, 1800, "but got only the half the first left")

    // --- a note outside the reported range is ignored ---
    let r5 = resolveNotes(intervals: gapOnly, notes: [note(90000, 93600, "sleep")], range: day)
    t.eq(r5.claims.count, 0, "a note for another day produces no claim here")

    // --- a note crossing the range boundary is clipped to it ---
    // This is how one night's sleep contributes to two days without being counted twice.
    let crossing = [mkInterval(0, 7200, kind: .gap, samples: 0, active: 0)]
    let r6 = resolveNotes(intervals: crossing, notes: [note(-3600, 3600, "sleep")], range: day)
    t.eq(r6.claims.first?.stated, 3600, "only the part inside the day is stated")
    t.eq(r6.claims.first?.claimed, 3600, "and only that part is claimed")

    // --- note slices cut at bucket boundaries and preserve the total ---
    let slices = noteSlices(r1.claims, bucketSecs: 1800)
    t.eq(slices.reduce(0) { $0 + $1.seconds }, 3600, "the slices preserve the claimed duration")
    t.eq(slices.count, 2, "an hour spans two half-hour buckets")
    t.expect(slices.allSatisfy { $0.category == "sleep" }, "each carries the activity as its category")
    // No input was recorded, so no active share can be claimed for it.
    t.expect(slices.allSatisfy { $0.activeSeconds == 0 }, "logged time reports no active seconds")
    t.expect(slices.allSatisfy { $0.kind == nil },
             "a logged slice has no recorded kind, which is how it is told from a measured one")

    // --- the invariant: no second is lost or counted twice ---
    // Whatever the notes claim must come out of the recorded totals exactly, or the day
    // would silently stop adding up.
    let busy = [
        mkInterval(0, 1800, kind: .gap, samples: 0, active: 0),
        mkInterval(1800, 3600, kind: .locked, samples: 60, active: 0),
        mkInterval(3600, 5400, bundle: "com.test.work", app: "Ghostty", ctx: "/a",
                   samples: 60, active: 45),
        mkInterval(5400, 7200, kind: .idle, samples: 60, active: 0),
    ]
    let before = totalSeconds(busy.map { Span($0.startedAt, $0.endedAt) })
    let r7 = resolveNotes(intervals: busy,
                          notes: [note(0, 7200, "sleep")], range: day)
    let after = totalSeconds(r7.intervals.map { Span($0.startedAt, $0.endedAt) })
    t.eq(before, 7200, "the day held two hours to begin with")
    t.eq(r7.claims.first?.claimed, 5400, "the note claimed the ninety minutes no app held")
    t.eq(after + (r7.claims.first?.claimed ?? 0), before,
         "trimmed recorded time plus claimed time equals what was there")
}

@MainActor func overlapAttributionTests(_ t: T) {
    let day = Span(0, 86400)
    // A seven-hour sleep with forty minutes of Slack inside it, which is the example
    // the design uses. The report has to be able to say what held the time.
    let ivs = [
        mkInterval(0, 3600, kind: .gap, samples: 0, active: 0),
        mkInterval(3600, 6000, bundle: "com.tinyspeck.slackmacgap", app: "Slack",
                   ctx: "general", samples: 80, active: 40),
        mkInterval(6000, 25200, kind: .gap, samples: 0, active: 0),
    ]
    let r = resolveNotes(intervals: ivs,
                         notes: [Note(activity: "sleep", span: Span(0, 25200), line: 1)],
                         range: day)
    let claim = r.claims.first
    t.eq(claim?.stated, 25200, "the note stated seven hours")
    t.eq(claim?.claimed, 22800, "and claimed all but the forty minutes Slack held")
    t.eq(claim?.heldBy["Slack"], 2400, "the app that held the time is named, with how long")
    t.eq(claim?.heldBy.count, 1, "only apps that actually overlapped are listed")

    // Two apps inside one note are both attributed.
    let two = resolveNotes(
        intervals: [
            mkInterval(0, 600, bundle: "com.a", app: "Alpha", ctx: "/a", samples: 20, active: 20),
            mkInterval(600, 1200, kind: .gap, samples: 0, active: 0),
            mkInterval(1200, 1500, bundle: "com.b", app: "Beta", ctx: "/b", samples: 10, active: 10),
        ],
        notes: [Note(activity: "sleep", span: Span(0, 1500), line: 1)], range: day)
    t.eq(two.claims.first?.heldBy["Alpha"], 600, "the first app is attributed")
    t.eq(two.claims.first?.heldBy["Beta"], 300, "and so is the second")
    t.eq(two.claims.first?.claimed, 600, "leaving only the gap between them")

    // When nothing held any of it, there is nothing to attribute and no line to print.
    let clean = resolveNotes(intervals: [mkInterval(0, 600, kind: .gap, samples: 0, active: 0)],
                             notes: [Note(activity: "sleep", span: Span(0, 600), line: 1)],
                             range: day)
    t.eq(clean.claims.first?.heldBy.isEmpty, true, "a note that claimed everything attributes nothing")
    t.eq(clean.claims.first?.stated, clean.claims.first?.claimed,
         "and its stated and claimed figures agree")

    // Time lost to an EARLIER NOTE is not blamed on an app. Different cause, and
    // blaming an app would send the reader looking for activity that was not there.
    let twoNotes = resolveNotes(
        intervals: [mkInterval(0, 3600, kind: .gap, samples: 0, active: 0)],
        notes: [Note(activity: "sleep", span: Span(0, 1800), line: 1),
                Note(activity: "workout", span: Span(0, 3600), line: 2)],
        range: day)
    t.eq(twoNotes.claims.last?.claimed, 1800, "the second note gets what the first left")
    t.eq(twoNotes.claims.last?.heldBy.isEmpty, true,
         "and blames no app, because an earlier note took it")
}

private let loggedRules = RuleSet(defaultCategory: "unclear", rules: [
    Rule(app: "com.test.work", appName: nil, context: nil, category: "work"),
], activities: ["sleep", "workout", "travel"], rest: Set(["sleep"]))

@MainActor func dayViewWithNotesTests(_ t: T) {
    let utc = TimeZone(identifier: "UTC")!
    let opts = RenderOptions(width: 100, color: false, home: "/Users/alex")
    let ivs = [
        mkInterval(0, 7200, kind: .gap, samples: 0, active: 0),
        mkInterval(7200, 9000, bundle: "com.test.work", app: "Ghostty",
                   ctx: "/Users/alex/Work/Proj", samples: 60, active: 51),
        mkInterval(9000, 12600, kind: .locked, samples: 120, active: 0),
    ]
    let notes = [
        Note(activity: "sleep", span: Span(0, 5400), line: 1),
        Note(activity: "workout", span: Span(10800, 12600), line: 2),
    ]
    let text = renderDay(ivs, notes: notes, bucketSecs: 1800, rules: loggedRules,
                         timeZone: utc, from: 0, to: 86400, options: opts)

    // --- a logged activity is a row in the list, like any category ---
    t.expect(text.contains("workout"), "a logged activity appears in the list")
    // No input was recorded for it, so no active share is claimed.
    let workoutRow = text.components(separatedBy: "\n").first { $0.hasPrefix("  workout") } ?? ""
    t.expect(!workoutRow.contains("active"), "a logged activity reports no active share")
    t.expect(workoutRow.contains("50%"), "but it does get a percentage, got: \(workoutRow)")

    // --- rest is kept out of the list and printed below it ---
    // Ninety minutes of sleep against an hour of everything else would otherwise take
    // most of the bar and halve every real percentage.
    t.expect(!text.components(separatedBy: "\n").contains { $0.hasPrefix("  sleep ") },
             "a rest activity is not a row in the list")
    t.expect(text.contains("\nsleep  1h 30m"), "a rest activity prints below the list")
    t.expect(text.contains("logged 1h 00m") || text.contains("1h 00m logged"),
             "the logged total excludes rest")

    // --- unaccounted replaces away, and shrinks by what was claimed ---
    // gap was 2h and locked 1h; the notes took 1h30m of gap and 30m of locked.
    t.expect(text.contains("unaccounted  1h 00m"), "unaccounted is what no note explained")
    t.expect(!text.contains("away  "), "the away line is gone, replaced by unaccounted")
    t.expect(text.contains("locked 30m"), "locked and no data stay distinguishable")
    t.expect(text.contains("no data 30m"), "so a dead sampler is still detectable")

    // --- the timeline names the activity instead of saying no data ---
    let rows = text.components(separatedBy: "\n").filter { $0.contains("─") }
    t.expect(rows.contains { $0.hasPrefix("00:00 ─ 01:30") && $0.contains("sleep") },
             "the sleep block is one row spanning its whole run")
    t.eq(rows.filter { $0.contains("sleep") }.count, 1,
         "three consecutive half-hours of sleep collapse to one row")
    // A logged activity has no app and no context, so it prints as a bare label the way
    // locked does, rather than padding out columns with dashes.
    let sleepRow = rows.first { $0.contains("sleep") } ?? ""
    t.expect(!sleepRow.contains("—"), "a logged row prints no placeholder app or context")
    t.expect(rows.contains { $0.hasPrefix("01:30 ─ 02:00") && $0.contains("no data") },
             "the gap the note did not cover is still reported")

    // --- the shortfall line ---
    // A note that claimed less than it stated must say so, or it reads as lost time.
    let clash = renderDay(
        [mkInterval(0, 1800, kind: .gap, samples: 0, active: 0),
         mkInterval(1800, 3600, bundle: "com.test.work", app: "Ghostty", ctx: "/a",
                    samples: 60, active: 60)],
        notes: [Note(activity: "workout", span: Span(0, 3600), line: 1)],
        bucketSecs: 1800, rules: loggedRules, timeZone: utc, from: 0, to: 86400, options: opts)
    t.expect(clash.contains("notes"), "a shortfall gets its own section")
    t.expect(clash.contains("claimed 30m of 1h 00m"), "stating both figures, got:\n\(clash)")
    t.expect(clash.contains("Ghostty"), "and naming what held the rest")
    // When a note claimed everything it stated, there is nothing to report.
    t.expect(!text.contains("claimed"), "a note that got what it asked for prints no note line")

    // --- exact layout, as a guard against drift ---
    let expected = [
        "Thu 1 Jan 1970",
        "",
        "00:00 ─ 01:30   sleep",
        "01:30 ─ 02:00   no data",
        "02:00 ─ 02:30   work         Ghostty        ~/Work/Proj",
        "02:30 ─ 03:00   locked",
        "03:00 ─ 03:30   workout",
        "",
        "YOUR DAY   1h 00m logged",
        "  work         ██████████░░░░░░░░░░      30m   50%   active 85%",
        "  workout      ██████████░░░░░░░░░░      30m   50%",
        "",
        "sleep  1h 30m",
        "unaccounted  1h 00m   locked 30m · no data 30m",
    ].joined(separator: "\n")
    t.eq(text, expected, "the rendered day matches the agreed layout exactly")

    // --- a day with no notes is unchanged from before this feature ---
    // The old header and away line are what every existing test asserts, so passing no
    // notes must still produce them.
    let plain = renderDay(ivs, bucketSecs: 1800, rules: loggedRules, timeZone: utc,
                          from: 0, to: 86400, options: opts)
    t.expect(plain.contains("TOTALS   tracked"), "with no notes the header is unchanged")
    t.expect(plain.contains("away  "), "and the away line is unchanged")
}

@MainActor func weekViewWithNotesTests(_ t: T) {
    let utc = TimeZone(identifier: "UTC")!
    let opts = RenderOptions(width: 100, color: false, home: "/Users/alex")
    let mon = 1_790_553_600, tue = 1_790_640_000, wed = 1_790_726_400

    let ivs = [
        mkInterval(mon, mon + 36000, kind: .gap, samples: 0, active: 0),
        mkInterval(mon + 36000, mon + 39600, bundle: "com.test.work", app: "Ghostty",
                   ctx: "/a", samples: 120, active: 102),
        mkInterval(mon + 39600, wed, kind: .gap, samples: 0, active: 0),
    ]
    // A night's sleep from 23:00 Monday to 07:00 Tuesday: one hour of it falls on
    // Monday and seven on Tuesday.
    let notes = [
        Note(activity: "sleep", span: Span(mon + 82800, mon + 111600), line: 1),
        Note(activity: "workout", span: Span(tue + 36000, tue + 37800), line: 2),
    ]
    let text = renderWeek(ivs, notes: notes, bucketSecs: 1800, rules: loggedRules,
                          timeZone: utc, from: mon, to: wed, options: opts)

    // --- a logged activity gets a column ---
    let header = text.components(separatedBy: "\n").first { $0.contains("logged") || $0.contains("tracked") } ?? ""
    t.expect(header.contains("workout"), "a logged activity is a column, got: \(header)")
    t.expect(header.contains("work"), "and recorded categories still are")
    // Rest is not a column. It would be the widest one every week and tell you nothing
    // you did not already know.
    t.expect(!header.contains("sleep"), "rest is not a column")
    t.expect(text.contains("sleep  8h 00m"), "rest totals as a footer line instead")

    // --- a note crossing midnight is split between the two days it touches ---
    let rows = text.components(separatedBy: "\n")
    let monRow = rows.first { $0.hasPrefix("  Mon 28") } ?? ""
    let tueRow = rows.first { $0.hasPrefix("  Tue 29") } ?? ""
    t.expect(monRow.contains("1h 00m"), "Monday shows its hour of recorded work, got: \(monRow)")
    t.expect(tueRow.contains("30m"), "Tuesday shows its half hour of workout, got: \(tueRow)")

    // --- the totals row is the sum of the day rows ---
    // work 1h on Monday plus workout 30m on Tuesday, with sleep excluded.
    let totalRow = rows.first { $0.contains("total") } ?? ""
    t.expect(totalRow.contains("1h 30m"), "the week logged an hour and a half, got: \(totalRow)")

    // --- what nothing explained ---
    // One word for one idea: the column heading and the line below the table both say
    // "unaccounted" once a note has explained part of the time away.
    t.expect(header.contains("unaccounted"),
             "the week gives unaccounted time a column, got: \(header)")
    t.expect(text.contains("unaccounted  no data "), "and names its kind below the table")
    t.expect(!text.contains("away"), "neither calls it away, since some of it now has a reason")

    // --- a week with no notes renders exactly as before ---
    let plain = renderWeek(ivs, bucketSecs: 1800, rules: loggedRules, timeZone: utc,
                           from: mon, to: wed, options: opts)
    t.expect(plain.contains("tracked"), "with no notes the column is still called tracked")
    t.expect(plain.contains("away  "), "and the away line is unchanged")
    t.expect(!plain.contains("sleep"), "with no notes there is no rest line")
}

@MainActor func noteCommandTests(_ t: T) {
    let utc = TimeZone(identifier: "UTC")!

    // --- argument parsing ---
    func action(_ args: [String]) -> NoteAction? {
        if case .note(let a) = parseArgs(args) { return a }
        return nil
    }
    t.eq(action(["note", "01:30-08:30", "sleep"]),
         NoteAction.add(range: "01:30-08:30", activity: "sleep", date: nil),
         "a range and an activity are read")
    t.eq(action(["note", "--date", "2026-10-01", "08:30-09:00", "travel"]),
         NoteAction.add(range: "08:30-09:00", activity: "travel", date: "2026-10-01"),
         "--date may precede the positional arguments")
    t.eq(action(["note", "08:30-09:00", "travel", "--date", "2026-10-01"]),
         NoteAction.add(range: "08:30-09:00", activity: "travel", date: "2026-10-01"),
         "or follow them")
    t.eq(action(["note", "--list"]), NoteAction.list(date: nil), "--list takes no positionals")
    t.eq(action(["note", "--list", "--date", "2026-10-01"]), NoteAction.list(date: "2026-10-01"),
         "--list may be scoped to a date")

    // Malformed input is refused rather than guessed, so a mistyped command cannot
    // silently append a line meaning something else.
    for bad in [["note"], ["note", "01:30-08:30"], ["note", "01:30-08:30", "sleep", "extra"],
                ["note", "--date"], ["note", "--date", "2026-10-01"],
                ["note", "--list", "01:30-08:30", "sleep"], ["note", "--nonsense"]] {
        t.eq(parseArgs(bad), Command.usageError, "refused: \(bad.joined(separator: " "))")
    }

    // --- today's date, for the default ---
    t.eq(todayString(now: 1_790_856_000, timeZone: utc), "2026-10-01",
         "the default date is today in the local zone")

    // --- the file itself ---
    let dir = NSTemporaryDirectory() + "/stalker-notes-test-\(Int(Date().timeIntervalSince1970))"
    let path = dir + "/notes.txt"
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        t.eq(try readNotes(path: path), "", "a missing notes file reads as empty, not an error")

        try appendNote(noteLine(date: "2026-10-01", from: "01:00", to: "08:00", activity: "sleep"),
                       path: path)
        let first = try readNotes(path: path)
        t.expect(first.contains("2026-10-01  01:00-08:00  sleep"), "the line is written")
        // A header so the file explains itself to whoever opens it in a year.
        t.expect(first.hasPrefix("#"), "the file is created with a header comment")

        try appendNote(noteLine(date: "2026-10-01", from: "08:30", to: "09:00", activity: "travel"),
                       path: path)
        let second = try readNotes(path: path)
        t.expect(second.contains("01:00-08:00  sleep"), "the first line survives the second append")
        t.expect(second.contains("08:30-09:00  travel"), "and the second is there too")
        t.eq(second.components(separatedBy: "\n").filter { $0.hasPrefix("# stalker notes") }.count, 1,
             "the header block is written once, not on every append")

        // The round trip that matters: what the command writes, the report must read.
        let parsed = try parseNotes(second, activities: Set(["sleep", "travel"]), timeZone: utc)
        t.eq(parsed.count, 2, "both appended lines parse back")
        t.eq(parsed.first?.activity, "sleep", "in the order they were written")
        t.eq(parsed.last?.span.seconds, 1800, "with the durations intended")

        try FileManager.default.removeItem(atPath: dir)
    } catch {
        t.expect(false, "the notes file test ran without throwing", "\(error)")
    }
}
