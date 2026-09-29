/// What a stretch of time represents. Spec §6.2.
public enum Kind: String, Sendable, Equatable, CaseIterable {
    case app        // a real application had focus
    case idle       // present but no input and nothing playing
    case locked     // screen locked
    case gap        // no data at all: sampler down or machine asleep
}

/// What kind of in-app context `Interval.context` holds. Spec §6.2.
/// `denied` is distinct from nil: nil means the app has no context to read,
/// `denied` means the permission was refused. Collapsing them would make a
/// revoked Accessibility grant indistinguishable from normal operation.
public enum ContextKind: String, Sendable, Equatable, CaseIterable {
    case url, cwd, file, folder, title, denied
}

/// One observation, taken once per tick.
public struct Sample: Sendable, Equatable {
    public let at: Int
    public let kind: Kind
    public let bundleId: String?
    public let appName: String?
    public let contextKind: ContextKind?
    public let context: String?
    public let title: String?
    public let hadInput: Bool
    public let engaged: Bool

    public init(at: Int, kind: Kind, bundleId: String?, appName: String?,
                contextKind: ContextKind?, context: String?, title: String?,
                hadInput: Bool, engaged: Bool) {
        self.at = at; self.kind = kind; self.bundleId = bundleId; self.appName = appName
        self.contextKind = contextKind; self.context = context; self.title = title
        self.hadInput = hadInput; self.engaged = engaged
    }
}

/// A continuous stretch of the same (kind, bundleId, context).
public struct Interval: Sendable, Equatable {
    public var id: Int64?
    public var kind: Kind
    public var startedAt: Int
    public var endedAt: Int
    public var bundleId: String?
    public var appName: String?
    public var contextKind: ContextKind?
    public var context: String?
    public var title: String?
    public var samples: Int
    public var active: Int
    public var engaged: Int

    public init(id: Int64?, kind: Kind, startedAt: Int, endedAt: Int,
                bundleId: String?, appName: String?, contextKind: ContextKind?,
                context: String?, title: String?, samples: Int, active: Int, engaged: Int) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.bundleId = bundleId; self.appName = appName; self.contextKind = contextKind
        self.context = context; self.title = title
        self.samples = samples; self.active = active; self.engaged = engaged
    }
}

/// Identity of an interval. A change here closes the open interval and opens a new one.
public struct IntervalKey: Hashable, Sendable {
    public let kind: Kind
    public let bundleId: String?
    public let context: String?
}

extension Sample {
    public var key: IntervalKey { IntervalKey(kind: kind, bundleId: bundleId, context: context) }
}

extension Interval {
    public var key: IntervalKey { IntervalKey(kind: kind, bundleId: bundleId, context: context) }
}
