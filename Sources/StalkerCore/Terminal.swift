import Foundation

/// Narrower than this the table cannot hold its columns; wider than this the
/// breakdown labels drift so far from their durations that aligning them stops
/// helping. A reading of 0 means "not a terminal", which is treated as too narrow
/// rather than as unknown.
let minWidth = 80, maxWidth = 160, defaultWidth = 100

/// Bring a detected terminal width into the range the layout is designed for.
///
/// Kept separate from the ioctl so the clamping is testable without a terminal,
/// which the test runner does not have.
public func clampWidth(_ raw: Int?) -> Int {
    guard let raw else { return defaultWidth }
    return min(maxWidth, max(minWidth, raw))
}

/// The terminal's column count, or nil when stdout is not a terminal.
public func detectedWidth() -> Int? {
    var ws = winsize()
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 else { return nil }
    return Int(ws.ws_col)
}

/// Is stdout a terminal? Piping into a file or `less` must not emit escapes.
public func stdoutIsTerminal() -> Bool {
    isatty(STDOUT_FILENO) == 1
}

/// Wrap text in an ANSI colour, or return it untouched.
///
/// Callers must pad a field BEFORE colouring it. The escapes have no width on screen
/// but plenty in a `String`, so colouring first silently misaligns every column, and
/// only in the coloured output where plain-text tests would never see it.
public func colorize(_ s: String, _ code: Int, enabled: Bool) -> String {
    enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
}

/// Foreground codes assigned to categories in order of how much time they hold, so
/// the biggest category keeps the same colour from one day to the next.
let categoryPalette = [36, 33, 35, 32, 34, 31, 96, 93]

/// Time away from the machine is context, not content, so it recedes.
let awayColor = 90

/// Remove ANSI escape sequences, so a coloured line can be measured or compared
/// against the plain text it carries.
public func stripANSI(_ s: String) -> String {
    var out = "", inEscape = false
    for ch in s {
        if inEscape {
            if ch == "m" { inEscape = false }
        } else if ch == "\u{1B}" {
            inEscape = true
        } else {
            out.append(ch)
        }
    }
    return out
}

/// 256-colour background for the band that frames a whole report.
///
/// Most of a report's own text sets no foreground colour and rides on the
/// terminal's default, which on a dark theme is light. A light grey background
/// washed that straight out, so this sits dark instead: distinct from a plain
/// black terminal background without fighting the text painted over it.
let bandColor = 236

/// Wrap a block of text, line by line, in a full-width background colour.
///
/// A background is the one signal a run cannot be mistaken for the one before or
/// after it: nothing inside a report can mark where it starts and the next shell
/// prompt begins, only something drawn outside its own content can. Width is
/// measured after stripping any colour a line already carries, same rule the
/// tables follow when padding a cell: the escapes have no width on screen but
/// plenty in a `String`.
public func band(_ text: String, width: Int, enabled: Bool) -> String {
    guard enabled else { return text }
    let start = "\u{1B}[48;5;\(bandColor)m"
    let reset = "\u{1B}[0m"
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { substring -> String in
        let line = String(substring)
        let pad = String(repeating: " ", count: max(0, width - stripANSI(line).count))
        // A cell's own reset would end the band early and leave the rest of the
        // line unpainted, so the band is reapplied after every one of them.
        let repainted = line.replacingOccurrences(of: reset, with: reset + start)
        return start + repainted + pad + reset
    }.joined(separator: "\n")
}

/// Map each category to a colour, biggest first.
func colorMap(_ categories: [String]) -> [String: Int] {
    var out: [String: Int] = [:]
    var next = 0
    for category in categories {
        if awayCategories.contains(category) {
            out[category] = awayColor
        } else {
            out[category] = categoryPalette[next % categoryPalette.count]
            next += 1
        }
    }
    return out
}
