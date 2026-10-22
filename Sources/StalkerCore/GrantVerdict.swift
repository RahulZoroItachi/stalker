/// What the recorded data says about the Accessibility grant.
public enum GrantVerdict: Equatable, Sendable {
    case granted(lastSeen: Int)
    case denied(lastSeen: Int)
    /// Nothing either way inside the window. A fresh install, not a failure.
    case notObserved
}

/// Judge the Accessibility grant from what the sampler actually recorded.
///
/// `AXIsProcessTrusted()` answers for the process tree's *responsible* process, not
/// always for the binary asking. Run from a shell the same signed binary reports
/// untrusted, because the answer describes whatever launched it; run from launchd it
/// reports trusted, because there it is responsible for itself. So a live call is the
/// wrong instrument for a command a person types, and the database is the right one:
/// the agent is the thing that needs the grant, and its rows are the record of
/// whether it had it. Spec §5.
///
/// Only `.title` and `.file` count as proof. `.url` can come from the AppleScript
/// fallback, `.cwd` from the shell courier and `.folder` from Finder, so none of them
/// distinguishes a live grant from a working fallback.
public func accessibilityVerdict(_ intervals: [Interval], now: Int,
                                 window: Int = 86_400) -> GrantVerdict {
    let cutoff = now - window
    var lastDenied: Int?
    var lastGranted: Int?
    for iv in intervals where iv.startedAt > cutoff {
        switch iv.contextKind {
        case .denied:
            lastDenied = max(lastDenied ?? iv.startedAt, iv.startedAt)
        case .title, .file:
            lastGranted = max(lastGranted ?? iv.startedAt, iv.startedAt)
        case .url, .cwd, .folder, nil:
            continue
        }
    }

    // A tie goes to granted. Reporting a working grant as broken is the anti-goal in
    // spec §1: it spends the trust the permission ask needs and returns nothing.
    switch (lastGranted, lastDenied) {
    case let (g?, d?): return g >= d ? .granted(lastSeen: g) : .denied(lastSeen: d)
    case let (g?, nil): return .granted(lastSeen: g)
    case let (nil, d?): return .denied(lastSeen: d)
    case (nil, nil):   return .notObserved
    }
}
