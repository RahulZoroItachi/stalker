import Foundation

/// How many categories get a column of their own before the rest are summed.
///
/// A week can touch a dozen categories, and a dozen columns is not a table anyone can
/// read. The tail is summed into `other` rather than dropped, so every row still adds
/// up to its tracked figure.
let weekColumnLimit = 5

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
private func dayLabel(_ ts: Int, _ tz: TimeZone) -> String {
    let f = DateFormatter()
    f.timeZone = tz
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE"
    let date = Date(timeIntervalSince1970: TimeInterval(ts))
    let day = calendar(tz).component(.day, from: date)
    return f.string(from: date) + " " + rightAligned("\(day)", 2)
}

/// One row per day, one column per category, for a range of days.
public func renderWeek(_ ivs: [Interval], bucketSecs: Int, rules: RuleSet, timeZone: TimeZone,
                       from: Int, to: Int, options: RenderOptions = RenderOptions()) -> String {
    let days = dayStarts(from: from, to: to, timeZone: timeZone)
    let lastDay = days.last ?? from
    var lines = [dayHeading(from, timeZone) + " ─ " + dayHeading(lastDay, timeZone), ""]

    // Totals for the whole range decide which categories earn a column, so the columns
    // are the same on every row.
    let weekSlices = slice(ivs, bucketSecs: bucketSecs, rules: rules, from: from, to: to)
    guard !weekSlices.isEmpty else {
        lines.append("no activity recorded")
        return lines.joined(separator: "\n")
    }
    let weekTotals = totals(weekSlices)
    let ranked = weekTotals.filter { !awayCategories.contains($0.category) }
    let named = ranked.prefix(weekColumnLimit).map(\.category)
    let hasOther = ranked.count > weekColumnLimit
    let columns = named + (hasOther ? ["other"] : []) + ["tracked"]

    /// Seconds per column for one day, in `columns` order.
    func cells(_ dayFrom: Int, _ dayTo: Int) -> [Int] {
        let cats = totals(slice(ivs, bucketSecs: bucketSecs, rules: rules, from: dayFrom, to: dayTo))
        let byName = Dictionary(uniqueKeysWithValues:
            cats.filter { !awayCategories.contains($0.category) }.map { ($0.category, $0.seconds) })
        var row = named.map { byName[$0] ?? 0 }
        if hasOther {
            let tail = byName.filter { !named.contains($0.key) }.values.reduce(0, +)
            row.append(tail)
        }
        row.append(byName.values.reduce(0, +))
        return row
    }

    var rows: [(label: String, cells: [Int])] = []
    for (i, dayFrom) in days.enumerated() {
        let dayTo = i + 1 < days.count ? days[i + 1] : to
        rows.append((dayLabel(dayFrom, timeZone), cells(dayFrom, dayTo)))
    }
    let totalCells = cells(from, to)

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

    // Only the named categories are coloured. `other` is a bucket rather than a
    // category and `tracked` is the sum of them all, so neither owns a colour.
    let colors = colorMap(named)
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
    // 100%, so it is left blank rather than stating the obvious.
    let tracked = totalCells.last ?? 0
    var shares = totalCells.dropLast().map { $0 > 0 ? "\(percent($0, of: tracked))%" : "" }
    shares.append("")
    lines.append(row("", Array(shares)))

    // Away time, kept out of the table but not out of the report: without it a week
    // asleep and a week with a dead sampler look identical.
    let locked = weekTotals.first { $0.category == Kind.locked.rawValue }?.seconds ?? 0
    let gap = weekTotals.first { $0.category == Kind.gap.rawValue }?.seconds ?? 0
    if locked + gap > 0 {
        var parts: [String] = []
        if locked > 0 { parts.append("locked \(formatDuration(locked))") }
        if gap > 0 { parts.append("no data \(formatDuration(gap))") }
        lines.append("")
        lines.append("away  \(formatDuration(locked + gap))   " + parts.joined(separator: " · "))
    }

    return lines.joined(separator: "\n")
}
