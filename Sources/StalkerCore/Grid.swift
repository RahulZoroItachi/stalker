import Foundation

/// The grid's resolution. Ten minutes is fine enough that a context switch shows as a
/// colour change, and coarse enough that a 24-hour day is 144 cells, which a terminal
/// can hold on one line.
public let gridSeconds = 600

/// The winning category of each ten-minute block of one local day.
///
/// Blocks are measured from `dayFrom` rather than from the absolute epoch alignment
/// `slice` uses. The grid is read by position — the eye compares the same column down
/// the week — so a block boundary has to sit on the local clock. A zone offset by 45
/// minutes would otherwise put every column half a block away from the hour above it.
///
/// The returned count is whatever the day actually was: 138 blocks across a
/// spring-forward, 150 across a fall-back. Padding either to 144 would misplace every
/// block after the change.
public func gridBlocks(_ ivs: [Interval], notes: [Note] = [], rules: RuleSet,
                       dayFrom: Int, dayTo: Int) -> [String] {
    let count = max(0, (dayTo - dayFrom) / gridSeconds)
    guard count > 0 else { return [] }

    // Notes claim only what no app held, same as every other view, so resolution comes
    // before the roll-up rather than being layered on top of it.
    let resolved = resolveNotes(intervals: ivs, notes: notes, range: Span(dayFrom, dayTo))
    var seconds = [[String: Int]](repeating: [:], count: count)

    func add(_ category: String, from start: Int, to end: Int) {
        let lo = max(start, dayFrom), hi = min(end, dayTo)
        guard hi > lo else { return }
        var i = max(0, (lo - dayFrom) / gridSeconds)
        while i < count {
            let blockStart = dayFrom + i * gridSeconds
            if blockStart >= hi { break }
            let secs = min(hi, blockStart + gridSeconds) - max(lo, blockStart)
            if secs > 0 { seconds[i][category, default: 0] += secs }
            i += 1
        }
    }

    // Subcategories are folded into their parent. "work/Meeting" in its own colour
    // would make a day of back-to-back calls look like constant switching.
    for iv in resolved.intervals {
        add(categoryParent(categoryFor(iv, rules: rules)),
            from: iv.startedAt, to: max(iv.endedAt, iv.startedAt))
    }
    for claim in resolved.claims {
        for span in claim.spans { add(claim.activity, from: span.start, to: span.end) }
    }

    // Ties go to the alphabetically first category, matching the day timeline, so the
    // same ten minutes is never named one thing in one view and another elsewhere.
    // A block nothing covered is no data, which is what an unreported day was.
    return seconds.map { cell in
        cell.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key ?? Kind.gap.rawValue
    }
}

/// Seven eighths of the cell, so a hairline of background survives under every row and
/// the days read as separate bands. A full block would fuse the week into one slab and
/// a half block thins each day to the point where a short run disappears.
let gridGlyph = "▇"

/// Plain rather than coloured, so it reads as a rule and not a 25th category, and so it
/// adds nothing to the colour codes a test (or a script) scans the row for.
let hourDivider = "│"

/// Splits a 144-long, ten-minutes-per-block row into 24 one-hour sections by inserting
/// `divider` after every sixth element. The eye can then find an hour mark by its own
/// position in the bar instead of pacing it out against the ruler above.
func withHourDividers<T>(_ items: [T], divider: T) -> [T] {
    var out: [T] = []
    out.reserveCapacity(items.count + items.count / 6)
    for (i, item) in items.enumerated() {
        if i > 0 && i % 6 == 0 { out.append(divider) }
        out.append(item)
    }
    return out
}

/// Everything past the palette shares one neutral grey.
///
/// `categoryPalette` holds eight colours and a real week can touch more categories than
/// that. Wrapping round would put two different categories in the same colour, and a
/// colour that means two things is worse than one that means "not one of the big ones".
let gridOtherColor = 37

/// Categories in the order they take palette colours, longest first.
///
/// The first `weekColumnLimit` are exactly the ones the week table names, in the table's
/// own order, so `colorMap` hands them the same codes it hands the table. A colour that
/// meant one thing in the grid and another in the table above it would be worse than no
/// colour at all.
///
/// Rest follows them rather than competing with them. It has no column in the table, so
/// placing it later cannot disagree with one, and it still earns a colour instead of
/// being greyed out: a third of a row is sleep, and losing that loses the day's shape.
func gridColorOrder(_ seconds: [String: Int], rules: RuleSet) -> [String] {
    func ranked(_ names: [String]) -> [String] {
        names.sorted { (seconds[$0] ?? 0, $1) > (seconds[$1] ?? 0, $0) }
    }
    let main = ranked(seconds.keys.filter {
        !awayCategories.contains($0) && !rules.rest.contains($0)
    })
    let tail = ranked(Array(main.dropFirst(weekColumnLimit))
                      + seconds.keys.filter { rules.rest.contains($0) })
    return Array((Array(main.prefix(weekColumnLimit)) + tail).prefix(categoryPalette.count))
}

