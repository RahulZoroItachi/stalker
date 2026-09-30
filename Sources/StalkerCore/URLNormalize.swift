import Foundation

/// Does this look like a local-file URL rather than a web one?
public func isFileURL(_ raw: String) -> Bool {
    raw.lowercased().hasPrefix("file://")
}

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

    // A browser showing a local file reports `file:///path`, whose host is empty.
    // Running it through the web-URL path discarded it on the empty-host guard,
    // so every local PDF, download and HTML file recorded no context at all.
    // Return the plain decoded path instead — which is also exactly what the
    // path rules match against.
    if isFileURL(trimmed) {
        var rest = String(trimmed.dropFirst("file://".count))
        // file://localhost/path is equivalent to file:///path.
        if rest.lowercased().hasPrefix("localhost/") {
            rest = String(rest.dropFirst("localhost".count))
        }
        let path = rest.removingPercentEncoding ?? rest
        return path.isEmpty ? nil : path
    }

    // Drop fragment then query. Doing it textually avoids URLComponents' tolerance
    // for inputs that are not really URLs.
    var s = trimmed
    if let h = s.firstIndex(of: "#") { s = String(s[s.startIndex..<h]) }
    if let q = s.firstIndex(of: "?") { s = String(s[s.startIndex..<q]) }

    // Drop scheme, remembering that we saw one.
    var hadScheme = false
    if let r = s.range(of: "://") {
        s = String(s[r.upperBound...])
        hadScheme = true
    }

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

    // A host must look like a host: no spaces, and either a dot or an explicit
    // scheme. The scheme clause is what keeps `http://localhost:3000/app` — a dev
    // server has no dot in its host, and requiring one silently discarded every
    // local URL. A scheme-less, dotless word is still rejected.
    guard !host.isEmpty, !host.contains(" "), hadScheme || host.contains(".") else { return nil }

    return path.isEmpty ? host + "/" : host + path
}

/// Clean a folder path into the same shape every other context uses.
///
/// Finder reports a directory with a trailing slash, while a shell cwd never has
/// one. Left alone, the same folder would appear as two separate rows in a
/// report, and every rule naming a folder would need two patterns to catch both
/// spellings. Anything that is not an absolute path is rejected: Finder returns
/// an empty string for a window with no folder behind it.
public func normalizeFolderPath(_ raw: String) -> String? {
    var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard p.hasPrefix("/") else { return nil }
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    return p
}
