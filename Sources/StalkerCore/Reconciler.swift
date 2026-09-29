public enum Transition: Equatable, Sendable {
    case openFirst
    case bump
    case closeAndOpen
    case gapThenOpen(from: Int, to: Int)
}

/// Pure transition decision, so every edge case is unit-testable without a database.
///
/// The gap check comes before the key check on purpose. After a fifteen-hour
/// sleep the key is usually unchanged — the same app is still frontmost — so a
/// key-first ordering would silently bump one interval across the whole night.
/// Spec §6.4.
public func decide(open: Interval?, sample: Sample, samplePeriod: Int) -> Transition {
    guard let open else { return .openFirst }
    if sample.at - open.endedAt > 2 * samplePeriod {
        return .gapThenOpen(from: open.endedAt, to: sample.at)
    }
    return open.key == sample.key ? .bump : .closeAndOpen
}

/// A fresh interval covering exactly one sample.
public func makeInterval(from s: Sample) -> Interval {
    Interval(id: nil, kind: s.kind, startedAt: s.at, endedAt: s.at,
             bundleId: s.bundleId, appName: s.appName,
             contextKind: s.contextKind, context: s.context, title: s.title,
             samples: 1, active: s.hadInput ? 1 : 0, engaged: s.engaged ? 1 : 0)
}

/// Applies transitions to the store.
///
/// Rows are INSERTed when an interval opens and UPDATEd on every tick, so a
/// killed sampler loses at most one tick rather than the whole open interval.
/// Spec §6.3.
public final class Reconciler {
    private let store: Store
    private let samplePeriod: Int
    public private(set) var open: Interval?

    public init(store: Store, samplePeriod: Int) {
        self.store = store
        self.samplePeriod = samplePeriod
    }

    /// Adopt the most recent row as the open interval, so a restarted sampler
    /// continues an interval instead of fragmenting it.
    public func loadOpen() throws {
        open = try store.lastInterval()
    }

    public func ingest(_ s: Sample) throws {
        switch decide(open: open, sample: s, samplePeriod: samplePeriod) {
        case .openFirst:
            try insertNew(s)

        case .bump:
            guard var iv = open else { try insertNew(s); return }
            iv.endedAt = s.at
            iv.samples += 1
            if s.hadInput { iv.active += 1 }
            if s.engaged { iv.engaged += 1 }
            if let title = s.title { iv.title = title }
            try store.update(iv)
            open = iv

        case .closeAndOpen:
            if var iv = open {
                iv.endedAt = max(iv.endedAt, iv.startedAt)
                try store.update(iv)
            }
            try insertNew(s)

        case .gapThenOpen(let from, let to):
            var gap = Interval(id: nil, kind: .gap, startedAt: from, endedAt: to,
                               bundleId: nil, appName: nil, contextKind: nil,
                               context: nil, title: nil, samples: 0, active: 0, engaged: 0)
            gap.id = try store.insert(gap)
            try insertNew(s)
        }
    }

    private func insertNew(_ s: Sample) throws {
        var iv = makeInterval(from: s)
        iv.id = try store.insert(iv)
        open = iv
    }
}
