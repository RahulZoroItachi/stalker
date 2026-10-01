import Foundation
import StalkerCore

/// Tests for the report presentation layer: formatting primitives, the day
/// renderer, and the week roll-up. Kept out of main.swift because that file
/// already carries the collection-side suite and is long enough.

func mkInterval(_ start: Int, _ end: Int, bundle: String? = nil, app: String? = nil,
                ctx: String? = nil, kind: Kind = .app, samples: Int = 1,
                active: Int = 1, engaged: Int = 0) -> Interval {
    Interval(id: nil, kind: kind, startedAt: start, endedAt: end,
             bundleId: bundle, appName: app ?? bundle,
             contextKind: ctx == nil ? nil : .url, context: ctx, title: nil,
             samples: samples, active: active, engaged: engaged)
}

@MainActor func formatTests(_ t: T) {
    // --- formatDuration ---
    t.eq(formatDuration(0), "0m", "zero is 0m")
    t.eq(formatDuration(59), "0m", "under a minute rounds down to 0m")
    t.eq(formatDuration(60), "1m", "exactly a minute")
    t.eq(formatDuration(45 * 60), "45m", "under an hour omits the hour part")
    t.eq(formatDuration(3600), "1h 00m", "a whole hour pads its minutes to two digits")
    t.eq(formatDuration(3660), "1h 01m", "an hour and one minute")
    t.eq(formatDuration(9 * 3600 + 47 * 60), "9h 47m", "multi-hour duration")
    // A clock correction can produce a negative span. Printing "-1h -30m" would be
    // worse than useless, so it clamps.
    t.eq(formatDuration(-90), "0m", "a negative duration clamps to zero")

    // --- tildePath ---
    let home = "/Users/alex"
    t.eq(tildePath("/Users/alex/Desktop/Casey/Work", home: home), "~/Desktop/Casey/Work",
         "a path under home is abbreviated")
    t.eq(tildePath("/Users/alex", home: home), "~", "home itself is just the tilde")
    // The prefix has to end on a separator. Without that check a sibling account's
    // directory would be rewritten as if it were inside this one.
    t.eq(tildePath("/Users/alexother/x", home: home), "/Users/alexother/x",
         "a path merely sharing a prefix with home is left alone")
    t.eq(tildePath("docs.google.com/document", home: home), "docs.google.com/document",
         "a URL context is not a path and is left alone")
    t.eq(tildePath("/tmp/scratch", home: home), "/tmp/scratch",
         "a path outside home is left alone")

    // --- middleEllipsis ---
    t.eq(middleEllipsis("short", max: 20), "short", "a string within the limit is unchanged")
    t.eq(middleEllipsis("abcdefghij", max: 10), "abcdefghij",
         "a string exactly at the limit is unchanged")
    let cut = middleEllipsis("abcdefghijklmnopqrstuvwxyz", max: 10)
    t.eq(cut.count, 10, "an over-long string is cut to exactly the limit")
    t.expect(cut.contains("…"), "the cut is marked with an ellipsis")
    t.expect(cut.hasPrefix("abcd"), "the leading characters survive")
    t.expect(cut.hasSuffix("wxyz"), "the trailing characters survive")
    t.eq(middleEllipsis("abcdef", max: 1), "…", "a limit of one leaves only the ellipsis")
    t.eq(middleEllipsis("abcdef", max: 0), "", "a limit of zero yields nothing")

    // --- ellipsizeLabel: the path- and URL-aware cut used for context labels ---
    let home2 = "~/Desktop/Casey/Work/Analytics_Personalisation"
    t.eq(ellipsizeLabel(home2, max: 60), home2, "a label within the limit is untouched")
    // Whole middle segments are dropped so the last one stays intact. That last
    // segment is the only part that says which project this is, and a character-level
    // cut would eat into it.
    t.eq(ellipsizeLabel(home2, max: 40), "~/Desktop/…/Analytics_Personalisation",
         "middle segments are dropped to keep the final segment whole")
    let url = "docs.google.com/document/d/1Wkwi7yo0qqUfZGTabc/edit"
    t.eq(ellipsizeLabel(url, max: 30), "docs.google.com/…/edit",
         "a URL keeps its host and its final segment")
    // When even first + last will not fit, the leading segment goes too.
    let deep = "~/aaaaaaaaaaaaaaaaaaaaaaaa/bbbb/Analytics_Personalisation"
    let deepCut = ellipsizeLabel(deep, max: 30)
    t.expect(deepCut.count <= 30, "the result never exceeds the limit")
    t.expect(deepCut.hasSuffix("Analytics_Personalisation"),
             "the final segment is kept even at the cost of the leading one")
    // A final segment longer than the whole limit has to be cut itself, and then a
    // character-level middle cut is the only option left.
    let huge = ellipsizeLabel("~/x/ThisOneSegmentIsLongerThanTheEntireAllowance", max: 20)
    t.eq(huge.count, 20, "an over-long final segment is itself cut to the limit")
    t.expect(huge.contains("…"), "that cut is marked too")
    // No separator at all means there are no segments to drop.
    t.eq(ellipsizeLabel("abcdefghijklmnopqrstuvwxyz", max: 10).count, 10,
         "a label with no separator falls back to a character-level cut")

    // --- bar ---
    t.eq(bar(1.0, width: 10), "██████████", "a full fraction fills the bar")
    t.eq(bar(0.0, width: 10).count, 10, "an empty bar still occupies its full width")
    t.eq(bar(0.5, width: 10), "█████░░░░░", "half fills half")
    // Asserted against literals rather than against bar() itself: a self-comparison
    // is satisfied by any implementation, including one that returns nothing.
    t.eq(bar(2.0, width: 10), "██████████", "a fraction above one clamps to full")
    t.eq(bar(-1.0, width: 10), "░░░░░░░░░░", "a negative fraction clamps to empty")
    t.eq(bar(0.0, width: 10), "░░░░░░░░░░", "a zero fraction is all empty cells")
    // Rounding a 1% category to zero cells would make real time look like none at
    // all, which is the one thing the bar must never do.
    t.expect(bar(0.01, width: 10).hasPrefix("█"),
             "a small but non-zero fraction still shows one cell")
    t.expect(!bar(0.0, width: 10).contains("█"),
             "a genuinely zero fraction shows no filled cell")

    // --- percent ---
    // 45/72 is exactly 62.5, which rounds up. Truncating would under-report every
    // category and make the column sum to well under 100.
    t.eq(percent(45, of: 72), 63, "percentage rounds to nearest, halves upward")
    t.eq(percent(72, of: 72), 100, "the whole is 100")
    t.eq(percent(0, of: 72), 0, "none is zero")
    t.eq(percent(5, of: 0), 0, "a zero denominator yields zero rather than dividing")
}

