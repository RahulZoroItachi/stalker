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

public enum Command: Equatable, Sendable {
    case sample
    case report(ReportRequest)
    case doctor
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
    case "help", "--help", "-h": return .help
    default: return .usageError
    }
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
