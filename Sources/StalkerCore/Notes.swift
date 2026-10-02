import Foundation

/// One block of time logged by hand.
///
/// `span` is absolute unix seconds, with any midnight crossing already resolved, so
/// nothing downstream has to know about dates or clocks. `line` survives only so an
/// error can name the line to fix.
public struct Note: Equatable, Sendable {
    public let activity: String
    public let span: Span
    public let line: Int

    public init(activity: String, span: Span, line: Int) {
        self.activity = activity; self.span = span; self.line = line
    }
}

public enum NotesError: Error, Equatable, CustomStringConvertible {
    case fields(line: Int, text: String)
    case date(line: Int, text: String)
    case range(line: Int, text: String)
    case emptyRange(line: Int, text: String)
    case unknownActivity(line: Int, activity: String, declared: [String])

    public var description: String {
        switch self {
        case .fields(let l, let t):
            return "notes line \(l): expected \"DATE  FROM-TO  ACTIVITY\", got \"\(t)\""
        case .date(let l, let t):
            return "notes line \(l): \"\(t)\" is not a real date in YYYY-MM-DD form"
        case .range(let l, let t):
            return "notes line \(l): \"\(t)\" is not a range in HH:MM-HH:MM form"
        case .emptyRange(let l, let t):
            return "notes line \(l): \"\(t)\" covers no time"
        case .unknownActivity(let l, let a, let declared):
            return "notes line \(l): unknown activity \"\(a)\". Declared activities are:\n  "
                 + declared.joined(separator: ", ")
                 + "\nAdd it to activities in rules.toml, or fix the line."
        }
    }
}

/// `HH:MM` as minutes past midnight, or nil if it is not a real time of day.
func minutesOfDay(_ text: String) -> Int? {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
          let h = Int(parts[0]), let m = Int(parts[1]),
          (0...23).contains(h), (0...59).contains(m) else { return nil }
    return h * 60 + m
}

/// Start of the given local day, or nil if the date is not real.
///
/// Built with `DateComponents` rather than a `DateFormatter` so that an impossible
/// date is rejected instead of being rolled forward: a formatter reads 2026-02-30 as
/// 2 March, which would file a block against a day the user never named.
func startOfDay(_ text: String, timeZone: TimeZone) -> Date? {
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]) else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d
    guard let date = cal.date(from: c), cal.component(.day, from: date) == d,
          cal.component(.month, from: date) == mo else { return nil }
    return cal.startOfDay(for: date)
}

/// Parse the notes file.
///
/// Every deviation throws rather than being skipped, for the reason the base spec §9
/// gives for `rules.toml`: a silently ignored line is a silently wrong report, with no
/// symptom to notice.
public func parseNotes(_ text: String, activities: Set<String>, timeZone: TimeZone) throws -> [Note] {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let declared = activities.sorted()
    var out: [Note] = []

    for (idx, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let lineNo = idx + 1
        var line = String(rawLine)
        if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }

        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 3 else { throw NotesError.fields(line: lineNo, text: line) }

        guard let dayStart = startOfDay(fields[0], timeZone: timeZone) else {
            throw NotesError.date(line: lineNo, text: fields[0])
        }

        let halves = fields[1].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard halves.count == 2, let from = minutesOfDay(halves[0]), let to = minutesOfDay(halves[1])
        else { throw NotesError.range(line: lineNo, text: fields[1]) }
        guard from != to else { throw NotesError.emptyRange(line: lineNo, text: fields[1]) }

        let activity = fields[2].lowercased()
        guard activities.contains(activity) else {
            throw NotesError.unknownActivity(line: lineNo, activity: activity, declared: declared)
        }

        // Added as calendar minutes rather than as seconds so a block spanning a clock
        // change keeps the wall-clock times the user wrote.
        guard let start = cal.date(byAdding: .minute, value: from, to: dayStart) else {
            throw NotesError.range(line: lineNo, text: fields[1])
        }
        // `to` at or before `from` means the block ends the next day. Sleep normally
        // crosses midnight, so this is the common case rather than an edge case.
        let endMinutes = to < from ? to + 24 * 60 : to
        guard let end = cal.date(byAdding: .minute, value: endMinutes, to: dayStart) else {
            throw NotesError.range(line: lineNo, text: fields[1])
        }

        out.append(Note(activity: activity,
                        span: Span(Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970)),
                        line: lineNo))
    }
    return out
}

/// One notes-file line.
///
/// The writer the `note` command uses. Kept beside the parser so the two cannot drift:
/// a command that appended a line the next report refused to read would be worse than
/// no command at all.
public func noteLine(date: String, from: String, to: String, activity: String) -> String {
    "\(date)  \(from)-\(to)  \(activity)"
}
