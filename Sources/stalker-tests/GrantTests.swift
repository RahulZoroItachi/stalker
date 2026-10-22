import Foundation
import StalkerCore

/// Tests for judging the Accessibility grant from recorded data rather than from a
/// live API call. Kept separate because the question is about evidence in the
/// database, not about any report.
@MainActor func grantTests(_ t: T) {
    func iv(_ at: Int, _ kind: ContextKind, _ bundle: String = "com.test.app") -> Interval {
        Interval(id: nil, kind: .app, startedAt: at, endedAt: at,
                 bundleId: bundle, appName: "Test", contextKind: kind,
                 context: "x", title: nil, samples: 1, active: 1, engaged: 0)
    }

    // .title and .file can only come from Accessibility. .url may come from the
    // AppleScript fallback, .cwd from the shell courier, .folder from Finder — so
    // none of those three prove the grant is live.
    t.eq(accessibilityVerdict([iv(1000, .title)], now: 1000), GrantVerdict.granted(lastSeen: 1000),
         "a title row proves Accessibility answered")
    t.eq(accessibilityVerdict([iv(1000, .file)], now: 1000), GrantVerdict.granted(lastSeen: 1000),
         "so does a file row")
    t.eq(accessibilityVerdict([iv(1000, .url)], now: 1000), GrantVerdict.notObserved,
         "a url proves nothing, the AppleScript fallback also produces it")
    t.eq(accessibilityVerdict([iv(1000, .cwd)], now: 1000), GrantVerdict.notObserved,
         "nor does a cwd, which comes from the shell courier")
    t.eq(accessibilityVerdict([iv(1000, .folder)], now: 1000), GrantVerdict.notObserved,
         "nor a Finder folder, which comes from AppleScript")
    t.eq(accessibilityVerdict([iv(1000, .denied)], now: 1000), GrantVerdict.denied(lastSeen: 1000),
         "a denied row is a revoked grant")

    // The most recent evidence decides, so a grant restored after a denial reads as granted.
    t.eq(accessibilityVerdict([iv(1000, .denied), iv(2000, .title)], now: 2000),
         GrantVerdict.granted(lastSeen: 2000), "newer evidence wins over older")
    t.eq(accessibilityVerdict([iv(2000, .denied), iv(1000, .title)], now: 2000),
         GrantVerdict.denied(lastSeen: 2000), "and in the other direction too")

    // A browser's `.file` row is NOT proof. The AppleScript fallback runs precisely
    // because Accessibility was denied, and it reports a local file as `.file`:
    // FallbackContextProbe returns `.value(url.hasPrefix("/") ? .file : .url, ...)`.
    // Counting it would make doctor report a grant that is not there.
    t.eq(accessibilityVerdict([iv(1000, .file, "com.google.Chrome")], now: 1000),
         GrantVerdict.notObserved, "a browser's file row could have come from the fallback")
    t.eq(accessibilityVerdict([iv(1000, .file, "com.apple.Preview")], now: 1000),
         GrantVerdict.granted(lastSeen: 1000), "a non-browser's file row is still proof")
    // The fallback never invents a title: it carries forward whatever the primary
    // found, and a denied primary carries nothing. So a title is proof even here.
    t.eq(accessibilityVerdict([iv(1000, .title, "com.google.Chrome")], now: 1000),
         GrantVerdict.granted(lastSeen: 1000), "a browser's title row is proof")
    // The scenario that matters: refuse Accessibility, open a local PDF in Chrome.
    t.eq(accessibilityVerdict([iv(1000, .denied, "com.google.Chrome"),
                               iv(2000, .file, "com.google.Chrome")], now: 2000),
         GrantVerdict.denied(lastSeen: 1000),
         "a denial still stands when the newer evidence is only a fallback file")

    // Review Focus 5: a fresh install has no evidence and must not read as failure.
    t.eq(accessibilityVerdict([], now: 1000), GrantVerdict.notObserved,
         "an empty database is not a failure")
    t.eq(accessibilityVerdict([iv(1000, .title)], now: 1_000_000), GrantVerdict.notObserved,
         "evidence older than the window is ignored")
}
