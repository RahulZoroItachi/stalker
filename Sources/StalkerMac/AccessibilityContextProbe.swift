import ApplicationServices
import Foundation
import StalkerCore

/// In-app context via Accessibility. One grant covers every app, including
/// Electron apps that expose no usable AppleScript dictionary. Spec §5.3.
public struct AccessibilityContextProbe: ContextProbe {
    let messagingTimeout: Float

    public init(messagingTimeout: Float = 1.0) {
        self.messagingTimeout = messagingTimeout
    }

    public func context(for focus: FocusInfo) -> ContextResult {
        // A revoked grant must be recorded as `denied`, never as nil. Collapsed
        // into nil it would be indistinguishable from an app that simply has no
        // context, and weeks of missing URLs would read as normal. Spec §9.
        guard AXIsProcessTrusted() else { return .denied }

        let app = AXUIElementCreateApplication(focus.pid)

        // AX is synchronous IPC into the target process: an app whose main thread
        // is blocked would hang this call indefinitely without a timeout.
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        guard let window = element(app, kAXFocusedWindowAttribute as String) else {
            return .none
        }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)

        return classifyContextValue(
            axURL: string(window, "AXURL"),
            axDocument: string(window, kAXDocumentAttribute as String),
            axTitle: string(window, kAXTitleAttribute as String)
        )
    }

    private func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// AXURL arrives as a CFURL on some apps and a CFString on others.
    private func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let v = value else { return nil }
        if let s = v as? String { return s }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }
}
