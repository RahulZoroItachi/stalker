import Foundation

/// Stale courier files from closed terminals are ignored past this age. Spec §5.3.
public let courierMaxAgeSecs = 86_400

public struct CourierReading: Equatable, Sendable {
    public let at: Int
    public let cwd: String
    public init(at: Int, cwd: String) { self.at = at; self.cwd = cwd }
}

/// Parse one courier file: `<unix-seconds> <absolute-path>`.
///
/// Split on the FIRST space only. Paths legitimately contain spaces
/// (`Application Support`, most user folders), and splitting on every space
/// would truncate the cwd to its first word — after which the directory rule
/// silently never matches.
public func parseCourierLine(_ line: String) -> CourierReading? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let space = trimmed.firstIndex(of: " ") else { return nil }
    guard let at = Int(trimmed[trimmed.startIndex..<space]) else { return nil }
    let cwd = String(trimmed[trimmed.index(after: space)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cwd.isEmpty else { return nil }
    return CourierReading(at: at, cwd: cwd)
}

/// The focused shell is the one that most recently ran a command or changed
/// directory. macOS exposes no way to ask which terminal tab has focus, and
/// Ghostty exposes no tty or working directory through scripting, so this
/// timestamp comparison is the attribution rule. Spec §5.3.
public func newestReading(_ readings: [CourierReading], now: Int, maxAgeSecs: Int) -> CourierReading? {
    readings
        .filter { now - $0.at <= maxAgeSecs }
        .max { $0.at < $1.at }
}

/// Read every courier file in `dir`. Unreadable or malformed files are skipped
/// rather than failing the tick — a broken file must not stop collection.
public func readCourierDir(_ dir: String, now: Int, maxAgeSecs: Int) -> CourierReading? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
    var readings: [CourierReading] = []
    for name in names {
        guard let text = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8),
              let r = parseCourierLine(text) else { continue }
        readings.append(r)
    }
    return newestReading(readings, now: now, maxAgeSecs: maxAgeSecs)
}
