import Foundation

/// What `stalker report` was asked for.
///
/// `color` and `width` are optional rather than defaulted: nil means the flag was
/// absent and the caller should detect the terminal, which only the caller can do.
public struct ReportRequest: Equatable, Sendable {
    public enum Span: Equatable, Sendable {
        case day
        case week
        case since(Int)
    }
    public let date: String?
    public let span: Span
    public let color: Bool?
    public let width: Int?

    public init(date: String? = nil, span: Span = .day, color: Bool? = nil, width: Int? = nil) {
        self.date = date; self.span = span; self.color = color; self.width = width
    }
}

/// What `stalker note` was asked for.
public enum NoteAction: Equatable, Sendable {
    case add(range: String, activity: String, date: String?)
    case list(date: String?)
}

public enum Command: Equatable, Sendable {
    case sample
    case report(ReportRequest)
    case note(NoteAction)
    case doctor
    /// Per-user wiring a Homebrew formula is not allowed to do: the signing
    /// certificate, the shell hook, and the launchd agents. Spec §4.
    case setup(supportDir: String?)
    /// The version, so a report from someone else's machine can be placed against
    /// a build. A success, like `help`.
    case version
    /// Usage was asked for. A success.
    case help
    /// Arguments were malformed. Distinct from `help` so the process can exit
    /// non-zero: a script that mistypes a flag must not get a successful-looking run
    /// and a report for some other range.
    case usageError
}

public func parseArgs(_ args: [String]) -> Command {
    guard let first = args.first else { return .help }
    switch first {
    case "sample": return .sample
    case "doctor": return .doctor
    case "report": return parseReport(Array(args.dropFirst()))
    case "note": return parseNote(Array(args.dropFirst()))
    case "setup": return parseSetup(Array(args.dropFirst()))
    case "version", "--version": return .version
    case "help", "--help", "-h": return .help
    default: return .usageError
    }
}

/// The one flag `setup` takes.
///
/// `--support-dir` exists because the support files sit in Homebrew's share
/// directory when installed and in `scripts/` when run from a clone, and only the
/// caller knows which. An unknown flag is refused rather than ignored, so a typo
/// cannot produce a half-finished install that looks like a complete one.
private func parseSetup(_ args: [String]) -> Command {
    var dir: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--support-dir":
            guard i + 1 < args.count else { return .usageError }
            i += 1
            dir = args[i]
        default:
            return .usageError
        }
        i += 1
    }
    return .setup(supportDir: dir)
}

/// Flags for `report`, in any order.
///
/// Anything unrecognised, malformed, or contradictory yields `.help`. A typo that
/// silently reports the wrong range is worse than one that prints usage: the output
/// looks perfectly plausible and there is nothing to notice.
private func parseReport(_ args: [String]) -> Command {
    var date: String?
    var span: ReportRequest.Span?
    var color: Bool?
    var width: Int?

    var i = 0
    while i < args.count {
        /// The value after a flag, or nil when the flag ends the argument list.
        func value() -> String? {
            guard i + 1 < args.count else { return nil }
            i += 1
            return args[i]
        }
        switch args[i] {
        case "--date":
            guard let v = value() else { return .usageError }
            date = v
        case "--week":
            // Two spans at once has no single correct reading, so it is refused rather
            // than resolved by whichever happened to be parsed last.
            guard span == nil else { return .usageError }
            span = .week
        case "--since":
            guard span == nil, let v = value(), let n = Int(v), n >= 1 else { return .usageError }
            span = .since(n)
        case "--no-color":
            color = false
        case "--width":
            guard let v = value(), let n = Int(v) else { return .usageError }
            width = n
        default:
            return .usageError
        }
        i += 1
    }
    return .report(ReportRequest(date: date, span: span ?? .day, color: color, width: width))
}

/// Flags and positionals for `note`, in any order.
///
/// The range and activity are carried as written and validated later by the notes
/// parser, so the command and the file can never disagree about what is well-formed.
private func parseNote(_ args: [String]) -> Command {
    var date: String?
    var list = false
    var positional: [String] = []

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--date":
            guard i + 1 < args.count else { return .usageError }
            i += 1
            date = args[i]
        case "--list":
            list = true
        default:
            guard !args[i].hasPrefix("--") else { return .usageError }
            positional.append(args[i])
        }
        i += 1
    }

    if list {
        // Listing takes no range: it reports what is already written.
        guard positional.isEmpty else { return .usageError }
        return .note(.list(date: date))
    }
    guard positional.count == 2 else { return .usageError }
    return .note(.add(range: positional[0], activity: positional[1], date: date))
}

/// Start and end of the requested day, in unix seconds.
public func dayRange(_ dateString: String?, now: Int, timeZone: TimeZone) -> (from: Int, to: Int) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone

    let reference: Date
    if let dateString {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        reference = f.date(from: dateString) ?? Date(timeIntervalSince1970: TimeInterval(now))
    } else {
        reference = Date(timeIntervalSince1970: TimeInterval(now))
    }

    let start = cal.startOfDay(for: reference)
    let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
}