/// One row per day, one coloured block per ten minutes.
///
/// A second view of the same slices the tables already describe, answering a question no
/// total can: not how long each category took, but how often the day changed hands. Long
/// runs of one colour are focus; a row that flickers is churn.
public func renderGrid(_ ivs: [Interval], notes: [Note] = [], rules: RuleSet,
                       timeZone: TimeZone, from: Int, to: Int,
                       options: RenderOptions = RenderOptions()) -> String {
    // A cell is a coloured block and nothing else, so with colour off there is nothing
    // left to read. Printing 144 identical characters would be worse than saying so.
    guard options.color else {
        return "grid   omitted: colour is the only signal the blocks carry"
    }

    let days = dayStarts(from: from, to: to, timeZone: timeZone)
    guard !days.isEmpty else { return "" }

    var rows: [(label: String, blocks: [String])] = []
    var seconds: [String: Int] = [:]
    for (i, dayFrom) in days.enumerated() {
        let dayTo = i + 1 < days.count ? days[i + 1] : to
        rows.append((dayLabel(dayFrom, timeZone),
                     gridBlocks(ivs, notes: notes, rules: rules, dayFrom: dayFrom, dayTo: dayTo)))
        // Ranked on real seconds rather than on block counts, because the table ranks on
        // seconds and the two orders have to agree for the colours to agree. Bucket size
        // does not enter into a category total, so 600 here matches the table's 1800.
        let r = resolveNotes(intervals: ivs, notes: notes, range: Span(dayFrom, dayTo))
        for c in totals(slice(r.intervals, bucketSecs: gridSeconds, rules: rules,
                              from: dayFrom, to: dayTo)
                        + noteSlices(r.claims, bucketSecs: gridSeconds)) {
            seconds[c.category, default: 0] += c.seconds
        }
    }

    let order = gridColorOrder(seconds, rules: rules)
    let colors = colorMap(order)
    func paint(_ category: String) -> String {
        let code = awayCategories.contains(category) ? awayColor
                 : (colors[category] ?? gridOtherColor)
        return colorize(gridGlyph, code, enabled: true)
    }

    let labelWidth = rows.map(\.label.count).max() ?? 0
    let indent = String(repeating: " ", count: 2 + labelWidth + 2)
    let widest = rows.map(\.blocks.count).max() ?? 0
    guard widest > 0 else { return "" }

    // --- hour ruler ---
    // Ticks are labelled from the longest day's real timestamps, not from arithmetic on
    // the block index. On a DST day the two disagree, and the ruler has to name the hour
    // actually sitting above the column.
    let longest = days[rows.firstIndex { $0.blocks.count == widest } ?? 0]
    var ruler = Array(repeating: Character(" "), count: widest)
    for b in stride(from: 0, to: widest, by: 12) {
        for (k, ch) in clockTime(longest + b * gridSeconds, timeZone).enumerated()
        where b + k < widest {
            ruler[b + k] = ch
        }
    }
    // Widened by the same rule as the rows below, with blanks rather than dividers, so
    // a label still sits above the hour it names once the row grows past 144 columns.
    ruler = withHourDividers(ruler, divider: " ")
    // A trailing-whitespace line is noise in a diff or a paste, same as in the table.
    var rulerLine = indent + String(ruler)
    while rulerLine.hasSuffix(" ") { rulerLine.removeLast() }
    var lines = [rulerLine]

    for r in rows {
        lines.append("  " + padded(r.label, labelWidth) + "  "
                     + withHourDividers(r.blocks.map(paint), divider: hourDivider).joined())
    }

    // --- legend ---
    var legend = order.map { paint($0) + " " + $0 }
    if seconds.keys.contains(where: { !awayCategories.contains($0) && colors[$0] == nil }) {
        legend.append(colorize(gridGlyph, gridOtherColor, enabled: true) + " other")
    }
    if seconds.keys.contains(where: { awayCategories.contains($0) }) {
        legend.append(colorize(gridGlyph, awayColor, enabled: true) + " away")
    }
    lines.append("")
    lines.append(indent + legend.joined(separator: "   "))

    // --- switches ---
    // Away blocks are removed before counting rather than treated as a category, so the
    // slide into an empty evening is not charged as a switch. Returning to work after
    // lunch is one switch, not two.
    let counted = rows.map { r -> String in
        let real = r.blocks.filter { !awayCategories.contains($0) }
        return "\(r.label) \(zip(real, real.dropFirst()).filter { $0 != $1 }.count)"
    }
    lines.append(indent + "switches   " + counted.joined(separator: "   "))

    return lines.joined(separator: "\n")
}
