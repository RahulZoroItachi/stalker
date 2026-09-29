import Foundation

public let bucketSeconds = 1800

/// Absolute-time bucket alignment. For every time zone whose offset is a whole
/// multiple of 30 minutes this lands on local :00 and :30. Zones offset by 45
/// minutes (for example Asia/Kathmandu) will show :15 and :45 labels — odd to
/// read, but not wrong.
public func bucketStart(_ ts: Int, bucketSecs: Int) -> Int {
    ts - (ts % bucketSecs)
}

/// Seconds of `iv` that fall inside [bucketStart, bucketEnd).
///
/// `endedAt` is clamped to be at least `startedAt` first: a clock correction can
/// leave a row with `ended_at < started_at`, and a negative duration would
/// corrupt every total it is summed into.
public func overlapSeconds(_ iv: Interval, bucketStart: Int, bucketEnd: Int) -> Int {
    let ivEnd = max(iv.endedAt, iv.startedAt)
    let s = max(iv.startedAt, bucketStart)
    let e = min(ivEnd, bucketEnd)
    return max(0, e - s)
}

public struct Slice: Equatable, Sendable {
    public let bucketStart: Int
    public let category: String
    public let kind: Kind
    public let appName: String?
    public let context: String?
    public let seconds: Int
}

/// Cut intervals at bucket boundaries, classifying each as it goes.
public func slice(_ ivs: [Interval], bucketSecs: Int, rules: RuleSet) -> [Slice] {
    var out: [Slice] = []
    for iv in ivs {
        let ivEnd = max(iv.endedAt, iv.startedAt)
        guard ivEnd > iv.startedAt else { continue }
        let category = iv.kind == .app ? classify(iv, with: rules) : iv.kind.rawValue
        var b = bucketStart(iv.startedAt, bucketSecs: bucketSecs)
        while b < ivEnd {
            let secs = overlapSeconds(iv, bucketStart: b, bucketEnd: b + bucketSecs)
            if secs > 0 {
                out.append(Slice(bucketStart: b, category: category, kind: iv.kind,
                                 appName: iv.appName, context: iv.context, seconds: secs))
            }
            b += bucketSecs
        }
    }
    return out
}

public struct ContextTotal: Equatable, Sendable {
    public let label: String
    public let seconds: Int
}

public struct CategoryTotal: Equatable, Sendable {
    public let category: String
    public let seconds: Int
    public let byContext: [ContextTotal]
}

/// Totals per category, each broken down by context.
///
/// The breakdown is deliberate: a rule like `Chrome = work` is a habit, not a
/// fact, so youtube time sitting inside `work` must be visible rather than
/// folded into a flattering total. Spec §8.
public func totals(_ slices: [Slice]) -> [CategoryTotal] {
    var byCategory: [String: Int] = [:]
    var byCategoryContext: [String: [String: Int]] = [:]

    for s in slices {
        byCategory[s.category, default: 0] += s.seconds
        let label = s.context ?? s.appName ?? "(unknown)"
        byCategoryContext[s.category, default: [:]][label, default: 0] += s.seconds
    }

    return byCategory
        .map { cat, secs in
            let contexts = (byCategoryContext[cat] ?? [:])
                .map { ContextTotal(label: $0.key, seconds: $0.value) }
                .sorted { ($0.seconds, $1.label) > ($1.seconds, $0.label) }
            return CategoryTotal(category: cat, seconds: secs, byContext: contexts)
        }
        .sorted { ($0.seconds, $1.category) > ($1.seconds, $0.category) }
}

private func hhmm(_ ts: Int, _ tz: TimeZone) -> String {
    let f = DateFormatter()
    f.timeZone = tz
    f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
}

private func dur(_ secs: Int) -> String {
    let h = secs / 3600, m = (secs % 3600) / 60
    return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
}

public func render(_ ivs: [Interval], bucketSecs: Int, rules: RuleSet, timeZone: TimeZone) -> String {
    let all = slice(ivs, bucketSecs: bucketSecs, rules: rules)
    var lines: [String] = []

    // Per bucket, the category that took the most time, with its top context.
    let buckets = Set(all.map(\.bucketStart)).sorted()
    for b in buckets {
        let here = all.filter { $0.bucketStart == b }
        guard let top = here.max(by: { $0.seconds < $1.seconds }) else { continue }
        let label = top.context ?? top.appName ?? "—"
        lines.append("\(hhmm(b, timeZone)) ─ \(hhmm(b + bucketSecs, timeZone))   "
                     + top.category.padding(toLength: 12, withPad: " ", startingAt: 0)
                     + "\(top.appName ?? "—")  \(label)")
    }

    lines.append("")
    lines.append("TOTALS")
    for ct in totals(all) {
        lines.append("  " + ct.category.padding(toLength: 14, withPad: " ", startingAt: 0) + dur(ct.seconds))
        for c in ct.byContext.prefix(6) {
            lines.append("    " + c.label.padding(toLength: 44, withPad: " ", startingAt: 0) + dur(c.seconds))
        }
    }
    return lines.joined(separator: "\n")
}