@MainActor func engagementShareTests(_ t: T) {
    // One rule, so every app interval lands in a known category.
    let rules = RuleSet(defaultCategory: "unclear",
                        rules: [Rule(app: "com.test.app", appName: nil, context: nil,
                                     category: "work")])

    // 600 seconds observed over 60 samples, half of which had input. Half the time
    // was therefore hands-on.
    let half = [mkInterval(0, 600, bundle: "com.test.app", ctx: "/a",
                           samples: 60, active: 30, engaged: 12)]
    let halfSlices = slice(half, bucketSecs: 1800, rules: rules)
    t.eq(halfSlices.count, 1, "the interval produces one slice")
    t.eq(halfSlices[0].seconds, 600, "the slice carries the full duration")
    t.eq(halfSlices[0].activeSeconds, 300, "half the samples having input yields half the seconds")
    t.eq(halfSlices[0].engagedSeconds, 120, "engaged seconds scale by the same ratio")

    // Every sample had input, so active time is the whole of it.
    let allActive = [mkInterval(0, 600, bundle: "com.test.app", ctx: "/a",
                                samples: 20, active: 20, engaged: 0)]
    let allSlices = slice(allActive, bucketSecs: 1800, rules: rules)
    t.eq(allSlices[0].activeSeconds, 600, "all samples active means all seconds active")
    t.eq(allSlices[0].engagedSeconds, 0, "no engaged samples means no engaged seconds")

    // A gap row is written with samples = 0. Scaling by active/samples must not divide
    // by it; this is the case that would trap rather than merely mislead.
    let gap = [mkInterval(0, 600, kind: .gap, samples: 0, active: 0, engaged: 0)]
    let gapSlices = slice(gap, bucketSecs: 1800, rules: rules)
    t.eq(gapSlices[0].activeSeconds, 0, "a row with no samples reports no active seconds")
    t.eq(gapSlices[0].engagedSeconds, 0, "a row with no samples reports no engaged seconds")

    // Split across a boundary, the active seconds have to split with it, or the ratio
    // reported per bucket would be wrong even though the day's total looked right.
    let spanning = [mkInterval(1500, 2100, bundle: "com.test.app", ctx: "/a",
                               samples: 20, active: 10, engaged: 0)]
    let spanSlices = slice(spanning, bucketSecs: 1800, rules: rules)
    t.eq(spanSlices.count, 2, "the interval spans two buckets")
    t.eq(spanSlices.reduce(0) { $0 + $1.seconds }, 600, "duration is preserved across the split")
    t.eq(spanSlices.reduce(0) { $0 + $1.activeSeconds }, 300,
         "active seconds are preserved across the split")
    t.expect(spanSlices.allSatisfy { $0.activeSeconds == 150 },
             "each half carries half the active seconds")

    // --- totals carry the counters up ---
    let mixed = [
        mkInterval(0, 600, bundle: "com.test.app", ctx: "/a", samples: 20, active: 20, engaged: 0),
        mkInterval(600, 1200, bundle: "com.test.app", ctx: "/b", samples: 20, active: 5, engaged: 15),
    ]
    let tot = totals(slice(mixed, bucketSecs: 1800, rules: rules))
    let work = tot.first { $0.category == "work" }
    t.eq(work?.seconds, 1200, "the category total sums both intervals")
    t.eq(work?.activeSeconds, 750, "active seconds sum across the category")
    t.eq(work?.engagedSeconds, 450, "engaged seconds sum across the category")

    // The same has to hold for a subcategory, otherwise a parent's ratio and its
    // children's ratios would disagree with no way to tell which was right.
    let subRules = RuleSet(defaultCategory: "unclear",
                           rules: [Rule(app: "com.test.app", appName: nil, context: nil,
                                        category: "fun/Youtube")])
    let subTot = totals(slice(mixed, bucketSecs: 1800, rules: subRules))
    let fun = subTot.first { $0.category == "fun" }
    t.eq(fun?.subcategories.first?.activeSeconds, 750,
         "a subcategory carries its own active seconds")
    t.eq(fun?.activeSeconds, 750, "the parent's active seconds include its subcategory's")
}

private let dayRules = RuleSet(defaultCategory: "unclear", rules: [
    Rule(app: "com.test.work", appName: nil, context: nil, category: "work"),
    Rule(app: "com.test.fun", appName: nil, context: nil, category: "fun"),
])

private let utc = TimeZone(identifier: "UTC")!

/// Timeline rows only: everything above the blank line that precedes TOTALS.
private func timelineRows(_ text: String) -> [String] {
    text.components(separatedBy: "\n")
        .prefix { !$0.hasPrefix("TOTALS") }
        .filter { $0.contains("─") }
}

