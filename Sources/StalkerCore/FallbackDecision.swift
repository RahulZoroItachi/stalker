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
/// For a known browser, whenever Accessibility did not produce a URL. The single
/// exclusion is a `.url` result, which is not second-guessed — AX already
/// answered. A browser yielding only a `.title` falls back, because the title is
/// not the URL and the URL is what classification needs.
///
/// `.denied` falls back too, which reverses the original rule. That rule held
/// that substituting AppleScript would hide a revoked Accessibility grant and the
/// `denied` column would never fire. Two things make it the wrong trade:
///
/// - `denied` still fires. It is what gets recorded whenever AppleScript cannot
///   answer either, so the column now means "no source could supply a URL" —
///   strictly more useful than "AX in particular was refused". Every non-browser
///   app is untouched and keeps recording `denied` on its own.
/// - The cost was total. A denied grant meant no browser URL was collected at
///   all, for weeks, while Automation sat granted and able to supply every one of
///   them. Every URL rule silently stopped classifying.
///
/// A revoked grant stays visible where it belongs, in `doctor`, which reports
/// Accessibility directly. Spec §9.
public func shouldFallBack(primary: ContextResult, bundleId: String?,
                           browserBundleIds: Set<String>) -> Bool {
    guard let bundleId, browserBundleIds.contains(bundleId) else { return false }
    switch primary {
    case .value(.url, _, _):          return false
    case .denied, .none, .value:      return true
    }
}

/// Finder is the one app whose context comes from neither Accessibility nor the
/// shell courier.
public let finderBundleId = "com.apple.finder"

/// Should the folder probe run instead of the ordinary context chain?
///
/// Finder exposes no AXURL and no document, so Accessibility can only ever
/// return the window title — the bare folder name, which no path rule can
/// match. AppleScript is therefore the primary source here, not a fallback,
/// which is why this does not consider what Accessibility said. In particular it
/// runs even when Accessibility is denied: a `denied` reading for Finder would
/// carry no information, since a granted reading carries none either.
public func shouldUseFolderProbe(bundleId: String?) -> Bool {
    bundleId == finderBundleId
}
