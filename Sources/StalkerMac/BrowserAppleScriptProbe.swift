import Cocoa
import Foundation
import StalkerCore

/// Reads a browser's active-tab URL via AppleScript.
///
/// Measured at ~90 ms per call, against an expected 1–5 ms for Accessibility —
/// which is why this is the fallback and not the primary. Spec §10.
public struct BrowserAppleScriptProbe: Sendable {
    let timeoutSeconds: Int

    public init(timeoutSeconds: Int = 2) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func url(bundleId: String) -> String? {
        guard let script = Self.script(for: bundleId, timeoutSeconds: timeoutSeconds) else {
            return nil
        }
        // Don't launch a browser that isn't running just to ask it a question.
        guard NSWorkspace.shared.runningApplications
                .contains(where: { $0.bundleIdentifier == bundleId }) else { return nil }
        guard let raw = Self.runOsascript(script, hardTimeout: timeoutSeconds + 1) else { return nil }
        return normalizeURL(raw)
    }

    /// `with timeout of N seconds` bounds how long AppleScript waits for the
    /// Apple Event. A busy browser would otherwise hang the call indefinitely,
    /// and a sampler that blocks forever is a sampler that silently stopped.
    static func script(for bundleId: String, timeoutSeconds: Int) -> String? {
        let body: String
        switch bundleId {
        case "com.google.Chrome":
            body = #"tell application "Google Chrome" to return URL of active tab of front window"#
        case "com.microsoft.edgemac":
            body = #"tell application "Microsoft Edge" to return URL of active tab of front window"#
        case "com.brave.Browser":
            body = #"tell application "Brave Browser" to return URL of active tab of front window"#
        case "company.thebrowser.Browser":
            body = #"tell application "Arc" to return URL of active tab of front window"#
        case "com.apple.Safari":
            body = #"tell application "Safari" to return URL of front document"#
        default:
            return nil
        }
        return "with timeout of \(timeoutSeconds) seconds\n\(body)\nend timeout"
    }

    /// `with timeout` only bounds Apple Event waits, so the process is also killed
    /// outright as a backstop.
    static func runOsascript(_ script: String, hardTimeout: Int) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(TimeInterval(hardTimeout))
        while p.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if p.isRunning {
            p.terminate()
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}

/// Accessibility first, AppleScript second, for browsers only.
public struct FallbackContextProbe: ContextProbe {
    let primary: any ContextProbe
    let fallback: BrowserAppleScriptProbe
    let browserBundleIds: Set<String>

    public init(primary: any ContextProbe, fallback: BrowserAppleScriptProbe,
                browserBundleIds: Set<String>) {
        self.primary = primary
        self.fallback = fallback
        self.browserBundleIds = browserBundleIds
    }

    public func context(for focus: FocusInfo) -> ContextResult {
        let first = primary.context(for: focus)
        guard shouldFallBack(primary: first, bundleId: focus.bundleId,
                             browserBundleIds: browserBundleIds) else { return first }
        guard let bundleId = focus.bundleId,
              let url = fallback.url(bundleId: bundleId) else { return first }

        // Keep whatever title the primary found; only the URL is being replaced.
        var title: String?
        if case .value(_, _, let t) = first { title = t }
        return .value(.url, url, title: title)
    }
}
