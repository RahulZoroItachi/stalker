import Foundation

/// How many categories get a column of their own before the rest are summed.
///
/// A week can touch a dozen categories, and a dozen columns is not a table anyone can
/// read. The tail is summed into `other` rather than dropped, so every row still adds
/// up to its tracked figure.
let weekColumnLimit = 6

private func calendar(_ tz: TimeZone) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    // Monday. The week starts on a working day, and Sunday-first would put the weekend
    // either side of the week it belongs to.
    cal.firstWeekday = 2
    return cal
}

/// Start of each local day in `[from, to)`.
///
/// Stepped with `Calendar`, not by adding 86,400. Across a spring-forward every later
/// day would land an hour early, shifting the whole week's buckets and cutting the
/// last day short.
public func dayStarts(from: Int, to: Int, timeZone: TimeZone) -> [Int] {
    let cal = calendar(timeZone)
    var out: [Int] = []
    var day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(from)))
    while Int(day.timeIntervalSince1970) < to {
        out.append(Int(day.timeIntervalSince1970))
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
    }
    return out
}

/// The calendar week containing `dateString`, Monday to Monday.
public func weekRange(_ dateString: String?, now: Int, timeZone: TimeZone) -> (from: Int, to: Int) {
    let cal = calendar(timeZone)
    let reference: Date
    if let dateString {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        reference = f.date(from: dateString) ?? Date(timeIntervalSince1970: TimeInterval(now))
    } else {
        reference = Date(timeIntervalSince1970: TimeInterval(now))
    }

    let startOfDay = cal.startOfDay(for: reference)
    // Days since Monday. `weekday` is 1-based from Sunday, so Sunday maps to 6 rather
    // than 0: it ends the week that began six days earlier, it does not start a new one.
    let weekday = cal.component(.weekday, from: startOfDay)
    let daysSinceMonday = (weekday + 5) % 7
    let monday = cal.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay) ?? startOfDay
    let next = cal.date(byAdding: .day, value: 7, to: monday) ?? monday
    return (Int(monday.timeIntervalSince1970), Int(next.timeIntervalSince1970))
}

/// The last `days` local days, today included, ending at the start of tomorrow.
public func sinceRange(days: Int, now: Int, timeZone: TimeZone) -> (from: Int, to: Int) {
    let cal = calendar(timeZone)
    let today = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now)))
    let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today
    let start = cal.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
    return (Int(start.timeIntervalSince1970), Int(tomorrow.timeIntervalSince1970))
}

/// "Mon 28", with single-digit days space-padded to "Thu  1".
///
/// The day number is a number in a table of numbers, so it is right-aligned. A plain
/// "EEE d" leaves the 1st of the month in a different column from the 28th.
func dayLabel(_ ts: Int, _ tz: TimeZone) -> String {
    let f = DateFormatter()
    f.timeZone = tz
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE"
    let date = Date(timeIntervalSince1970: TimeInterval(ts))
    let day = calendar(tz).component(.day, from: date)
    return f.string(from: date) + " " + rightAligned("\(day)", 2)
}

