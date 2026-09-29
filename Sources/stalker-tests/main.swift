import Foundation
import StalkerCore

@MainActor final class T {
    var failures = 0
    var total = 0

    func expect(_ cond: Bool, _ name: String, _ detail: String = "") {
        total += 1
        if cond {
            print("  ok   \(name)")
        } else {
            failures += 1
            print("  FAIL \(name) \(detail)")
        }
    }

    func eq<V: Equatable>(_ got: V, _ want: V, _ name: String) {
        expect(got == want, name, "got \(got) want \(want)")
    }

    func summary() -> Int32 {
        print("\n\(total - failures)/\(total) passed")
        if failures > 0 {
            print("FAILURES: \(failures)")
            return 1
        }
        return 0
    }
}

@MainActor func run() -> Int32 {
    let t = T()
    print("running tests")

    // --- Task 2: models and clock ---
    t.eq(Kind.app.rawValue, "app", "Kind raw value")
    t.eq(Kind(rawValue: "gap"), Kind.gap, "Kind round-trips")
    t.eq(ContextKind.denied.rawValue, "denied", "ContextKind denied raw value")

    let s = Sample(at: 100, kind: .app, bundleId: "com.google.Chrome", appName: "Google Chrome",
                   contextKind: .url, context: "docs.google.com/document", title: "Doc",
                   hadInput: true, engaged: false)
    let iv = Interval(id: nil, kind: .app, startedAt: 100, endedAt: 100,
                      bundleId: "com.google.Chrome", appName: "Google Chrome",
                      contextKind: .url, context: "docs.google.com/document", title: "Doc",
                      samples: 1, active: 1, engaged: 0)
    t.eq(s.key, iv.key, "Sample and Interval derive the same key")

    let other = Sample(at: 100, kind: .app, bundleId: "com.google.Chrome", appName: "Google Chrome",
                       contextKind: .url, context: "youtube.com/watch", title: nil,
                       hadInput: true, engaged: false)
    t.expect(s.key != other.key, "different context yields a different key")

    let fake = FakeClock(1000)
    t.eq(fake.now, 1000, "FakeClock starts at given time")
    fake.advance(30)
    t.eq(fake.now, 1030, "FakeClock advances")

    return t.summary()
}

exit(run())
