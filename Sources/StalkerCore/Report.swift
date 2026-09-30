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
///
/// `from`/`to` clamp each interval to the window being reported. Without the
/// clamp an interval spanning midnight contributed its ENTIRE duration to
/// whichever day was asked for, and emitted buckets labelled with the
/// neighbouring day's times — so every daily total was wrong by however long
/// the machine was mid-interval at midnight. Passing nil keeps the whole span,
/// which is what the unclamped callers want.
public func slice(_ ivs: [Interval], bucketSecs: Int, rules: RuleSet,
                  from: Int? = nil, to: Int? = nil) -> [Slice] {
    let lo = from ?? Int.min
    let hi = to ?? Int.max
    var out: [Slice] = []
    for iv in ivs {
        let start = max(iv.startedAt, lo)
        let end = min(max(iv.endedAt, iv.startedAt), hi)
        guard end > start else { continue }
        let category = iv.kind == .app ? classify(iv, with: rules) : iv.kind.rawValue
        var b = bucketStart(start, bucketSecs: bucketSecs)
        while b < end {
            let secs = max(0, min(end, b + bucketSecs) - max(start, b))
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

public struct SubcategoryTotal: Equatable, Sendable {
    public let name: String
    public let seconds: Int
    public let byContext: [ContextTotal]
}

public struct CategoryTotal: Equatable, Sendable {
    public let category: String
    /// Includes every subcategory, so a parent total is the whole of what was spent
    /// under it.
    public let seconds: Int
    /// Only the time filed directly against the parent, never a subcategory's.
    public let byContext: [ContextTotal]
    public let subcategories: [SubcategoryTotal]
}

/// A category may name a parent with a slash, as in "fun/Youtube".
///
/// This exists so a category can be both specific and countable. YouTube in Edge
/// deserves its own name, but the day's `fun` figure is a lie if that time sits in
/// a separate bucket beside it. The parent carries the total; the child stays
/// visible underneath.
public func categoryParent(_ category: String) -> String {
    guard let slash = category.firstIndex(of: "/") else { return category }
    let parent = String(category[category.startIndex..<slash])
    return parent.isEmpty ? category : parent
}

/// The child half of a "parent/child" category, or nil for a plain one.
public func categoryLeaf(_ category: String) -> String? {
    guard let slash = category.firstIndex(of: "/"),
          !String(category[category.startIndex..<slash]).isEmpty else { return nil }
    let leaf = String(category[category.index(after: slash)...])
    return leaf.isEmpty ? nil : leaf
}

/// Totals per category, each broken down by context.
///
/// The breakdown is deliberate: a rule like `Chrome = work` is a habit, not a
/// fact, so youtube time sitting inside `work` must be visible rather than
/// folded into a flattering total. Spec §8.
public func totals(_ slices: [Slice]) -> [CategoryTotal] {
    var parentSeconds: [String: Int] = [:]
    var directContext: [String: [String: Int]] = [:]
    var subSeconds: [String: [String: Int]] = [:]
    var subContext: [String: [String: [String: Int]]] = [:]

    for s in slices {
        let parent = categoryParent(s.category)
        let label = s.context ?? s.appName ?? "(unknown)"
        parentSeconds[parent, default: 0] += s.seconds
        if let leaf = categoryLeaf(s.category) {
            subSeconds[parent, default: [:]][leaf, default: 0] += s.seconds
            subContext[parent, default: [:]][leaf, default: [:]][label, default: 0] += s.seconds
        } else {
            directContext[parent, default: [:]][label, default: 0] += s.seconds
        }
    }

    func ranked(_ m: [String: Int]) -> [ContextTotal] {
        m.map { ContextTotal(label: $0.key, seconds: $0.value) }
            .sorted { ($0.seconds, $1.label) > ($1.seconds, $0.label) }
    }

    return parentSeconds
        .map { parent, secs in
            let subs = (subSeconds[parent] ?? [:])
                .map { name, ss in
                    SubcategoryTotal(name: name, seconds: ss,
                                     byContext: ranked(subContext[parent]?[name] ?? [:]))
                }
                .sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }
            return CategoryTotal(category: parent, seconds: secs,
                                 byContext: ranked(directContext[parent] ?? [:]),
                                 subcategories: subs)
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

public func render(_ ivs: [Interval], bucketSecs: Int, rules: RuleSet, timeZone: TimeZone,
                   from: Int? = nil, to: Int? = nil) -> String {
    let all = slice(ivs, bucketSecs: bucketSecs, rules: rules, from: from, to: to)
    var lines: [String] = []

    // Per bucket, the category that took the most time, with its top context.
    //
    // "Most time" means total seconds across every fragment of that category in
    // the bucket, not whichever single fragment happens to be longest — three
    // short Slack visits summing to more than one long Chrome visit must still
    // show as Slack's category.
    let buckets = Set(all.map(\.bucketStart)).sorted()
    for b in buckets {
        let here = all.filter { $0.bucketStart == b }
        var secondsByCategory: [String: Int] = [:]
        for s in here { secondsByCategory[s.category, default: 0] += s.seconds }
        guard let winningCategory = secondsByCategory.max(by: { $0.value < $1.value })?.key,
              let top = here.filter({ $0.category == winningCategory })
                            .max(by: { $0.seconds < $1.seconds }) else { continue }
        let label = top.context ?? top.appName ?? "—"
        lines.append("\(hhmm(b, timeZone)) ─ \(hhmm(b + bucketSecs, timeZone))   "
                     + top.category.padding(toLength: 12, withPad: " ", startingAt: 0)
                     + "\(top.appName ?? "—")  \(label)")
    }

    lines.append("")
    lines.append("TOTALS")
    for ct in totals(all) {
        lines.append("  " + ct.category.padding(toLength: 14, withPad: " ", startingAt: 0) + dur(ct.seconds))
        // Subcategories first, each with its own contexts indented under it. The
        // extra indent is what distinguishes a subcategory subtotal from one of the
        // parent's own context lines at the same level.
        for sub in ct.subcategories {
            lines.append("    " + sub.name.padding(toLength: 44, withPad: " ", startingAt: 0) + dur(sub.seconds))
            // A lone context under a subcategory accounts for all of it, so the line
            // restates the subtotal directly above with nothing added. Two or more
            // earn their place by showing how the time divides.
            if sub.byContext.count > 1 {
                for c in sub.byContext.prefix(4) {
                    lines.append("      " + c.label.padding(toLength: 42, withPad: " ", startingAt: 0) + dur(c.seconds))
                }
            }
        }
        // Same rule for the parent, but only when it has no subcategories. With one,
        // a lone direct context is a part of the total rather than the whole of it —
        // dropping it would leave the arithmetic unexplained.
        if ct.byContext.count > 1 || !ct.subcategories.isEmpty {
            for c in ct.byContext.prefix(6) {
                lines.append("    " + c.label.padding(toLength: 44, withPad: " ", startingAt: 0) + dur(c.seconds))
            }
        }
    }
    return lines.joined(separator: "\n")
}
