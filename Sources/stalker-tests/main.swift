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

    t.eq(stalkerCoreVersion, "0.1.0", "harness reaches StalkerCore")

    return t.summary()
}

exit(run())
