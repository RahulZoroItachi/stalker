import Foundation
import StalkerCore

/// Tests for the 10-minute grid: the block roll-up and the coloured row renderer.
/// Kept in its own file because the grid is a second, independent view of the same
/// slices and has nothing to say about the tables in ReportTests.

private let utc = TimeZone(identifier: "UTC")!
private let newYork = TimeZone(identifier: "America/New_York")!

private let gridRules = RuleSet(defaultCategory: "unclear", rules: [
    Rule(app: "com.test.work", appName: nil, context: nil, category: "work"),
    Rule(app: "com.test.fun", appName: nil, context: nil, category: "fun"),
    Rule(app: "com.test.meet", appName: nil, context: nil, category: "work/Meeting"),
], activities: ["sleep", "workout"], rest: ["sleep"])

/// Local midnight, built the same way the report builds it, so a DST day is as long
/// as it really was rather than as long as arithmetic would make it.
private func localMidnight(_ y: Int, _ m: Int, _ d: Int, _ tz: TimeZone) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return Int(cal.date(from: DateComponents(year: y, month: m, day: d))!.timeIntervalSince1970)
}

@MainActor func gridTests(_ t: T) {
    let mon = localMidnight(2026, 9, 28, utc)

    // --- one entry per ten minutes of the local day ---
    let work = mkInterval(mon, mon + 86400, bundle: "com.test.work", app: "Ghostty",
                          ctx: "/a", samples: 2880, active: 2880)
    t.eq(gridBlocks([work], rules: gridRules, dayFrom: mon, dayTo: mon + 86400).count, 144,
         "a 24-hour day is 144 ten-minute blocks")

    // --- a DST day is as long as it actually was ---
    // Padding a 23-hour day out to 144 would put every block after the change in the
    // wrong column, which is the one thing a grid read by position must never do.
    let spring = localMidnight(2026, 3, 8, newYork)
    let springEnd = localMidnight(2026, 3, 9, newYork)
    t.eq(gridBlocks([], rules: gridRules, dayFrom: spring, dayTo: springEnd).count, 138,
         "a spring-forward day is 23 hours, so 138 blocks")

    let autumn = localMidnight(2026, 11, 1, newYork)
    let autumnEnd = localMidnight(2026, 11, 2, newYork)
    t.eq(gridBlocks([], rules: gridRules, dayFrom: autumn, dayTo: autumnEnd).count, 150,
         "a fall-back day is 25 hours, so 150 blocks")

    // --- a block names whichever category held most of it ---
    // Ten minutes split four ways cannot be four colours, so it is the winner's. The
    // alternative is a blended cell, which would read as a category that never existed.
    let mixed = gridBlocks([
        mkInterval(mon, mon + 200, bundle: "com.test.work", app: "Ghostty", ctx: "/a",
                   samples: 7, active: 7),
        mkInterval(mon + 200, mon + 600, bundle: "com.test.fun", app: "Edge",
                   ctx: "youtube.com/watch", samples: 14, active: 14),
    ], rules: gridRules, dayFrom: mon, dayTo: mon + 86400)
    t.eq(mixed[0], "fun", "400 seconds of fun beats 200 of work in the same block")

    // --- a block nothing covered is no data, not a blank ---
    // A day missing from the database and a day spent asleep are different facts, and
    // the grid has to be able to show the difference.
    t.eq(mixed[1], Kind.gap.rawValue, "a block with nothing in it is no data")

    // --- subcategories fold into their parent ---
    // A morning of back-to-back calls is not switching. Giving "work/Meeting" its own
    // colour beside "work" would make it look like it was.
    let meeting = gridBlocks([
        mkInterval(mon, mon + 600, bundle: "com.test.meet", app: "Zoom", ctx: "/call",
                   samples: 20, active: 20),
    ], rules: gridRules, dayFrom: mon, dayTo: mon + 86400)
    t.eq(meeting[0], "work", "a work/Meeting block is coloured as work")

    // --- a note claims time the laptop could not explain ---
    // Without this the grid would show a night's sleep as no data, which is the gap the
    // note exists to close.
    let slept = gridBlocks(
        [mkInterval(mon, mon + 3600, kind: .locked, samples: 120, active: 0)],
        notes: [Note(activity: "sleep", span: Span(mon, mon + 3600), line: 1)],
        rules: gridRules, dayFrom: mon, dayTo: mon + 86400)
    t.eq(slept[0], "sleep", "a note over locked time shows the logged activity")
    t.eq(slept[5], "sleep", "and across every block it covers")
    t.eq(slept[6], Kind.gap.rawValue, "but not past where the note ended")
}

/// Everything visible once the escapes are gone.
private func visible(_ s: String) -> String {
    var out = "", inEscape = false
    for ch in s {
        if inEscape {
            if ch == "m" { inEscape = false }
        } else if ch == "\u{1B}" { inEscape = true } else { out.append(ch) }
    }
    return out
}

private func rowFor(_ text: String, _ label: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .first { $0.contains(label) }.map(String.init) ?? ""
}

/// The colour code of block `i` on a line, or -1 when the line has no such block, so a
/// missing row fails the assertion instead of trapping the whole suite.
private func code(_ line: String, _ i: Int) -> Int {
    let all = codes(line)
    return i < all.count ? all[i] : -1
}

/// The colour codes on a line, in order, so block N's colour is `codes(row)[N]`.
private func codes(_ line: String) -> [Int] {
    line.components(separatedBy: "\u{1B}[").dropFirst()
        .compactMap { Int($0.components(separatedBy: "m").first ?? "") }
        .filter { $0 != 0 }
}

