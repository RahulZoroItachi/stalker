import Foundation

/// Shell-style glob match using libc `fnmatch(3)`. No custom matcher, no dependency.
public func globMatches(_ pattern: String, _ subject: String) -> Bool {
    fnmatch(pattern, subject, 0) == 0
}

/// Reduce a URL to `host + path`, dropping scheme, userinfo, query, and fragment.
///
/// Query strings carry auth tokens, search terms, and session ids and contribute
/// nothing to classification, so they are discarded here — at collection — and
/// never written to disk. Spec §5.3, §11.
///
/// A URL with no path returns `host/` rather than `host`, because a rule glob of
/// the form `host/*` does not match a bare `host`.
public func normalizeURL(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Drop fragment then query. Doing it textually avoids URLComponents' tolerance
    // for inputs that are not really URLs.
    var s = trimmed
    if let h = s.firstIndex(of: "#") { s = String(s[s.startIndex..<h]) }
    if let q = s.firstIndex(of: "?") { s = String(s[s.startIndex..<q]) }

    // Drop scheme.
    if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }

    // Split host from path at the first "/".
    var host = s
    var path = ""
    if let slash = s.firstIndex(of: "/") {
        host = String(s[s.startIndex..<slash])
        path = String(s[slash...])
    }

    // Drop userinfo and port.
    if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
    if let colon = host.firstIndex(of: ":") { host = String(host[host.startIndex..<colon]) }

    // A host must look like a host: no spaces, and at least one dot.
    guard !host.isEmpty, !host.contains(" "), host.contains(".") else { return nil }

    return path.isEmpty ? host + "/" : host + path
}
