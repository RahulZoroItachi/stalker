import Foundation

/// Decide which context a set of raw Accessibility values represents.
///
/// Precedence: a URL is the most specific thing we can know, then an open
/// document, then the window title. Kept separate from the Accessibility calls
/// so the precedence is testable without the permission.
public func classifyContextValue(axURL: String?, axDocument: String?, axTitle: String?) -> ContextResult {
    let title = (axTitle?.isEmpty ?? true) ? nil : axTitle

    if let raw = axURL, let normalized = normalizeURL(raw) {
        // A local file open in a browser is a file, not a web page — and saying so
        // keeps `url` honest about what it contains.
        return .value(isFileURL(raw) ? .file : .url, normalized, title: title)
    }

    if let doc = axDocument, !doc.isEmpty {
        // kAXDocument is usually a file URL, but Chrome has been observed putting
        // the tab's http(s) URL there when AXURL is absent — trust the scheme,
        // not the attribute name, or web pages get filed as local files.
        if isFileURL(doc) {
            let path = URL(string: doc)?.path ?? doc
            if !path.isEmpty { return .value(.file, path, title: title) }
        } else if let normalized = normalizeURL(doc) {
            return .value(.url, normalized, title: title)
        } else if !doc.isEmpty {
            return .value(.file, doc, title: title)
        }
    }

    if let title { return .value(.title, title, title: title) }
    return .none
}