@MainActor func gridRenderTests(_ t: T) {
    let mon = localMidnight(2026, 9, 28, utc)
    let wide = RenderOptions(width: 200, color: true, home: "/Users/alex")
    let mono = RenderOptions(width: 200, color: false, home: "/Users/alex")

    // An hour of work, then ten minutes of fun, then nothing for the rest of the week.
    let ivs = [
        mkInterval(mon, mon + 3600, bundle: "com.test.work", app: "Ghostty", ctx: "/a",
                   samples: 120, active: 120),
        mkInterval(mon + 3600, mon + 4200, bundle: "com.test.fun", app: "Edge",
                   ctx: "youtube.com/watch", samples: 20, active: 20),
    ]
    let text = renderGrid(ivs, rules: gridRules, timeZone: utc,
                          from: mon, to: mon + 3 * 86400, options: wide)

    // --- one row per day, including days with nothing ---
    // A blank week and a week the sampler missed look identical without the empty rows.
    t.expect(text.contains("Mon 28"), "Monday has a row")
    t.expect(text.contains("Tue 29"), "Tuesday has a row")
    t.expect(text.contains("Wed 30"), "a day with no activity still has a row")

    let row = rowFor(text, "Mon 28")
    t.eq(visible(row).filter { $0 == "▇" }.count, 144, "a full day is 144 blocks on the row")
    // 2 margin + 6 label + 2 gap + 144 blocks + 23 hour dividers between the 24 sections.
    t.eq(visible(row).count, 177, "the row is exactly 177 columns wide")

    // --- a block's colour is its category's ---
    t.eq(code(row, 0), code(row, 5), "the first hour of work is one colour throughout")
    t.expect(code(row, 6) != code(row, 0), "the fun block that follows is a different colour")
    t.eq(code(row, 100), 90, "a block with no data uses the dim grey the report gives away time")

    // --- the hour ruler ---
    let ruler = text.split(separator: "\n").first { $0.contains("00:00") }.map(String.init) ?? ""
    t.expect(ruler.contains("12:00"), "the ruler ticks through midday")
    t.expect(ruler.contains("22:00"), "and on to the end of the day")
    // Block 0 is the first column of the grid, so its hour label has to sit above it.
    t.eq(visible(ruler).prefix(15), "          00:00", "the first tick sits above the first block")

    // --- switches per day, away stretches ignored ---
    // Six work blocks then one fun block is one switch. Counting the slide into no-data
    // as a switch would make every evening look busy.
    let switches = text.split(separator: "\n").first { $0.contains("switches") }.map(String.init) ?? ""
    t.expect(switches.contains("Mon 28 1"), "Monday counts the one real switch, got: \(visible(switches))")
    t.expect(switches.contains("Tue 29 0"), "a day with nothing in it counts none")

    // --- colour is the only signal the blocks carry ---
    let off = renderGrid(ivs, rules: gridRules, timeZone: utc,
                         from: mon, to: mon + 3 * 86400, options: mono)
    t.expect(!off.contains("▇"), "with colour off no blocks are drawn")
    t.expect(off.contains("omitted"), "and the grid says why it is not there")

    // --- rest is in the grid even though it is out of the tables ---
    // Sleep is excluded from the totals because it would dwarf them. In the grid it is
    // the opposite: a third of the row is sleep, and greying it out would lose the shape
    // of the day.
    let slept = renderGrid(
        [mkInterval(mon, mon + 86400, kind: .locked, samples: 2880, active: 0)],
        notes: [Note(activity: "sleep", span: Span(mon, mon + 25200), line: 1)],
        rules: gridRules, timeZone: utc, from: mon, to: mon + 86400, options: wide)
    t.expect(visible(slept).contains("sleep"), "sleep is named in the legend")
    t.expect(code(rowFor(slept, "Mon 28"), 0) != 90, "and has a colour of its own, not away's grey")

    // --- more categories than the palette holds ---
    // categoryPalette has eight colours. A ninth category reusing the first would put
    // two different things in the same colour, which is worse than not colouring it.
    var manyRules: [Rule] = []
    var manyIvs: [Interval] = []
    for i in 0..<9 {
        manyRules.append(Rule(app: "com.test.c\(i)", appName: nil, context: nil, category: "cat\(i)"))
        // Descending durations, so which categories win a colour is unambiguous.
        manyIvs.append(mkInterval(mon + i * 3600, mon + i * 3600 + (9 - i) * 600,
                                  bundle: "com.test.c\(i)", app: "App", ctx: "/x",
                                  samples: 20, active: 20))
    }
    let many = renderGrid(manyIvs, rules: RuleSet(defaultCategory: "unclear", rules: manyRules),
                          timeZone: utc, from: mon, to: mon + 86400, options: wide)
    t.expect(visible(many).contains("other"), "the category past the palette is folded into other")
    t.expect(!visible(many).contains("cat8"), "and is not named in the legend")
    for i in 0..<8 { t.expect(visible(many).contains("cat\(i)"), "cat\(i) keeps a colour of its own") }

    // --- a colour means the same thing in the grid as in the table above it ---
    // Two views in one report disagreeing about what green means is worse than either
    // having no colour at all.
    let table = renderWeek(ivs, bucketSecs: 1800, rules: gridRules, timeZone: utc,
                           from: mon, to: mon + 3 * 86400, options: wide)
    let header = table.split(separator: "\n").first { $0.contains("work") }.map(String.init) ?? ""
    let workInTable = header.components(separatedBy: "\u{1B}[")
        .first { $0.contains("work") }
        .flatMap { Int($0.components(separatedBy: "m").first ?? "") }
    t.eq(code(row, 0), workInTable, "work is the same colour in the grid as in the week table")
}