@MainActor func dayRenderTests(_ t: T) {
    let opts = RenderOptions(width: 100, color: false, home: "/Users/alex")

    // Four consecutive half-hours with no data, then a locked half-hour, then work.
    let ivs = [
        mkInterval(0, 7200, kind: .gap, samples: 0, active: 0),
        mkInterval(7200, 9000, kind: .locked, samples: 60, active: 0),
        mkInterval(9000, 12000, bundle: "com.test.work", app: "Ghostty",
                   ctx: "/Users/alex/Work/Proj", samples: 100, active: 85),
        mkInterval(12000, 12600, bundle: "com.test.fun", app: "Edge",
                   ctx: "youtube.com/watch", samples: 20, active: 2, engaged: 18),
    ]
    let text = renderDay(ivs, bucketSecs: 1800, rules: dayRules, timeZone: utc,
                         from: 0, to: 86400, options: opts)
    let rows = timelineRows(text)

    // --- away runs collapse, real categories do not ---
    // Four gap buckets become one row. Eighteen of them on a real overnight is what
    // made the old report unreadable.
    t.eq(rows.filter { $0.contains("no data") }.count, 1,
         "a run of four empty buckets collapses to a single row")
    t.expect(rows.contains { $0.hasPrefix("00:00 ─ 02:00") },
             "the collapsed row spans the whole run")
    t.eq(rows.filter { $0.contains("locked") }.count, 1, "the locked bucket is its own row")
    // gap and locked are different states, so adjacent runs of each stay separate rows.
    t.expect(rows.contains { $0.hasPrefix("02:00 ─ 02:30") && $0.contains("locked") },
             "a locked run is not merged into the adjacent no-data run")
    // The work interval covers two buckets and must still show as two rows: the spec
    // asks for a 30-minute-by-30-minute account, which collapsing would destroy.
    t.eq(rows.filter { $0.contains("work") }.count, 2,
         "consecutive buckets of a real category are not collapsed")

    // --- tilde ---
    t.expect(text.contains("~/Work/Proj"), "a home-relative path is shown with a tilde")
    t.expect(!text.contains("/Users/alex/Work/Proj"), "the absolute form is not shown")

    // --- the mixed-block share ---
    // 02:30-03:00 is entirely work, so no share is printed.
    let pureRow = rows.first { $0.hasPrefix("02:30 ─ 03:00") } ?? ""
    t.expect(!pureRow.contains("%"), "a block with a single category prints no share")
    // 03:00-03:30 is 1200s work against 600s fun. Work wins, but only with 67%, and
    // saying so is the difference between an honest row and a flattering one.
    let mixedRow = rows.first { $0.hasPrefix("03:00 ─ 03:30") } ?? ""
    t.expect(mixedRow.contains("(67%)"), "a mixed block prints the winner's share, got: \(mixedRow)")

    // --- tracked excludes time away from the machine ---
    // work 3000s + fun 600s = 3600s. The 7200s gap and 1800s locked are not activity
    // and must not dilute the percentages.
    t.expect(text.contains("tracked 1h 00m"),
             "tracked time counts only activity, not gap or locked")
    t.expect(text.contains("  83%") || text.contains(" 83%"),
             "work is 83% of tracked time, not of the 24-hour day")

    // --- the away footer keeps the two states distinguishable ---
    // Merging them would hide a dead sampler, which gap rows are the only evidence of.
    t.expect(text.contains("away  2h 30m"), "the footer totals time away")
    t.expect(text.contains("locked 30m"), "the footer reports locked time on its own")
    t.expect(text.contains("no data 2h 00m"), "the footer reports missing data on its own")

    // --- the engagement counters finally reach the page ---
    t.expect(text.contains("active 85%"), "a category reports what share of it was hands-on")
    t.expect(text.contains("engaged 90%"), "and what share had media playing")
    // Idle time has no input by definition, so an active figure for it would be noise.
    let idleOnly = renderDay([mkInterval(0, 600, kind: .idle, samples: 20, active: 0)],
                             bucketSecs: 1800, rules: dayRules, timeZone: utc,
                             from: 0, to: 86400, options: opts)
    t.expect(!idleOnly.contains("active"), "a category with no active time prints no active figure")

    // --- a label can never run into its duration ---
    // This is the actual bug in the old renderer: padding(toLength:) truncated the
    // label to exactly the column width, leaving no gap before the number, so the day
    // read "...Analytics_Per33m".
    let longPaths = [
        mkInterval(0, 1200, bundle: "com.test.work", app: "Ghostty",
                   ctx: "/Users/alex/Desktop/Casey/Work/Analytics_Personalisation/deeply/nested",
                   samples: 40, active: 40),
        mkInterval(1200, 1800, bundle: "com.test.work", app: "Ghostty",
                   ctx: "/Users/alex/Desktop/Casey/Work/Another_Very_Long_Project_Name/also/deep",
                   samples: 20, active: 20),
    ]
    for w in [60, 80, 100, 140] {
        let narrow = renderDay(longPaths, bucketSecs: 1800, rules: dayRules, timeZone: utc,
                               from: 0, to: 86400,
                               options: RenderOptions(width: w, color: false, home: "/Users/alex"))
        let breakdown = narrow.components(separatedBy: "\n")
            .filter { $0.hasPrefix("    ") && $0.contains("m") }
        t.expect(!breakdown.isEmpty, "the breakdown is printed at width \(w)")
        for line in breakdown {
            t.expect(line.count <= w, "no line exceeds width \(w), got \(line.count): \(line)")
            t.expect(line.contains("  "),
                     "a breakdown line keeps a gap before its duration at width \(w): \(line)")
        }
    }

    // --- rows that round to nothing are dropped ---
    // Two contexts, so the breakdown prints; the second is 20 seconds, which reads as
    // "0m" and tells the reader nothing.
    let tiny = [
        mkInterval(0, 1200, bundle: "com.test.work", app: "Ghostty", ctx: "/big", samples: 40, active: 40),
        mkInterval(1200, 1220, bundle: "com.test.work", app: "Ghostty", ctx: "/tiny", samples: 1, active: 1),
    ]
    let tinyText = renderDay(tiny, bucketSecs: 1800, rules: dayRules, timeZone: utc,
                             from: 0, to: 86400, options: opts)
    t.expect(tinyText.contains("/big"), "a context worth reporting is listed")
    t.expect(!tinyText.contains("/tiny"), "a context that rounds to 0m is dropped")

    // --- an empty day does not crash or invent content ---
    let empty = renderDay([], bucketSecs: 1800, rules: dayRules, timeZone: utc,
                          from: 0, to: 86400, options: opts)
    t.expect(!empty.contains("TOTALS"), "an empty day prints no totals section")
    t.expect(empty.contains("no activity"), "an empty day says so")

    // --- exact layout, as a guard against accidental drift ---
    let expected = [
        "Thu 1 Jan 1970",
        "",
        "00:00 ─ 02:00   no data",
        "02:00 ─ 02:30   locked",
        "02:30 ─ 03:00   work         Ghostty        ~/Work/Proj",
        "03:00 ─ 03:30   work         Ghostty        ~/Work/Proj  (67%)",
        "",
        "TOTALS   tracked 1h 00m",
        "  work         █████████████████░░░      50m   83%   active 85%",
        "  fun          ███░░░░░░░░░░░░░░░░░      10m   17%   active 10%  engaged 90%",
        "",
        "away  2h 30m   locked 30m · no data 2h 00m",
    ].joined(separator: "\n")
    t.eq(text, expected, "the rendered day matches the agreed layout exactly")
}

