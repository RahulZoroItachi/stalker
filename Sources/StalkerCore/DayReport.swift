import Foundation

/// How to lay the report out. Kept as a value so the renderers stay pure functions
/// and every layout rule is testable at any width without a terminal.
public struct RenderOptions: Sendable {
    public let width: Int
    public let color: Bool
    /// Home directory, used to abbreviate paths to `~`. Empty disables that.
    public let home: String

    public init(width: Int = 100, color: Bool = false, home: String = "") {
        self.width = width; self.color = color; self.home = home
    }
}

/// Kinds that mean "not at the machine".
///
/// They are reported in a footer rather than as categories. Counting a nine-hour
/// night among the day's percentages makes every real figure look tiny, which is
/// what the old report did: `gap 7h 54m` sat at the top of the totals while 45
/// minutes of actual work sat below it.
let awayCategories: Set<String> = [Kind.gap.rawValue, Kind.locked.rawValue]

/// Categories with no app behind them: time away, and activities logged by hand.
///
/// Both render as a bare label rather than padding out an app and context column with
/// dashes, and runs of both collapse into one row.
func isLabelOnly(_ category: String, _ rules: RuleSet) -> Bool {
    awayCategories.contains(category) || rules.activities.contains(category)
}

/// `gap` is the schema's word for it. "no data" is what it means to a reader.
func displayCategory(_ category: String) -> String {
    category == Kind.gap.rawValue ? "no data" : category
}

/// Below this share, a bucket's winning category is printed with its percentage.
///
/// A bucket is one row, so a row names one category. When that category holds only
/// 55% of the half-hour, saying so is the difference between an honest row and a
/// flattering one.
let dominantShare = 80

