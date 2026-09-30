public struct FocusInfo: Equatable, Sendable {
    public let bundleId: String?
    public let appName: String?
    public let pid: Int32
    public init(bundleId: String?, appName: String?, pid: Int32) {
        self.bundleId = bundleId; self.appName = appName; self.pid = pid
    }
}

/// What a context lookup produced.
///
/// `denied` exists so a revoked Accessibility grant is distinguishable from an
/// app that simply has nothing to report. Spec §6.2, §9.
public enum ContextResult: Equatable, Sendable {
    case none
    case denied
    case value(ContextKind, String, title: String?)
}

public protocol FocusProbe: Sendable { func frontmost() -> FocusInfo? }
public protocol IdleProbe: Sendable { func inputIdleSeconds() -> Double }
public protocol LockProbe: Sendable { func isScreenLocked() -> Bool }
public protocol EngagementProbe: Sendable { func isEngaged(pid: Int32) -> Bool }
public protocol ContextProbe: Sendable { func context(for focus: FocusInfo) -> ContextResult }
public protocol FolderProbe: Sendable { func folder() -> String? }
public protocol CourierProbe: Sendable { func newest(now: Int, bundleId: String) -> CourierReading? }

public struct Probes: Sendable {
    public let focus: any FocusProbe
    public let idle: any IdleProbe
    public let lock: any LockProbe
    public let engagement: any EngagementProbe
    public let context: any ContextProbe
    public let courier: any CourierProbe

    public init(focus: any FocusProbe, idle: any IdleProbe, lock: any LockProbe,
                engagement: any EngagementProbe, context: any ContextProbe,
                courier: any CourierProbe) {
        self.focus = focus; self.idle = idle; self.lock = lock
        self.engagement = engagement; self.context = context; self.courier = courier
    }
}

public struct TickConfig: Sendable {
    public let samplePeriod: Int
    public let idleThreshold: Int
    public let terminalBundleIds: Set<String>

    public init(samplePeriod: Int, idleThreshold: Int, terminalBundleIds: Set<String>) {
        self.samplePeriod = samplePeriod
        self.idleThreshold = idleThreshold
        self.terminalBundleIds = terminalBundleIds
    }

    /// Spec §5.1, §5.4.
    public static let `default` = TickConfig(
        samplePeriod: 30,
        idleThreshold: 180,
        terminalBundleIds: ["com.mitchellh.ghostty", "com.apple.Terminal", "net.kovidgoyal.kitty",
                            "com.googlecode.iterm2", "dev.warp.Warp-Stable", "co.zeit.hyper"]
    )
}