@MainActor func dayLayoutTests(_ t: T) {
    let opts = RenderOptions(width: 100, color: false, home: "/Users/alex")

    // --- durations align to the longest label, not the terminal edge ---
    // Right-aligning every duration at column 100 strands the numbers an inch away
    // from their labels, which is unreadable on real data where most contexts are
    // short. The column belongs just past the longest label actually present.
    let shortLabels = [
        mkInterval(0, 1200, bundle: "com.test.work", app: "Ghostty", ctx: "/a", samples: 40, active: 40),
        mkInterval(1200, 1800, bundle: "com.test.work", app: "Ghostty", ctx: "/bb", samples: 20, active: 20),
    ]
    let short = renderDay(shortLabels, bucketSecs: 1800, rules: dayRules, timeZone: utc,
                          from: 0, to: 86400, options: opts)
    let shortRows = short.components(separatedBy: "\n").filter { $0.hasPrefix("    ") }
    t.eq(shortRows.count, 2, "both contexts are listed")
    t.expect(shortRows.allSatisfy { $0.count == shortRows[0].count },
             "every breakdown row ends in the same column")
    t.expect(shortRows[0].count < 30,
             "with short labels the duration sits near them, not at the far edge, got \(shortRows[0].count)")

    // One shared column across the whole report, so a subcategory's duration lines up
    // with a plain category's rather than each category aligning to itself.
    let subRules2 = RuleSet(defaultCategory: "unclear", rules: [
        Rule(app: "com.test.work", appName: nil, context: nil, category: "work"),
        Rule(app: "com.test.fun", appName: nil, context: nil, category: "fun/Youtube"),
    ])
    let mixedDepth = [
        mkInterval(0, 1200, bundle: "com.test.work", app: "Ghostty", ctx: "/short", samples: 40, active: 40),
        mkInterval(1200, 1800, bundle: "com.test.work", app: "Ghostty", ctx: "/other", samples: 20, active: 20),
        mkInterval(1800, 3000, bundle: "com.test.fun", app: "Edge",
                   ctx: "/a/much/longer/context/path/here", samples: 40, active: 40),
    ]
    let depth = renderDay(mixedDepth, bucketSecs: 1800, rules: subRules2, timeZone: utc,
                          from: 0, to: 86400, options: opts)
    let depthRows = depth.components(separatedBy: "\n").filter { $0.hasPrefix("    ") }
    t.expect(depthRows.count >= 3, "the deeper breakdown is printed")
    t.expect(depthRows.allSatisfy { $0.count == depthRows[0].count },
             "rows at different indents still share one duration column")
    t.expect(depthRows.allSatisfy { $0.count <= 100 }, "and the column stays inside the width")

    // --- a category that rounds to 0m is not printed at all ---
    // The old output ended with "unclear 0m 0%", a row that says nothing and crowds
    // out the rows that do.
    let withNoise = [
        mkInterval(0, 1800, bundle: "com.test.work", app: "Ghostty", ctx: "/a", samples: 60, active: 60),
        mkInterval(1800, 1820, bundle: "com.unmatched", app: "Thing", ctx: "/b", samples: 1, active: 1),
    ]
    let noise = renderDay(withNoise, bucketSecs: 1800, rules: dayRules, timeZone: utc,
                          from: 0, to: 86400, options: opts)
    // Scoped to the totals block. The timeline is a time axis, so a bucket whose only
    // activity was unclear is still honestly labelled unclear there.
    let noiseTotals = noise.components(separatedBy: "TOTALS").last ?? ""
    t.expect(noiseTotals.contains("work"), "a category worth reporting is printed")
    t.expect(!noiseTotals.contains("unclear"),
             "a category that rounds to 0m is not printed among the totals")
    // It is still counted, so the percentages stay truthful about the whole.
    t.expect(noise.contains("tracked 30m"), "the dropped category is still inside tracked time")

    // --- common app names fit the column ---
    // "Goog…hrome" is not a readable app name. Browsers and PWAs are the apps most
    // often in focus, so the column has to hold their real names.
    let longApps = [
        mkInterval(0, 1800, bundle: "com.test.work", app: "Google Chrome", ctx: "/a",
                   samples: 60, active: 60),
        mkInterval(1800, 3600, bundle: "com.test.fun", app: "Microsoft Edge", ctx: "/b",
                   samples: 60, active: 60),
    ]
    let apps = renderDay(longApps, bucketSecs: 1800, rules: dayRules, timeZone: utc,
                         from: 0, to: 86400, options: opts)
    t.expect(apps.contains("Google Chrome"), "a 13-character app name is not cut")
    t.expect(apps.contains("Microsoft Edge"), "a 14-character app name is not cut")
    t.expect(!apps.contains("…hrome"), "no app name is ellipsized mid-word")
}