/// One row per day, one column per category, for a range of days.
public func renderWeek(_ ivs: [Interval], notes: [Note] = [], bucketSecs: Int, rules: RuleSet,
                       timeZone: TimeZone, from: Int, to: Int,
                       options: RenderOptions = RenderOptions()) -> String {
    let days = dayStarts(from: from, to: to, timeZone: timeZone)
    let lastDay = days.last ?? from
    var lines = [dayHeading(from, timeZone) + " ─ " + dayHeading(lastDay, timeZone), ""]

    /// Category totals for one day, with notes resolved against that day's window.
    ///
    /// Per day rather than per week, so a note crossing midnight contributes to each day
    /// the part that actually falls in it.
    func catsFor(_ dayFrom: Int, _ dayTo: Int) -> [CategoryTotal] {
        let r = resolveNotes(intervals: ivs, notes: notes, range: Span(dayFrom, dayTo))
        return totals(slice(r.intervals, bucketSecs: bucketSecs, rules: rules,
                            from: dayFrom, to: dayTo)
                      + noteSlices(r.claims, bucketSecs: bucketSecs))
    }

    var dayCats: [(label: String, cats: [CategoryTotal])] = []
    for (i, dayFrom) in days.enumerated() {
        let dayTo = i + 1 < days.count ? days[i + 1] : to
        dayCats.append((dayLabel(dayFrom, timeZone), catsFor(dayFrom, dayTo)))
    }

    // Summed from the days rather than recomputed over the range, so the total row is
    // the sum of the rows above it by construction and cannot drift from them.
    var weekSeconds: [String: Int] = [:]
    for d in dayCats { for c in d.cats { weekSeconds[c.category, default: 0] += c.seconds } }
    guard !weekSeconds.isEmpty else {
        lines.append("no activity recorded")
        return lines.joined(separator: "\n")
    }

    // Rest is excluded from the table as well as from the total: it would be the widest
    // column every week and say nothing you did not already know.
    func inList(_ c: String) -> Bool { !awayCategories.contains(c) && !rules.rest.contains(c) }
    let hasLogged = rules.activities.contains { (weekSeconds[$0] ?? 0) > 0 }

    let locked = weekSeconds[Kind.locked.rawValue] ?? 0
    let gap = weekSeconds[Kind.gap.rawValue] ?? 0
    // Once some away time has a reason, "away" is the wrong word for what is left. The
    // day report draws the same distinction, and the column heading has to use the word
    // the line below the table uses.
    let awayLabel = hasLogged ? "unaccounted" : "away"
    // Only when there is some. A column of blank cells would widen the table to say
    // nothing, and a week with no gaps in it is the week that needs the room least.
    let hasAway = locked + gap > 0

    let ranked = weekSeconds.filter { inList($0.key) }
        .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
    let named = ranked.prefix(weekColumnLimit).map(\.key)
    let hasOther = ranked.count > weekColumnLimit
    // Away sits past the total rather than among the categories. The total is the sum of
    // the columns to its left, and folding a night's sleep into it would make "logged"
    // mean something it does not.
    let columns = named + (hasOther ? ["other"] : []) + [hasLogged ? "logged" : "tracked"]
                  + (hasAway ? [awayLabel] : [])

    /// Seconds per column for one day, in `columns` order.
    func cells(_ cats: [CategoryTotal]) -> [Int] {
        let byName = Dictionary(uniqueKeysWithValues:
            cats.filter { inList($0.category) }.map { ($0.category, $0.seconds) })
        var row = named.map { byName[$0] ?? 0 }
        if hasOther {
            row.append(byName.filter { !named.contains($0.key) }.values.reduce(0, +))
        }
        row.append(byName.values.reduce(0, +))
        // Read off the day's own categories, not from the week total, so the column
        // shows which days the time went missing rather than only how much did.
        if hasAway {
            row.append(cats.filter { awayCategories.contains($0.category) }
                           .reduce(0) { $0 + $1.seconds })
        }
        return row
    }

    let rows = dayCats.map { (label: $0.label, cells: cells($0.cats)) }
    var totalCells = Array(repeating: 0, count: columns.count)
    for r in rows { for (i, v) in r.cells.enumerated() { totalCells[i] += v } }

    // A blank cell rather than "0m": the eye should land on the days that happened.
    func cellText(_ seconds: Int) -> String { seconds >= 60 ? formatDuration(seconds) : "" }

    // Each column is as wide as the widest thing in it, so the table holds whatever
    // durations the week actually produced.
    let labelWidth = max(rows.map(\.label.count).max() ?? 0, "total".count)
    var widths: [Int] = []
    for (c, name) in columns.enumerated() {
        let values = (rows.map { cellText($0.cells[c]) } + [cellText(totalCells[c])])
        widths.append(max(name.count, values.map(\.count).max() ?? 0) + 3)
    }

    // Only the named categories take a palette colour. `other` is a bucket rather than a
    // category and `tracked` is the sum of them all, so neither owns one. Away gets the
    // same grey it has everywhere else: it is context, not content, so it recedes.
    var colors = colorMap(named)
    if hasAway { colors[awayLabel] = awayColor }
    func row(_ label: String, _ texts: [String], paint: Bool = false) -> String {
        var line = "  " + padded(label, labelWidth)
        for (c, text) in texts.enumerated() {
            // Aligned first, coloured second: the escapes have no width on screen but
            // plenty in a String, so colouring first would misalign the whole table.
            let cell = rightAligned(text, widths[c])
            line += paint ? colorize(cell, colors[columns[c]] ?? 0,
                                     enabled: options.color && colors[columns[c]] != nil)
                          : cell
        }
        // Trailing blanks carry no information and a trailing-whitespace line is noise
        // in a diff or a paste.
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }

    lines.append(row("", columns, paint: true))
    for r in rows { lines.append(row(r.label, r.cells.map(cellText))) }

    let tableWidth = 2 + labelWidth + widths.reduce(0, +)
    lines.append("  " + String(repeating: "─", count: max(0, tableWidth - 2)))
    lines.append(row("total", totalCells.map(cellText)))

    // Percentages of the range's tracked time. The tracked column itself is always
    // 100%, so it is left blank rather than stating the obvious, and away is left blank
    // because it is not a share of tracked time at all: nine hours asleep against seven
    // hours worked would print 128%.
    let trackedColumn = columns.count - (hasAway ? 2 : 1)
    let tracked = totalCells[trackedColumn]
    let shares = columns.indices.map { i in
        i < trackedColumn && totalCells[i] > 0 ? "\(percent(totalCells[i], of: tracked))%" : ""
    }
    lines.append(row("", shares))

    // Rest, below the table rather than inside it.
    let restNames = rules.rest.filter { (weekSeconds[$0] ?? 0) >= 60 }.sorted()
    if !restNames.isEmpty {
        lines.append("")
        for name in restNames {
            lines.append("\(name)  \(formatDuration(weekSeconds[name] ?? 0))")
        }
    }

    // The column carries the figure now, so this line carries only what one column
    // cannot: how much of it was a locked screen and how much was a sampler recording
    // nothing. A week asleep and a week with a dead sampler share an away total and
    // nothing else.
    if hasAway {
        var parts: [String] = []
        if locked > 0 { parts.append("locked \(formatDuration(locked))") }
        if gap > 0 { parts.append("no data \(formatDuration(gap))") }
        if restNames.isEmpty { lines.append("") }
        lines.append("\(awayLabel)  " + parts.joined(separator: " · "))
    }

    return lines.joined(separator: "\n")
}
