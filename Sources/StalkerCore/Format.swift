import Foundation

/// Presentation primitives for the report. Pure string and number work, with no
/// knowledge of intervals or categories, so the layout rules are testable without
/// building a day's worth of data.

/// "9h 47m", or "45m" under an hour.
///
/// A clock correction can hand us a negative span. "-1h -30m" would be worse than
/// useless in a total, so it clamps to zero.
public func formatDuration(_ secs: Int) -> String {
    let s = max(0, secs)
    let h = s / 3600, m = (s % 3600) / 60
    return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
}

/// Replace the home directory prefix with `~`.
///
/// The prefix must end at a separator. Without that check `/Users/alexother` would
/// be rewritten as `~other`, quietly reporting another account's directory as if it
/// were inside this one. Contexts that are not paths (URLs, window titles) have no
/// leading slash and fall through untouched.
public func tildePath(_ s: String, home: String) -> String {
    guard !home.isEmpty else { return s }
    if s == home { return "~" }
    if s.hasPrefix(home + "/") { return "~" + s.dropFirst(home.count) }
    return s
}

/// Cut an over-long string in the middle, keeping both ends.
///
/// The tail is what identifies a context — which project, which document — so the
/// tail is what survives. Tail truncation keeps `~/Desktop/Casey/Work/Analytics_Per`
/// and throws away the only part that distinguishes one path from its siblings.
public func middleEllipsis(_ s: String, max limit: Int) -> String {
    if limit <= 0 { return "" }
    if s.count <= limit { return s }
    if limit == 1 { return "…" }
    // The ellipsis occupies one column, so the two kept halves share `limit - 1`.
    // The tail gets the odd column, being the more informative end.
    let keep = limit - 1
    let head = keep / 2
    let tail = keep - head
    return String(s.prefix(head)) + "…" + String(s.suffix(tail))
}

private let barFilled: Character = "█"
private let barEmpty: Character = "░"

/// A proportional bar of exactly `width` characters.
///
/// Any non-zero fraction gets at least one filled cell. Rounding a 1% category down
/// to an empty bar would show real time as none at all, which is the one reading the
/// bar must never produce. A true zero still renders empty.
public func bar(_ fraction: Double, width: Int) -> String {
    guard width > 0 else { return "" }
    let f = min(1.0, Swift.max(0.0, fraction))
    var filled = Int((f * Double(width)).rounded())
    if f > 0 && filled == 0 { filled = 1 }
    return String(repeating: barFilled, count: filled)
        + String(repeating: barEmpty, count: width - filled)
}

/// `part` as a whole-number percentage of `whole`, rounded.
///
/// A zero denominator yields zero. An empty day has no percentages to report, and
/// dividing would trap.
public func percent(_ part: Int, of whole: Int) -> Int {
    guard whole > 0 else { return 0 }
    return Int((Double(part) / Double(whole) * 100).rounded())
}

/// Shorten a context label to fit, keeping the parts that identify it.
///
/// Context labels are slash-separated by nature: filesystem paths and normalised
/// URLs. The last segment carries the identity — which project, which document —
/// and the first carries the origin — which host, or `~`. So whole middle segments
/// are dropped before any character is cut, which is what produces
/// `~/Desktop/…/Analytics_Personalisation` rather than a tail-cut
/// `~/Desktop/Casey/Work/Analytics_Per`.
///
/// Order of sacrifice: middle segments, then the leading segment, then finally a
/// character-level cut of the last segment when it alone exceeds the limit.
public func ellipsizeLabel(_ s: String, max limit: Int) -> String {
    if limit <= 0 { return "" }
    if s.count <= limit { return s }

    let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    // Nothing to drop: one segment means there are no middle parts, so fall back to
    // cutting characters.
    guard parts.count > 2 else { return middleEllipsis(s, max: limit) }

    let last = parts[parts.count - 1]

    // Keep as many leading segments as the remaining width allows, so a wide terminal
    // shows `~/Desktop/…/Project` where a narrow one shows `~/…/Project`. Stopping at
    // the first segment unconditionally would waste the width that is available.
    let headBudget = limit - last.count - 3   // 3 for the "/…/" joiner
    if headBudget > 0 {
        var head = ""
        for part in parts.dropLast() {
            let candidate = head.isEmpty ? part : head + "/" + part
            if candidate.count > headBudget { break }
            head = candidate
        }
        if !head.isEmpty { return head + "/…/" + last }
    }
    // Not even one leading segment fits beside the last one.
    if last.count + 2 <= limit { return "…/" + last }
    return middleEllipsis(s, max: limit)
}