@MainActor func weekRangeTests(_ t: T) {
    let ny = TimeZone(identifier: "America/New_York")!
    let noonOct1 = 1_790_856_000   // 2026-10-01 12:00 UTC, a Thursday

    // --- weekRange: the calendar week containing the date, starting Monday ---
    let mid = weekRange("2026-10-01", now: 0, timeZone: utc)
    t.eq(mid.from, 1_790_553_600, "a Thursday resolves to the Monday of its week")
    t.eq(mid.to, 1_791_158_400, "and ends at the following Monday")

    let onMonday = weekRange("2026-09-28", now: 0, timeZone: utc)
    t.eq(onMonday.from, 1_790_553_600, "a Monday is the start of its own week")

    // Sunday is the END of the week, not the start of the next one. Treating it as a
    // start is the classic off-by-one here, and it would silently report the wrong
    // seven days.
    let onSunday = weekRange("2026-10-04", now: 0, timeZone: utc)
    t.eq(onSunday.from, 1_790_553_600, "a Sunday belongs to the week that began that Monday")

    // --- DST ---
    // A week is seven calendar days, not 7 x 86400. Stepping by seconds across a
    // spring-forward lands every later day an hour early, so the whole week's buckets
    // shift and the last day is cut short.
    let dstWeek = weekRange("2026-03-02", now: 0, timeZone: ny)
    t.eq(dstWeek.from, 1_772_427_600, "the DST week starts at local midnight Monday")
    t.eq(dstWeek.to, 1_773_028_800, "and ends at local midnight the next Monday")
    t.eq(dstWeek.to - dstWeek.from, 601_200,
         "the week spans an hour less than 7 x 86400 because the clocks went forward")

    // --- dayStarts: one local midnight per day, DST included ---
    let starts = dayStarts(from: dstWeek.from, to: dstWeek.to, timeZone: ny)
    t.eq(starts.count, 7, "seven days in the week despite the short one")
    t.eq(starts.first, dstWeek.from, "the first day is the range start")
    let diffs = zip(starts.dropFirst(), starts).map { $0 - $1 }
    t.eq(diffs.count, 6, "seven starts give six gaps between them")
    t.expect(diffs.allSatisfy { $0 == 86_400 },
             "every gap between two local midnights before the change is a full day")
    // The short day is the last one in the range: its start is the final midnight and
    // its end is the range end, which the clock change makes 23 hours later.
    t.eq(dstWeek.to - (starts.last ?? 0), 82_800,
         "the day the clocks went forward is 23 hours long")

    // --- sinceRange: the last N days, today included ---
    let since3 = sinceRange(days: 3, now: noonOct1, timeZone: utc)
    t.eq(since3.to, 1_790_899_200, "the range ends at the start of tomorrow")
    t.eq(since3.from, 1_790_640_000, "three days ending today starts on 29 September")
    t.eq(dayStarts(from: since3.from, to: since3.to, timeZone: utc).count, 3,
         "a three-day range covers three days")
    let since1 = sinceRange(days: 1, now: noonOct1, timeZone: utc)
    t.eq(dayStarts(from: since1.from, to: since1.to, timeZone: utc).count, 1,
         "one day means today alone")
}

