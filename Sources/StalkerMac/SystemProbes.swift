import Cocoa
import Foundation
import StalkerCore

/// Frontmost application. Requires no permission — verified.
public struct SystemFocusProbe: FocusProbe {
    public init() {}
    public func frontmost() -> FocusInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FocusInfo(bundleId: app.bundleIdentifier,
                         appName: app.localizedName,
                         pid: app.processIdentifier)
    }
}

/// Seconds since the last input event of ANY kind.
///
/// `kCGAnyInputEventType` (`~0`) is the union of input types: key presses,
/// modifier changes, cursor movement, scroll, clicks, and drags. Verified —
/// the ANY reading tracked the minimum of the individual types on every sample,
/// and agreed with `ioreg` HIDIdleTime to within 0.2 s.
///
/// This is why moving the trackpad or scrolling counts as activity, and why a
/// 180 s threshold genuinely means hands off. Spec §5.4.
public struct SystemIdleProbe: IdleProbe {
    public init() {}
    public func inputIdleSeconds() -> Double {
        guard let anyType = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyType)
    }
}

/// Whether the screen is locked.
public struct SystemLockProbe: LockProbe {
    public init() {}
    public func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

/// Reads the courier directory the zsh hook writes into.
///
/// Readings are nested one subdirectory per hosting app (`dir/<bundle-id>/<tty>`),
/// so a stale-but-present reading from one terminal app can never outrank a
/// fresher reading from a different terminal app just because it happens to be
/// newer. Only readings written by the app actually asked about are candidates.
public struct DirectoryCourierProbe: CourierProbe {
    let dir: String
    let maxAgeSecs: Int
    public init(dir: String, maxAgeSecs: Int = courierMaxAgeSecs) {
        self.dir = dir; self.maxAgeSecs = maxAgeSecs
    }
    public func newest(now: Int, bundleId: String) -> CourierReading? {
        readCourierDir(dir + "/" + bundleId, now: now, maxAgeSecs: maxAgeSecs)
    }
}
