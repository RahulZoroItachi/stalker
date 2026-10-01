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
