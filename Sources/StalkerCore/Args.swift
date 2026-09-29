import Foundation

public enum Command: Equatable, Sendable {
    case sample
    case report(date: String?)
    case doctor
    case help
}

public func parseArgs(_ args: [String]) -> Command {
    guard let first = args.first else { return .help }
    switch first {
    case "sample": return .sample
    case "doctor": return .doctor
    case "report":
        guard args.count > 1 else { return .report(date: nil) }
        guard args[1] == "--date", args.count > 2 else { return .help }
        return .report(date: args[2])
    default: return .help
    }
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
