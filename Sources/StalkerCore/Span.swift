import Foundation

/// A half-open range of unix seconds, `[start, end)`.
///
/// Half-open so that two adjacent spans share a boundary without overlapping on it.
/// `[0,60)` and `[60,120)` together cover two minutes, counting second 60 once.
public struct Span: Equatable, Sendable {
    public let start: Int
    public let end: Int

    public init(_ start: Int, _ end: Int) { self.start = start; self.end = end }

    public var seconds: Int { max(0, end - start) }
    public var isEmpty: Bool { end <= start }
}

/// Sort, merge, and drop the empties, giving a set of seconds one canonical form.
///
/// Every other function here begins with this, so results never depend on how the
/// caller happened to split or order its input. Touching spans merge for the same
/// reason: leaving `[10,20)` beside `[20,30)` would make the arithmetic sensitive to
/// an accident of construction.
public func normalized(_ spans: [Span]) -> [Span] {
    let sorted = spans.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
    var out: [Span] = []
    for s in sorted {
        if let last = out.last, s.start <= last.end {
            out[out.count - 1] = Span(last.start, max(last.end, s.end))
        } else {
            out.append(s)
        }
    }
    return out
}

/// How many seconds a set of spans covers, counting any overlap once.
public func totalSeconds(_ spans: [Span]) -> Int {
    normalized(spans).reduce(0) { $0 + $1.seconds }
}

/// Everything in `spans` that is not in `removing`.
///
/// A cut through the middle of a span leaves the pieces either side of it. That case
/// is the whole point: forty minutes of recorded Slack inside a seven-hour sleep must
/// leave sleep on both sides, not truncate it at the interruption.
public func subtracting(_ spans: [Span], _ removing: [Span]) -> [Span] {
    let cuts = normalized(removing)
    var out: [Span] = []
    for s in normalized(spans) {
        var cursor = s.start
        for cut in cuts where cut.end > s.start && cut.start < s.end {
            if cut.start > cursor { out.append(Span(cursor, cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if cursor < s.end { out.append(Span(cursor, s.end)) }
    }
    return out
}

/// Everything present in both sets.
public func intersecting(_ spans: [Span], _ other: [Span]) -> [Span] {
    let a = normalized(spans), b = normalized(other)
    var out: [Span] = []
    var i = 0, j = 0
    // Both sides are sorted and disjoint, so one pass over each is enough: advance
    // whichever ends first, since it cannot overlap anything later on the other side.
    while i < a.count && j < b.count {
        let start = max(a[i].start, b[j].start)
        let end = min(a[i].end, b[j].end)
        if start < end { out.append(Span(start, end)) }
        if a[i].end < b[j].end { i += 1 } else { j += 1 }
    }
    return out
}

/// The part of `spans` lying inside `window`.
///
/// This is how a note that crosses midnight contributes to two days: the same span
/// clipped to each day's window in turn.
public func clipped(_ spans: [Span], to window: Span) -> [Span] {
    intersecting(spans, [window])
}