@MainActor func weekRenderTests(_ t: T) {
    let opts = RenderOptions(width: 100, color: false, home: "/Users/alex")
    let mon = 1_790_553_600, tue = 1_790_640_000, thu = 1_790_812_800

    let ivs = [
        mkInterval(mon, mon + 7200, bundle: "com.test.work", app: "Ghostty", ctx: "/a",
                   samples: 240, active: 240),
        mkInterval(mon + 7200, mon + 9000, bundle: "com.test.fun", app: "Edge", ctx: "/b",
                   samples: 60, active: 60),
        mkInterval(tue, tue + 3600, bundle: "com.test.work", app: "Ghostty", ctx: "/a",
                   samples: 120, active: 120),
    ]
    let text = renderWeek(ivs, bucketSecs: 1800, rules: dayRules, timeZone: utc,
                          from: mon, to: thu, options: opts)

    // --- one row per day in the range, including days with nothing ---
    t.expect(text.contains("Mon 28"), "Monday has a row")
    t.expect(text.contains("Tue 29"), "Tuesday has a row")
    t.expect(text.contains("Wed 30"), "a day with no activity still has a row")
    t.expect(!text.contains("Thu"), "the day after the range is not shown")

    // --- single-digit day numbers line up with two-digit ones ---
    // "Thu 1" beside "Mon 28" leaves the numbers in different columns, which is exactly
    // what a table of numbers must not do.
    let acrossMonth = renderWeek(
        [mkInterval(1_790_726_400, 1_790_730_000, bundle: "com.test.work", app: "Ghostty",
                    ctx: "/a", samples: 120, active: 120)],
        bucketSecs: 1800, rules: dayRules, timeZone: utc,
        from: 1_790_726_400, to: 1_790_899_200, options: opts)
    t.expect(acrossMonth.contains("Wed 30"), "a two-digit day is unpadded")
    t.expect(acrossMonth.contains("Thu  1"),
             "a single-digit day is padded so the numbers share a column")

    // --- the totals row is the sum of the day rows ---
    t.expect(text.contains("3h 00m"), "work totals three hours across the week")
    t.expect(text.contains("3h 30m"), "tracked time totals three and a half hours")

    // --- percentages of the week's tracked time ---
    t.expect(text.contains("86%"), "work is 86% of the week")
    t.expect(text.contains("14%"), "fun is 14% of the week")

    // --- away time is reported, not silently dropped ---
    let withAway = renderWeek(ivs + [mkInterval(mon + 20000, mon + 27200, kind: .gap, samples: 0, active: 0)],
                              bucketSecs: 1800, rules: dayRules, timeZone: utc,
                              from: mon, to: thu, options: opts)
    t.expect(withAway.contains("away"), "the week reports time away from the machine")
    t.expect(withAway.contains("no data 2h 00m"), "and distinguishes missing data")

    // --- many categories collapse into an "other" column ---
    // A week can touch a dozen categories, and a dozen columns is not a table anyone
    // can read. The long tail is summed rather than dropped, so the row still adds up.
    var manyRules = [Rule]()
    var manyIvs = [Interval]()
    for i in 0..<8 {
        manyRules.append(Rule(app: "com.test.c\(i)", appName: nil, context: nil, category: "cat\(i)"))
        // Descending durations, so which categories make the top five is unambiguous.
        manyIvs.append(mkInterval(mon + i * 3600, mon + i * 3600 + (8 - i) * 600,
                                  bundle: "com.test.c\(i)", app: "App", ctx: "/x",
                                  samples: 20, active: 20))
    }
    let many = renderWeek(manyIvs, bucketSecs: 1800,
                          rules: RuleSet(defaultCategory: "unclear", rules: manyRules),
                          timeZone: utc, from: mon, to: thu, options: opts)
    for i in 0..<5 { t.expect(many.contains("cat\(i)"), "cat\(i) is among the top five columns") }
    t.expect(!many.contains("cat6"), "the sixth-ranked category has no column of its own")
    t.expect(many.contains("other"), "the long tail is summed into an other column")
    // cat5 + cat6 + cat7 = 1800 + 1200 + 600 = 3600s
    t.expect(many.contains("1h 00m"), "the other column carries the tail's real total")

    // --- exact layout, as a guard against accidental drift ---
    let expected = [
        "Mon 28 Sep 2026 ─ Wed 30 Sep 2026",
        "",
        "             work   fun   tracked",
        "  Mon 28   2h 00m   30m    2h 30m",
        "  Tue 29   1h 00m          1h 00m",
        "  Wed 30",
        "  ───────────────────────────────",
        "  total    3h 00m   30m    3h 30m",
        "              86%   14%",
    ].joined(separator: "\n")
    t.eq(text, expected, "the rendered week matches the agreed layout exactly")
}

/// Remove ANSI escape sequences, so a coloured line can be compared with the plain
/// one it must be identical to.
private func stripANSI(_ s: String) -> String {
    var out = "", inEscape = false
    for ch in s {
        if inEscape {
            if ch == "m" { inEscape = false }
        } else if ch == "\u{1B}" {
            inEscape = true
        } else {
            out.append(ch)
        }
    }
    return out
}

@MainActor func widthAndColorTests(_ t: T) {
    // --- clampWidth ---
    // A terminal narrower than 80 cannot hold the table, and beyond 160 the breakdown
    // labels drift so far from their durations that the alignment stops helping.
    t.eq(clampWidth(nil), 100, "an unknown terminal width falls back to 100")
    t.eq(clampWidth(40), 80, "a very narrow terminal is clamped up to 80")
    t.eq(clampWidth(200), 160, "a very wide terminal is clamped down to 160")
    t.eq(clampWidth(120), 120, "a width inside the range is used as given")
    t.eq(clampWidth(80), 80, "the lower bound is allowed")
    t.eq(clampWidth(160), 160, "the upper bound is allowed")
    t.eq(clampWidth(0), 80, "a zero reading is treated as too narrow, not as unknown")

    // --- colorize ---
    t.eq(colorize("work", 36, enabled: false), "work", "colour disabled leaves the text alone")
    t.eq(colorize("work", 36, enabled: true), "\u{1B}[36mwork\u{1B}[0m",
         "colour enabled wraps the text in the escape and resets after it")
    t.eq(stripANSI(colorize("work", 36, enabled: true)), "work", "stripping the escape recovers the text")

    // --- colour never changes the layout ---
    // The escape sequences have no width on screen but plenty in a String, so padding
    // has to be applied before colouring. Getting that backwards misaligns every
    // column, and only in the coloured output, where no plain-text test would see it.
    let ivs = [
        mkInterval(0, 3000, bundle: "com.test.work", app: "Ghostty", ctx: "/Users/alex/a",
                   samples: 100, active: 85),
        mkInterval(3000, 3600, bundle: "com.test.fun", app: "Edge", ctx: "youtube.com/watch",
                   samples: 20, active: 2, engaged: 18),
        mkInterval(3600, 7200, kind: .gap, samples: 0, active: 0),
    ]
    let plain = renderDay(ivs, bucketSecs: 1800, rules: dayRules, timeZone: utc, from: 0, to: 86400,
                          options: RenderOptions(width: 100, color: false, home: "/Users/alex"))
    let coloured = renderDay(ivs, bucketSecs: 1800, rules: dayRules, timeZone: utc, from: 0, to: 86400,
                             options: RenderOptions(width: 100, color: true, home: "/Users/alex"))
    t.expect(coloured.contains("\u{1B}["), "the coloured render actually emits escapes")
    t.eq(stripANSI(coloured), plain, "stripping the colour yields exactly the plain layout")

    // Two categories must not share a colour, or the colour carries no information.
    let codes = Set(coloured.components(separatedBy: "\u{1B}[").dropFirst().compactMap {
        $0.components(separatedBy: "m").first
    }).subtracting(["0"])
    t.expect(codes.count >= 2, "distinct categories get distinct colours, got \(codes.sorted())")

    // The same must hold for the week table.
    let plainWeek = renderWeek(ivs, bucketSecs: 1800, rules: dayRules, timeZone: utc,
                               from: 0, to: 86400,
                               options: RenderOptions(width: 100, color: false, home: "/Users/alex"))
    let colouredWeek = renderWeek(ivs, bucketSecs: 1800, rules: dayRules, timeZone: utc,
                                  from: 0, to: 86400,
                                  options: RenderOptions(width: 100, color: true, home: "/Users/alex"))
    t.expect(colouredWeek.contains("\u{1B}["), "the coloured week emits escapes")
    t.eq(stripANSI(colouredWeek), plainWeek, "stripping the week's colour yields the plain layout")
}

