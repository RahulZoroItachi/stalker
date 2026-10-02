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
    /// The recorded kind this came from, or nil when the slice was logged by hand.
    /// Logged time has no measured kind: nothing observed it.
    public let kind: Kind?
    public let appName: String?
    public let context: String?
    public let seconds: Int
    /// Of `seconds`, how many were hands-on, apportioned from the interval's
    /// `active / samples` ratio.
    public let activeSeconds: Int
    /// Of `seconds`, how many had media playing, apportioned the same way.
    public let engagedSeconds: Int
}

/// Which category an interval is filed under.
///
/// `app` time is classified by the rules. `idle` time normally is not, because no
/// input means you walked away, and classifying it by whatever happened to be in
/// focus would turn every coffee break into work. The exception is a rule that sets
/// `idle_counts`: in a meeting you listen without touching anything, and nothing the
/// sampler can see distinguishes that from an empty desk.
///
/// `locked` and `gap` are never reclassified. A locked screen means you left,
/// whatever was on it, and a gap means there was nothing to classify.
///
/// An idle interval matching no rule stays `idle` rather than becoming the default
/// category: the default exists for unclassified activity, and this is the absence
/// of activity.
func categoryFor(_ iv: Interval, rules: RuleSet) -> String {
    switch iv.kind {
    case .app:
        return classify(iv, with: rules)
    case .idle:
        if let rule = matchingRule(iv, with: rules), rule.idleCounts { return rule.category }
        return Kind.idle.rawValue
    case .locked, .gap:
        return iv.kind.rawValue
    }
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
        let category = categoryFor(iv, rules: rules)
        // The counters are tick counts over the whole interval, so a slice gets the
        // same proportion of them as it does of the duration. A `gap` row carries
        // samples = 0, which is why this is a guard and not a plain divide.
        let activeRatio = iv.samples > 0 ? Double(iv.active) / Double(iv.samples) : 0
        let engagedRatio = iv.samples > 0 ? Double(iv.engaged) / Double(iv.samples) : 0
        var b = bucketStart(start, bucketSecs: bucketSecs)
        while b < end {
            let secs = max(0, min(end, b + bucketSecs) - max(start, b))
            if secs > 0 {
                out.append(Slice(bucketStart: b, category: category, kind: iv.kind,
                                 appName: iv.appName, context: iv.context, seconds: secs,
                                 activeSeconds: min(secs, Int((Double(secs) * activeRatio).rounded())),
                                 engagedSeconds: min(secs, Int((Double(secs) * engagedRatio).rounded()))))
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
    public let activeSeconds: Int
    public let engagedSeconds: Int
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
    /// Hands-on seconds, including every subcategory's, so it is comparable with
    /// `seconds`.
    public let activeSeconds: Int
    /// Seconds with media playing, including every subcategory's.
    public let engagedSeconds: Int
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
    var parentActive: [String: Int] = [:]
    var parentEngaged: [String: Int] = [:]
    var directContext: [String: [String: Int]] = [:]
    var subSeconds: [String: [String: Int]] = [:]
    var subActive: [String: [String: Int]] = [:]
    var subEngaged: [String: [String: Int]] = [:]
    var subContext: [String: [String: [String: Int]]] = [:]

    for s in slices {
        let parent = categoryParent(s.category)
        let label = s.context ?? s.appName ?? "(unknown)"
        parentSeconds[parent, default: 0] += s.seconds
        parentActive[parent, default: 0] += s.activeSeconds
        parentEngaged[parent, default: 0] += s.engagedSeconds
        if let leaf = categoryLeaf(s.category) {
            subSeconds[parent, default: [:]][leaf, default: 0] += s.seconds
            subActive[parent, default: [:]][leaf, default: 0] += s.activeSeconds
            subEngaged[parent, default: [:]][leaf, default: 0] += s.engagedSeconds
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
                                     activeSeconds: subActive[parent]?[name] ?? 0,
                                     engagedSeconds: subEngaged[parent]?[name] ?? 0,
                                     byContext: ranked(subContext[parent]?[name] ?? [:]))
                }
                .sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }
            return CategoryTotal(category: parent, seconds: secs,
                                 byContext: ranked(directContext[parent] ?? [:]),
                                 subcategories: subs,
                                 activeSeconds: parentActive[parent] ?? 0,
                                 engagedSeconds: parentEngaged[parent] ?? 0)
        }
        .sorted { ($0.seconds, $1.category) > ($1.seconds, $0.category) }
}
