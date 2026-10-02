import Foundation

/// What one note actually logged, once recorded activity and earlier notes had their say.
///
/// `stated` and `claimed` are kept apart on purpose. When they differ, the report says
/// so: a note that silently logged less than it stated would read as a tracker that
/// lost time.
public struct NoteClaim: Equatable, Sendable {
    public let activity: String
    public let line: Int
    /// Seconds the note declared, clipped to the reported range.
    public let stated: Int
    /// Where it actually logged time.
    public let spans: [Span]
    /// Apps that held time inside the stated range, and for how long each.
    ///
    /// Only apps. Time lost to an earlier note is deliberately absent: blaming an app
    /// for it would send the reader looking for activity that was never there.
    public let heldBy: [String: Int]

    public var claimed: Int { totalSeconds(spans) }

    public init(activity: String, line: Int, stated: Int, spans: [Span],
                heldBy: [String: Int] = [:]) {
        self.activity = activity; self.line = line; self.stated = stated; self.spans = spans
        self.heldBy = heldBy
    }
}

/// Kinds a note may claim.
///
/// The rule, in the user's words: if the laptop recorded something keep it, unless what
/// it recorded is idle, locked or no data. `app` is absent because an app having focus
/// means there was either input or media playing, and both are real.
///
/// `idle` being here is the point. Walk away from an unlocked laptop and the sampler
/// records idle, not gap; without it a workout would log almost nothing.
let claimableKinds: Set<Kind> = [.idle, .locked, .gap]

private func span(of iv: Interval) -> Span {
    Span(iv.startedAt, max(iv.endedAt, iv.startedAt))
}

/// Cut an interval down to the parts of it inside `keep`.
///
/// Only ever applied to idle, locked and gap, whose `active` and `engaged` are
/// structurally zero: idle requires more input-idle seconds than a sample period, a
/// locked sample is written with no input, and a gap has no samples at all. So only
/// `samples` needs apportioning, and it is apportioned so the row still says roughly
/// how much evidence sits behind it.
func trimmed(_ iv: Interval, to keep: [Span]) -> [Interval] {
    let whole = span(of: iv).seconds
    return intersecting([span(of: iv)], keep).map { piece in
        var out = iv
        out.startedAt = piece.start
        out.endedAt = piece.end
        out.samples = whole > 0
            ? Int((Double(iv.samples) * Double(piece.seconds) / Double(whole)).rounded())
            : 0
        return out
    }
}

/// Apply notes to a day's recorded intervals.
///
/// Returns the recorded intervals with claimed time removed, plus what each note
/// managed to claim. The two together account for exactly the time that went in:
/// nothing is lost and nothing is counted twice.
public func resolveNotes(intervals: [Interval], notes: [Note], range: Span)
    -> (intervals: [Interval], claims: [NoteClaim]) {

    // Time an app held. This is what a note can never take.
    let appIntervals = intervals.filter { $0.kind == .app }
    let held = normalized(appIntervals.map(span(of:)))

    var takenByNotes: [Span] = []
    var claims: [NoteClaim] = []
    for note in notes {
        let inRange = clipped([note.span], to: range)
        // A note for another day has nothing to say about this one.
        guard !inRange.isEmpty else { continue }
        // Earlier notes are subtracted too, so two notes over the same hour split it
        // rather than both counting it. File order decides, which is arbitrary but
        // deterministic, and the loser reports claiming less than it stated.
        let available = subtracting(inRange, normalized(held + takenByNotes))

        // Which apps overlapped the stated range, so the report can name them. Measured
        // per interval rather than from the merged `held` set, which has already lost
        // track of who owned what.
        var heldBy: [String: Int] = [:]
        for iv in appIntervals {
            let overlap = totalSeconds(intersecting(inRange, [span(of: iv)]))
            guard overlap > 0 else { continue }
            heldBy[iv.appName ?? "(unknown)", default: 0] += overlap
        }

        claims.append(NoteClaim(activity: note.activity, line: note.line,
                                stated: totalSeconds(inRange), spans: available,
                                heldBy: heldBy))
        takenByNotes = normalized(takenByNotes + available)
    }

    var out: [Interval] = []
    for iv in intervals {
        guard claimableKinds.contains(iv.kind) else { out.append(iv); continue }
        out += trimmed(iv, to: subtracting([span(of: iv)], takenByNotes))
    }
    return (out, claims)
}

/// Turn claims into slices, cut at bucket boundaries so they sit in the timeline
/// alongside recorded time.
///
/// `kind` is nil and the counters are zero: nothing observed this time, so there is no
/// measured kind and no input to report an active share for.
public func noteSlices(_ claims: [NoteClaim], bucketSecs: Int) -> [Slice] {
    var out: [Slice] = []
    for claim in claims {
        for span in normalized(claim.spans) {
            var b = bucketStart(span.start, bucketSecs: bucketSecs)
            while b < span.end {
                let secs = min(span.end, b + bucketSecs) - max(span.start, b)
                if secs > 0 {
                    out.append(Slice(bucketStart: b, category: claim.activity, kind: nil,
                                     appName: nil, context: nil, seconds: secs,
                                     activeSeconds: 0, engagedSeconds: 0))
                }
                b += bucketSecs
            }
        }
    }
    return out
}