@MainActor func reportArgsTests(_ t: T) {
    func req(_ args: [String]) -> ReportRequest? {
        if case .report(let r) = parseArgs(args) { return r }
        return nil
    }

    // --- the existing forms still mean what they meant ---
    t.eq(req(["report"])?.span, ReportRequest.Span.day, "a bare report is a single day")
    t.eq(req(["report"])?.date, nil, "with no date")
    t.eq(req(["report", "--date", "2026-09-30"])?.date, "2026-09-30", "--date is carried through")
    t.eq(req(["report", "--date", "2026-09-30"])?.span, ReportRequest.Span.day,
         "--date alone is still a single day")
    t.eq(parseArgs(["sample"]), Command.sample, "sample is unaffected")
    t.eq(parseArgs(["doctor"]), Command.doctor, "doctor is unaffected")
    t.eq(parseArgs([]), Command.help, "no arguments is help")

    // --- the new spans ---
    t.eq(req(["report", "--week"])?.span, ReportRequest.Span.week, "--week selects the week view")
    t.eq(req(["report", "--week", "--date", "2026-09-30"])?.date, "2026-09-30",
         "--week takes a date, meaning the week containing it")
    t.eq(req(["report", "--since", "7"])?.span, ReportRequest.Span.since(7), "--since takes a day count")

    // --- presentation flags, in any order ---
    t.eq(req(["report", "--no-color"])?.color, false, "--no-color forces colour off")
    t.eq(req(["report"])?.color, nil, "without the flag the choice is left to the caller to detect")
    t.eq(req(["report", "--width", "120"])?.width, 120, "--width is carried through")
    t.eq(req(["report"])?.width, nil, "without the flag the width is left to be detected")
    t.eq(req(["report", "--width", "120", "--week", "--no-color"])?.span, ReportRequest.Span.week,
         "flags may come in any order")
    t.eq(req(["report", "--no-color", "--width", "90", "--date", "2026-09-30"])?.width, 90,
         "and combine freely")

    // --- malformed input is refused, never guessed ---
    // A typo that silently reports the wrong range is worse than one that prints usage.
    // These are usage ERRORS, not help requests. Reporting them as `.help` makes the
    // process exit 0, so a script that mistypes a flag gets a successful-looking run
    // and a report for the wrong range.
    t.eq(parseArgs(["report", "--since", "abc"]), Command.usageError, "a non-numeric --since is refused")
    t.eq(parseArgs(["report", "--since", "0"]), Command.usageError, "a --since of zero days is refused")
    t.eq(parseArgs(["report", "--since", "-3"]), Command.usageError, "a negative --since is refused")
    t.eq(parseArgs(["report", "--since"]), Command.usageError, "--since with no value is refused")
    t.eq(parseArgs(["report", "--width", "abc"]), Command.usageError, "a non-numeric --width is refused")
    t.eq(parseArgs(["report", "--date"]), Command.usageError, "--date with no value is refused")
    t.eq(parseArgs(["report", "--nonsense"]), Command.usageError, "an unknown flag is refused")
    t.eq(parseArgs(["report", "2026-09-30"]), Command.usageError, "a bare positional argument is refused")
    t.eq(parseArgs(["nonsense"]), Command.usageError, "an unknown subcommand is a usage error")
    // Two spans at once has no single correct reading, so it is refused rather than
    // resolved by whichever happened to be parsed last.
    t.eq(parseArgs(["report", "--week", "--since", "7"]), Command.usageError,
         "asking for a week and a day count at once is refused")
    // Asking for help IS a success. Only malformed input is an error.
    t.eq(parseArgs([]), Command.help, "no arguments asks for help rather than erring")
    t.eq(parseArgs(["--help"]), Command.help, "--help asks for help")
    t.eq(parseArgs(["help"]), Command.help, "so does the bare word")
}

