import Foundation
import StalkerCore

/// Reads the folder the frontmost Finder window is showing, via AppleScript.
///
/// Finder is the one app whose context Accessibility cannot supply. It exposes no
/// AXURL and no document, so the AX chain falls through to the window title — the
/// bare folder name, which no path rule can match. AppleScript is the only source
/// of the POSIX path. Spec §5.3.
public struct FinderFolderProbe: FolderProbe {
    let timeoutSeconds: Int

    public init(timeoutSeconds: Int = 2) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func folder() -> String? {
        // Reuses the browser probe's osascript runner: same hard timeout, same
        // null stderr, no second copy of that logic to keep in step.
        guard let raw = BrowserAppleScriptProbe.runOsascript(
                Self.script(timeoutSeconds: timeoutSeconds),
                hardTimeout: timeoutSeconds + 1) else { return nil }
        return normalizeFolderPath(raw)
    }

    /// `Finder window` is the folder-browsing class specifically. Finder's plain
    /// `window` collection also holds Get Info panels, the Go to Folder sheet, and
    /// the preferences window — none of which have a folder behind them, so asking
    /// one for its `target` raises -1700 and the real folder window sitting behind
    /// it is never reached.
    ///
    /// Everything that still has no folder — zero folder windows open, a search
    /// result, the Trash — returns an empty string rather than raising.
    /// `runOsascript` maps empty output to nil, so those read as "Finder had
    /// nothing to say" and the caller degrades to the ordinary context chain.
    public static func script(timeoutSeconds: Int) -> String {
        """
        with timeout of \(timeoutSeconds) seconds
          tell application "Finder"
            try
              if (count of Finder windows) is 0 then return ""
              return POSIX path of (target of front Finder window as alias)
            on error
              return ""
            end try
          end tell
        end timeout
        """
    }
}

/// Finder's folder first, every other app unchanged.
///
/// Sits outside `FallbackContextProbe` rather than inside it because this is not
/// a fallback: for Finder the folder probe is the primary and only useful source,
/// so it runs first and the Accessibility call is skipped entirely on the happy
/// path.
public struct FinderContextProbe: ContextProbe {
    let primary: any ContextProbe
    let folder: any FolderProbe

    public init(primary: any ContextProbe, folder: any FolderProbe) {
        self.primary = primary
        self.folder = folder
    }

    public func context(for focus: FocusInfo) -> ContextResult {
        guard shouldUseFolderProbe(bundleId: focus.bundleId),
              let path = folder.folder() else { return primary.context(for: focus) }
        // No title: Finder's would be the bare folder name, which the path already
        // carries in full.
        return .value(.folder, path, title: nil)
    }
}