/// Pad to `width`, never truncating.
///
/// Truncation here was the original bug: `padding(toLength:)` cut the label to
/// exactly the column width, so a long path ran straight into its duration and the
/// report read `...Analytics_Per33m`. Callers shorten labels with `ellipsizeLabel`
/// first; this only ever adds spaces.
func padded(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func rightAligned(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

/// Fit a value into a fixed column, keeping at least one space after it.
func column(_ s: String, _ width: Int) -> String {
    padded(ellipsizeLabel(s, max: width - 1), width)
}

public func clockTime(_ ts: Int, _ tz: TimeZone) -> String {
    let f = DateFormatter()
    f.timeZone = tz
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
}

func dayHeading(_ ts: Int, _ tz: TimeZone) -> String {
    let f = DateFormatter()
    f.timeZone = tz
    // Fixed locale so the heading, and the test that pins it, do not depend on the
    // machine's region settings.
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE d MMM yyyy"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
}

/// One row of the timeline, before it is turned into text.
private struct Row {
    let start: Int
    var end: Int
    let category: String
    let appName: String?
    let label: String?
    /// The winning category's share of the bucket, as a percentage.
    let share: Int
}

/// Collapse each bucket to its winning category, then merge consecutive runs of the
/// away categories.
///
/// Only the away runs merge. Real categories keep one row per bucket because the
/// whole point of the report is a 30-minute-by-30-minute account, and collapsing
/// `work` into one long row would throw that away. Merging the away runs is what
/// turns eighteen identical overnight rows into one.
private func timelineRows(_ slices: [Slice], bucketSecs: Int, rules: RuleSet) -> [Row] {
    var rows: [Row] = []
    for bucket in Set(slices.map(\.bucketStart)).sorted() {
        let here = slices.filter { $0.bucketStart == bucket }
        var secondsByCategory: [String: Int] = [:]
        for s in here { secondsByCategory[s.category, default: 0] += s.seconds }
        // "Most time" is the category's total across every fragment in the bucket, not
        // whichever single fragment is longest: three short Slack visits outweighing one
        // long Chrome visit must show as Slack.
        guard let winner = secondsByCategory.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key,
              let top = here.filter({ $0.category == winner }).max(by: { $0.seconds < $1.seconds })
        else { continue }

        let bucketTotal = here.reduce(0) { $0 + $1.seconds }
        let row = Row(start: bucket, end: bucket + bucketSecs, category: winner,
                      appName: top.appName, label: top.context ?? top.appName,
                      share: percent(secondsByCategory[winner] ?? 0, of: bucketTotal))

        // gap and locked stay separate runs. They are different states, and the footer
        // reports them separately for the same reason: merging them would hide a dead
        // sampler behind a night's sleep.
        if isLabelOnly(winner, rules), var last = rows.last,
           last.category == winner, last.end == bucket {
            last.end = row.end
            rows[rows.count - 1] = last
        } else {
            rows.append(row)
        }
    }
    return rows
}

public func renderDay(_ ivs: [Interval], notes: [Note] = [], bucketSecs: Int, rules: RuleSet,
                      timeZone: TimeZone, from: Int, to: Int,
                      options: RenderOptions = RenderOptions()) -> String {
    // Notes claim only what no app held, so resolution happens before slicing: the
    // recorded intervals come back trimmed to the time no note explained, and the
    // claims become slices of their own.
    let resolved = resolveNotes(intervals: ivs, notes: notes, range: Span(from, to))
    let all = slice(resolved.intervals, bucketSecs: bucketSecs, rules: rules, from: from, to: to)
             + noteSlices(resolved.claims, bucketSecs: bucketSecs)
    // Whether anything was actually logged by hand decides the wording below. A note
    // for another day leaves this day exactly as it was, so it must not change it.
    let hasLogged = resolved.claims.contains { $0.claimed > 0 }
    var lines = [dayHeading(from, timeZone), ""]

    guard !all.isEmpty else {
        lines.append("no activity recorded")
        return lines.joined(separator: "\n")
    }

    let cats = totals(all)
    // Assigned from the totals, biggest first, so a category does not change colour
    // from one day to the next just because the timeline visited it in a different order.
    let colors = colorMap(cats.map(\.category))
    func paint(_ text: String, _ category: String) -> String {
        colorize(text, colors[category] ?? awayColor, enabled: options.color)
    }

    // --- timeline ---
    // 15 holds "Microsoft Edge" and "Google Chrome" whole. Browsers and PWAs are the
    // apps most often in focus, and "Goog…hrome" is not a readable app name.
    let timeCol = 13, catCol = 13, appCol = 15, shareCol = 7
    let labelWidth = max(8, options.width - timeCol - 3 - catCol - appCol - shareCol)
    for row in timelineRows(all, bucketSecs: bucketSecs, rules: rules) {
        let span = "\(clockTime(row.start, timeZone)) ─ \(clockTime(row.end, timeZone))   "
        if isLabelOnly(row.category, rules) {
            lines.append(span + paint(displayCategory(row.category), row.category))
            continue
        }
        let label = ellipsizeLabel(tildePath(row.label ?? "—", home: options.home), max: labelWidth)
        let share = row.share < dominantShare ? "  (\(row.share)%)" : ""
        lines.append(span + paint(column(row.category, catCol), row.category)
                     + column(row.appName ?? "—", appCol) + label + share)
    }

    // --- totals ---
    // Rest is excluded from the denominator as well as from the list. Seven hours of
    // sleep in the same divisor would make every other row a rounding error, which is
    // the whole reason it sits apart.
    func inList(_ c: String) -> Bool { !awayCategories.contains(c) && !rules.rest.contains(c) }
    let tracked = cats.filter { inList($0.category) }.reduce(0) { $0 + $1.seconds }

    /// Rows that round to `0m` tell the reader nothing and crowd out rows that do.
    func worthShowing(_ seconds: Int) -> Bool { seconds >= 60 }

    /// Which breakdown rows a category contributes, at what indent.
    ///
    /// Collected before anything is formatted because the duration column is shared
    /// by the whole report, and its position depends on the longest label in it.
    func breakdownRows(_ ct: CategoryTotal) -> [(indent: Int, label: String, seconds: Int)] {
        var rows: [(indent: Int, label: String, seconds: Int)] = []
        // Subcategories first, each with its own contexts indented under it. The extra
        // indent is what distinguishes a subcategory subtotal from one of the parent's
        // own context lines at the same level.
        for sub in ct.subcategories where worthShowing(sub.seconds) {
            rows.append((4, sub.name, sub.seconds))
            // A lone context under a subcategory accounts for all of it, so the line
            // would restate the subtotal directly above with nothing added. Two or more
            // earn their place by showing how the time divides.
            if sub.byContext.count > 1 {
                for c in sub.byContext.prefix(4) where worthShowing(c.seconds) {
                    rows.append((6, c.label, c.seconds))
                }
            }
        }
        // Same rule for the parent, but only when it has no subcategories. With one, a
        // lone direct context is a part of the total rather than the whole of it, so
        // dropping it would leave the arithmetic unexplained.
        if ct.byContext.count > 1 || !ct.subcategories.isEmpty {
            for c in ct.byContext.prefix(6) where worthShowing(c.seconds) {
                rows.append((4, c.label, c.seconds))
            }
        }
        return rows
    }

    if tracked > 0 {
        // A category below a minute is dropped, but stays inside `tracked`, so the
        // percentages still describe the whole day rather than only what is printed.
        let shown = cats.filter { inList($0.category) && worthShowing($0.seconds) }

        /// Shorten each label to what the width allows, then find where the duration
        /// column has to sit. Right-aligning at the terminal edge instead strands every
        /// number an inch from its label, which on real data is most of the page.
        let durationCol = 7
        var prepared: [String: [(indent: Int, text: String, seconds: Int)]] = [:]
        var labelEnd = 0
        for ct in shown {
            prepared[ct.category] = breakdownRows(ct).map { row in
                let room = max(8, options.width - row.indent - durationCol - 2)
                let text = ellipsizeLabel(tildePath(row.label, home: options.home), max: room)
                labelEnd = max(labelEnd, row.indent + text.count)
                return (row.indent, text, row.seconds)
            }
        }

        lines.append("")
        // "tracked" means time at the machine, which is no longer the whole story once
        // off-screen activities are logged. The word changes with the meaning.
        lines.append(hasLogged ? "YOUR DAY   \(formatDuration(tracked)) logged"
                               : "TOTALS   tracked \(formatDuration(tracked))")
        for ct in shown {
            var line = "  " + paint(column(ct.category, catCol), ct.category)
                       + paint(bar(Double(ct.seconds) / Double(tracked), width: 20), ct.category)
                       + "  " + rightAligned(formatDuration(ct.seconds), durationCol)
                       + "  " + rightAligned("\(percent(ct.seconds, of: tracked))%", 4)
            // Idle time has no input by definition, so it reports no active share and
            // the clause is simply absent rather than printed as zero.
            if ct.activeSeconds > 0 {
                line += "   active \(percent(ct.activeSeconds, of: ct.seconds))%"
            }
            if ct.engagedSeconds > 0 {
                line += "  engaged \(percent(ct.engagedSeconds, of: ct.seconds))%"
            }
            lines.append(line)

            for row in prepared[ct.category] ?? [] {
                lines.append(String(repeating: " ", count: row.indent)
                             + padded(row.text, labelEnd - row.indent) + "  "
                             + rightAligned(formatDuration(row.seconds), durationCol))
            }
        }
    }

    // --- rest, below the list rather than inside it ---
    let restRows = cats.filter { rules.rest.contains($0.category) && worthShowing($0.seconds) }
    if !restRows.isEmpty {
        lines.append("")
        for ct in restRows { lines.append("\(ct.category)  \(formatDuration(ct.seconds))") }
    }

    // --- what nothing explained ---
    let locked = cats.first { $0.category == Kind.locked.rawValue }?.seconds ?? 0
    let gap = cats.first { $0.category == Kind.gap.rawValue }?.seconds ?? 0
    if locked + gap > 0 {
        var parts: [String] = []
        if locked > 0 { parts.append("locked \(formatDuration(locked))") }
        if gap > 0 { parts.append("no data \(formatDuration(gap))") }
        // Once some away time has a reason, "away" is the wrong word for what is left.
        let label = hasLogged ? "unaccounted" : "away"
        if restRows.isEmpty { lines.append("") }
        lines.append("\(label)  \(formatDuration(locked + gap))   " + parts.joined(separator: " · "))
    }

    // --- notes that logged less than they stated ---
    // Silence here would read as a tracker that lost time.
    let byLine = Dictionary(notes.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
    let short = resolved.claims.filter { $0.claimed < $0.stated }
    if !short.isEmpty {
        lines.append("")
        lines.append("notes")
        for claim in short {
            var line = "  \(claim.activity)"
            if let note = byLine[claim.line] {
                line += " \(clockTime(note.span.start, timeZone))-\(clockTime(note.span.end, timeZone))"
            }
            line += " claimed \(formatDuration(claim.claimed)) of \(formatDuration(claim.stated))"
            let blame = claim.heldBy.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(3).map { "\(formatDuration($0.value)) held by \($0.key)" }
            if !blame.isEmpty { line += " — " + blame.joined(separator: ", ") }
            lines.append(line)
        }
    }

    return lines.joined(separator: "\n")
}