@MainActor func idleCountsTests(_ t: T) {
    // --- the parser accepts an unquoted boolean ---
    // TOML booleans are bare words. Requiring idle_counts = "true" would be
    // non-standard and would read as a string that happens to spell a boolean.
    let parsed = try? parseRules("""
    default = "unclear"

    [[rule]]
    app_name = "Google Meet"
    category = "work/Meeting"
    idle_counts = true

    [[rule]]
    app = "com.apple.Terminal"
    category = "work"
    """, homeDirectory: "/Users/alex")
    t.expect(parsed != nil, "a rule file with idle_counts parses")
    let meetRule = parsed?.rules.first { $0.appName == "Google Meet" }
    let termRule = parsed?.rules.first { $0.app == "com.apple.Terminal" }
    t.eq(meetRule?.idleCounts, true, "idle_counts = true is read as true")
    // Defaulting to false matters: every existing rule file omits the key, and idle
    // must keep meaning "away" for all of them.
    t.eq(termRule?.idleCounts, false, "a rule without idle_counts defaults to false")

    func rejects(_ body: String, _ name: String) {
        let r = try? parseRules("default = \"x\"\n\n[[rule]]\napp = \"a\"\ncategory = \"c\"\n\(body)",
                                homeDirectory: "/Users/alex")
        t.expect(r == nil, name)
    }
    rejects("idle_counts = maybe", "a non-boolean idle_counts is refused")
    rejects("idle_counts = \"true\"", "a quoted idle_counts is refused, being the wrong type")
    rejects("category = yes", "an unquoted string value is still refused")

    // --- matchingRule, which is what lets the caller see the flag ---
    let rules = RuleSet(defaultCategory: "unclear", rules: [
        Rule(app: nil, appName: "Google Meet", context: nil, category: "work/Meeting", idleCounts: true),
        Rule(app: "com.test.term", appName: nil, context: nil, category: "work", idleCounts: false),
    ])
    let meetIv = mkInterval(0, 600, bundle: "com.google.Chrome.app.abc", app: "Google Meet",
                            ctx: nil, kind: .idle, samples: 20, active: 0)
    t.eq(matchingRule(meetIv, with: rules)?.category, "work/Meeting", "the matching rule is returned")
    t.eq(matchingRule(mkInterval(0, 60, bundle: "com.nope", app: "Nope"), with: rules)?.category, nil,
         "no match returns nil rather than the default category")
    // classify must keep behaving exactly as before.
    t.eq(classify(meetIv, with: rules), "work/Meeting", "classify still returns the category")
    t.eq(classify(mkInterval(0, 60, bundle: "com.nope", app: "Nope"), with: rules), "unclear",
         "classify still falls back to the default")

    // --- idle time is reclassified only when the rule opts in ---
    let meetSlices = slice([meetIv], bucketSecs: 1800, rules: rules)
    t.eq(meetSlices.first?.category, "work/Meeting",
         "idle in an app whose rule opts in takes the rule's category")
    // Walking away from a terminal must stay idle. Classifying all idle time by app
    // would quietly turn every coffee break into work.
    let termIdle = mkInterval(0, 600, bundle: "com.test.term", app: "Ghostty",
                              ctx: "/a", kind: .idle, samples: 20, active: 0)
    t.eq(slice([termIdle], bucketSecs: 1800, rules: rules).first?.category, "idle",
         "idle in an app whose rule does not opt in stays idle")
    // An idle interval matching no rule must not become the default category: the
    // default is for unclassified ACTIVITY, and this is absence of activity.
    let strangerIdle = mkInterval(0, 600, bundle: "com.unknown", app: "Unknown",
                                  ctx: nil, kind: .idle, samples: 20, active: 0)
    t.eq(slice([strangerIdle], bucketSecs: 1800, rules: rules).first?.category, "idle",
         "idle matching no rule stays idle, not the default category")

    // --- locked and gap are never reclassified ---
    // A locked screen means you left, whatever was on it. Spec §5.2.
    let meetLocked = mkInterval(0, 600, bundle: "com.google.Chrome.app.abc", app: "Google Meet",
                                ctx: nil, kind: .locked, samples: 20, active: 0)
    t.eq(slice([meetLocked], bucketSecs: 1800, rules: rules).first?.category, "locked",
         "a locked screen stays locked even for an opted-in app")
    let meetGap = mkInterval(0, 600, bundle: "com.google.Chrome.app.abc", app: "Google Meet",
                             ctx: nil, kind: .gap, samples: 0, active: 0)
    t.eq(slice([meetGap], bucketSecs: 1800, rules: rules).first?.category, "gap",
         "a gap stays a gap even for an opted-in app")

    // --- a context rule works too, so a call in any browser counts ---
    let ctxRules = RuleSet(defaultCategory: "unclear", rules: [
        Rule(app: nil, appName: nil, context: "*meet.google.com/*", category: "work/Meeting",
             idleCounts: true),
    ])
    let browserIdle = mkInterval(0, 600, bundle: "com.microsoft.edgemac", app: "Microsoft Edge",
                                 ctx: "meet.google.com/abc-defg-hij", kind: .idle,
                                 samples: 20, active: 0)
    t.eq(slice([browserIdle], bucketSecs: 1800, rules: ctxRules).first?.category, "work/Meeting",
         "a context rule reclassifies idle in any browser")

    // --- the reclassified time is honestly marked as hands-off ---
    // It lands in work, but with no input, so work's active share falls. That is the
    // only visible trace of "joined a meeting and wandered off".
    let mixed = [
        mkInterval(0, 600, bundle: "com.test.term", app: "Ghostty", ctx: "/a",
                   kind: .app, samples: 20, active: 20),
        meetIv,
    ]
    let tot = totals(slice(mixed, bucketSecs: 1800, rules: rules))
    let work = tot.first { $0.category == "work" }
    t.eq(work?.seconds, 1200, "both the typed and the listened time land under work")
    t.eq(work?.activeSeconds, 600, "but only the typed half counts as active")
    t.eq(percent(work?.activeSeconds ?? 0, of: work?.seconds ?? 1), 50,
         "so the active share halves, which is the visible trace of listening")
}
