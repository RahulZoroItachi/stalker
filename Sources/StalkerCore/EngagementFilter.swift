public struct AssertionRecord: Equatable, Sendable {
    public let type: String
    public let name: String
    public init(type: String, name: String) { self.type = type; self.name = name }
}

/// Assertion types that mean "media is playing in this app".
private let displayAssertionTypes: Set<String> = [
    "NoDisplaySleepAssertion",           // taken by video players, mute or not
    "PreventUserIdleDisplaySleep",       // the older public name for the same intent
]

/// Is media playing in the given process?
///
/// Scoped to one pid on purpose. Probing found five assertions held permanently
/// by system processes — `powerd`, `coreaudiod`, `caffeinate`, and WindowServer's
/// `UserIsActive` — so a check of the form "does any display assertion exist"
/// would report engagement 24/7 and idle detection would never fire. Spec §5.4.
public func isEngaged(assertionsByPid: [Int32: [AssertionRecord]], pid: Int32) -> Bool {
    guard let held = assertionsByPid[pid] else { return false }
    for a in held {
        if displayAssertionTypes.contains(a.type) { return true }
        // Audio playback surfaces as an idle-sleep assertion whose name says so.
        // The type alone is too broad: caffeinate and powerd use the same type.
        if a.type == "NoIdleSleepAssertion" && a.name.lowercased().contains("playing audio") {
            return true
        }
    }
    return false
}
