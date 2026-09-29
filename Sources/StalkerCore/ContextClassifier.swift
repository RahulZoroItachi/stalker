import Foundation

/// Decide which context a set of raw Accessibility values represents.
///
/// Precedence: a URL is the most specific thing we can know, then an open
/// document, then the window title. Kept separate from the Accessibility calls
/// so the precedence is testable without the permission.
public func classifyContextValue(axURL: String?, axDocument: String?, axTitle: String?) -> ContextResult {
    let title = (axTitle?.isEmpty ?? true) ? nil : axTitle

    if let raw = axURL, let normalized = normalizeURL(raw) {
        return .value(.url, normalized, title: title)
    }

    if let doc = axDocument, !doc.isEmpty {
        // kAXDocument is a file URL; store the plain path so path rules match it.
        let path = doc.hasPrefix("file://")
            ? (URL(string: doc)?.path ?? doc)
            : doc
        if !path.isEmpty { return .value(.file, path, title: title) }
    }

    if let title { return .value(.title, title, title: title) }
    return .none
}
