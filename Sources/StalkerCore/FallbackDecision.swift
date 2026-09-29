/// Browsers whose URL can be read by AppleScript. Automation to Chrome and Edge
/// is already granted on this machine — both returned live URLs when probed.
public let browserBundleIds: Set<String> = [
    "com.google.Chrome",
    "com.microsoft.edgemac",
    "com.apple.Safari",
    "company.thebrowser.Browser",   // Arc
    "com.brave.Browser",
]

/// Should the AppleScript fallback run?
///
/// Only when Accessibility produced no URL for a known browser. Two cases are
/// deliberately excluded:
///
/// - `.denied` never falls back. Recording `denied` is the only way a revoked
///   Accessibility grant stays visible; silently substituting AppleScript would
///   hide it and the `denied` column would never fire. Spec §9.
/// - A `.url` result is not second-guessed — AX already answered.
///
/// A browser yielding only a `.title` does fall back, because the title is not
/// the URL and the URL is what classification needs.
public func shouldFallBack(primary: ContextResult, bundleId: String?,
                           browserBundleIds: Set<String>) -> Bool {
    guard let bundleId, browserBundleIds.contains(bundleId) else { return false }
    switch primary {
    case .denied:                 return false
    case .value(.url, _, _):      return false
    case .none, .value:           return true
    }
}
