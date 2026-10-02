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
