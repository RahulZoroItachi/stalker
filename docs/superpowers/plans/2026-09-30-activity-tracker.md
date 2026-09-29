# Activity Tracker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local macOS tracker that records what app/context had focus every 30 seconds, stores it as intervals, and reports each 30-minute block of the day classified as work / pet-project / fun / unclear.

**Architecture:** One Swift package, four targets. `StalkerCore` holds all pure logic (models, URL normalisation, rule parsing and matching, the interval state machine, SQLite store, courier reader, report rendering) and imports no UI frameworks, so it is fully unit-testable. `StalkerMac` holds thin adapters over `NSWorkspace`, `CGEventSource`, `CGSession`, `IOKit` power assertions, and Accessibility, each conforming to a protocol declared in Core. `stalker` is the CLI (`sample`, `report`, `doctor`). `stalker-tests` is a hand-rolled test executable.

**Tech Stack:** Swift 6.3.3, SwiftPM, system libsqlite3, zsh, launchd. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-29-activity-tracker-design.md`

## Global Constraints

- **No third-party dependencies.** Spec §4. Everything uses the system toolchain.
- **No XCTest, no swift-testing.** This machine has Command Line Tools only (no `/Applications/Xcode.app`); both frameworks are absent — verified by attempting `import XCTest` and `import Testing`, each failing with "no such module". Tests are therefore an executable target `stalker-tests` run via `swift run stalker-tests`, which exits 0 on pass and 1 on failure. Never write `swift test` in this plan — it cannot work here.
- **Swift toolchain:** `Apple Swift version 6.3.3`, target `arm64-apple-macosx26.0`. `swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]`.
- **Swift 6 strict concurrency is on.** Global mutable `var` at file scope in an executable target is MainActor-isolated and cannot be mutated from a nonisolated function. Put mutable test state inside a `@MainActor final class` and call it from a `@MainActor func`. Verified.
- **`import Foundation` is required for `exit()`** in executable targets. Verified (its absence fails with "cannot find 'exit' in scope").
- **SQLite:** `import SQLite3`, and the Core target must declare `linkerSettings: [.linkedLibrary("sqlite3")]`. Verified working, sqlite version 3.51.0.
- **Sample period:** 30 seconds. **Idle threshold:** 180 seconds. Both config constants, spec §5.1 and §5.4.
- **URLs store host + path only.** Scheme, query string, and fragment are stripped at collection and never written to disk. Spec §5.3 and §11.
- **No `category` column in the database.** Classification is read-time only. Spec §6.2.
- **`"~/..."` inside double quotes does not expand in shell.** Use `"$HOME/..."`. Spec §12.

## Review Focus

Five failure modes the spec implies that no task's happy-path tests would catch. Each has a test pinned to the task that owns the code.

1. **A courier line whose path contains a space** — `Application Support` and many user folders contain spaces. Splitting the line on every space silently truncates the cwd to its first word, and the directory rule then never matches. Must split on the **first** space only. → Task 9.
2. **A URL with no path** — `https://youtube.com` normalises to a bare host, which `fnmatch("youtube.com/*", "youtube.com")` does **not** match, so a rule the user believes is working silently classifies nothing. A bare host must normalise to `host/`. → Task 3.
3. **A rule written with a leading `~`** — `context = "~/Work/*"` never matches the absolute `/Users/alex/Work/...` the courier records. Tildes in rule globs must be expanded at parse time. → Task 4.
4. **Clock moving backwards** (NTP correction, manual change) — produces `ended_at < started_at` and a negative duration that corrupts every total it lands in. Durations must clamp at zero. → Task 10.
5. **`rules.toml` missing or malformed** — if this degrades to "classify everything unclear", a typo silently voids a day of reporting. Parse failure must be a hard, reported error. → Task 4.

---

### Task 1: Package skeleton and test harness

**Files:**
- Create: `.gitignore`
- Create: `Package.swift`
- Create: `Sources/StalkerCore/Placeholder.swift`
- Create: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `@MainActor final class T` with `expect(_ cond: Bool, _ name: String, _ detail: String = "")`, `eq<V: Equatable>(_ got: V, _ want: V, _ name: String)`, and `summary() -> Int32`. Every later task adds cases to `Sources/stalker-tests/main.swift` using these three methods.

- [ ] **Step 1: Initialise the repository**

```bash
cd /Users/alex/Desktop/Casey/Projects/stalker
git init
printf '.build/\n.DS_Store\n*.db\n*.db-wal\n*.db-shm\n' > .gitignore
```

- [ ] **Step 2: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "stalker",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "StalkerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "StalkerMac", dependencies: ["StalkerCore"]),
        .executableTarget(name: "stalker", dependencies: ["StalkerCore", "StalkerMac"]),
        .executableTarget(name: "stalker-tests", dependencies: ["StalkerCore", "StalkerMac"]),
    ]
)
```

- [ ] **Step 3: Create a placeholder so `StalkerCore` compiles**

`Sources/StalkerCore/Placeholder.swift`:

```swift
// Replaced in Task 2. SwiftPM requires at least one source file per target.
public let stalkerCoreVersion = "0.1.0"
```

- [ ] **Step 4: Write the test harness**

`Sources/stalker-tests/main.swift`:

```swift
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
```

- [ ] **Step 5: Run the harness and verify it passes**

Run: `swift run stalker-tests`
Expected: `ok   harness reaches StalkerCore`, then `1/1 passed`. Exit code 0.

- [ ] **Step 6: Verify a failure exits nonzero**

Temporarily change the assertion to `t.eq(stalkerCoreVersion, "wrong", "deliberate failure")`.

Run: `swift run stalker-tests; echo "exit=$?"`
Expected: `FAIL deliberate failure got 0.1.0 want wrong`, `0/1 passed`, `exit=1`.

Then revert the assertion to `"0.1.0"` and re-run to confirm `exit=0`.

- [ ] **Step 7: Commit**

```bash
git add .gitignore Package.swift Sources/
git commit -m "chore: swift package skeleton and test harness"
```

---

### Task 2: Models and Clock

**Files:**
- Create: `Sources/StalkerCore/Models.swift`
- Delete: `Sources/StalkerCore/Placeholder.swift`
- Create: `Sources/StalkerCore/Clock.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: the `T` harness from Task 1.
- Produces:
  - `enum Kind: String { case app, idle, locked, gap }`
  - `enum ContextKind: String { case url, cwd, file, folder, title, denied }`
  - `struct Sample` with `at: Int, kind: Kind, bundleId: String?, appName: String?, contextKind: ContextKind?, context: String?, title: String?, hadInput: Bool, engaged: Bool`
  - `struct Interval` with `id: Int64?, kind: Kind, startedAt: Int, endedAt: Int, bundleId: String?, appName: String?, contextKind: ContextKind?, context: String?, title: String?, samples: Int, active: Int, engaged: Int`
  - `struct IntervalKey: Hashable` and `.key` on both `Sample` and `Interval`
  - `protocol Clock { var now: Int { get } }`, `struct SystemClock`, `final class FakeClock` with `advance(_ seconds: Int)`

- [ ] **Step 1: Write the failing tests**

Add to `run()` in `Sources/stalker-tests/main.swift`, replacing the Task 1 placeholder assertion:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: compile errors — `cannot find 'Kind' in scope`, `cannot find 'Sample' in scope`, `cannot find 'FakeClock' in scope`.

- [ ] **Step 3: Write `Models.swift`**

```swift
/// What a stretch of time represents. Spec §6.2.
public enum Kind: String, Sendable, Equatable, CaseIterable {
    case app        // a real application had focus
    case idle       // present but no input and nothing playing
    case locked     // screen locked
    case gap        // no data at all: sampler down or machine asleep
}

/// What kind of in-app context `Interval.context` holds. Spec §6.2.
/// `denied` is distinct from nil: nil means the app has no context to read,
/// `denied` means the permission was refused. Collapsing them would make a
/// revoked Accessibility grant indistinguishable from normal operation.
public enum ContextKind: String, Sendable, Equatable, CaseIterable {
    case url, cwd, file, folder, title, denied
}

/// One observation, taken once per tick.
public struct Sample: Sendable, Equatable {
    public let at: Int
    public let kind: Kind
    public let bundleId: String?
    public let appName: String?
    public let contextKind: ContextKind?
    public let context: String?
    public let title: String?
    public let hadInput: Bool
    public let engaged: Bool

    public init(at: Int, kind: Kind, bundleId: String?, appName: String?,
                contextKind: ContextKind?, context: String?, title: String?,
                hadInput: Bool, engaged: Bool) {
        self.at = at; self.kind = kind; self.bundleId = bundleId; self.appName = appName
        self.contextKind = contextKind; self.context = context; self.title = title
        self.hadInput = hadInput; self.engaged = engaged
    }
}

/// A continuous stretch of the same (kind, bundleId, context).
public struct Interval: Sendable, Equatable {
    public var id: Int64?
    public var kind: Kind
    public var startedAt: Int
    public var endedAt: Int
    public var bundleId: String?
    public var appName: String?
    public var contextKind: ContextKind?
    public var context: String?
    public var title: String?
    public var samples: Int
    public var active: Int
    public var engaged: Int

    public init(id: Int64?, kind: Kind, startedAt: Int, endedAt: Int,
                bundleId: String?, appName: String?, contextKind: ContextKind?,
                context: String?, title: String?, samples: Int, active: Int, engaged: Int) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.bundleId = bundleId; self.appName = appName; self.contextKind = contextKind
        self.context = context; self.title = title
        self.samples = samples; self.active = active; self.engaged = engaged
    }
}

/// Identity of an interval. A change here closes the open interval and opens a new one.
public struct IntervalKey: Hashable, Sendable {
    public let kind: Kind
    public let bundleId: String?
    public let context: String?
}

extension Sample {
    public var key: IntervalKey { IntervalKey(kind: kind, bundleId: bundleId, context: context) }
}

extension Interval {
    public var key: IntervalKey { IntervalKey(kind: kind, bundleId: bundleId, context: context) }
}
```

- [ ] **Step 4: Write `Clock.swift` and delete the placeholder**

```swift
import Foundation

/// Injectable time, so interval and gap logic can be tested deterministically.
public protocol Clock: Sendable {
    var now: Int { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Int { Int(Date().timeIntervalSince1970) }
}

public final class FakeClock: Clock, @unchecked Sendable {
    private var t: Int
    public init(_ t: Int) { self.t = t }
    public var now: Int { t }
    public func advance(_ seconds: Int) { t += seconds }
}
```

```bash
rm Sources/StalkerCore/Placeholder.swift
```

Also remove the `t.eq(stalkerCoreVersion, ...)` line from `main.swift` if it is still present, since `stalkerCoreVersion` no longer exists.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all seven Task 2 assertions `ok`, `7/7 passed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/StalkerCore/Models.swift Sources/StalkerCore/Clock.swift Sources/stalker-tests/main.swift
git rm --cached Sources/StalkerCore/Placeholder.swift 2>/dev/null || true
git add -A
git commit -m "feat: interval and sample models, injectable clock"
```

---

### Task 3: URL normalisation

**Files:**
- Create: `Sources/StalkerCore/URLNormalize.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `func normalizeURL(_ raw: String) -> String?` — returns `host + path` with scheme, query string, fragment, and userinfo removed. A URL with no path returns `host/` (trailing slash), so that `fnmatch` globs of the form `host/*` match. Returns `nil` if no host can be extracted.

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 3: URL normalisation ---
    t.eq(normalizeURL("https://docs.google.com/document/d/1Wkwi7yo/edit?tab=t.0"),
         "docs.google.com/document/d/1Wkwi7yo/edit", "strips scheme and query")
    t.eq(normalizeURL("https://www.youtube.com/watch?v=m36qlrBAMTo"),
         "www.youtube.com/watch", "strips video id query")
    t.eq(normalizeURL("https://github.com/a/b#readme"), "github.com/a/b", "strips fragment")
    t.eq(normalizeURL("http://example.com/p?q=1#frag"), "example.com/p", "strips both")
    t.eq(normalizeURL("https://example.com/path"), "example.com/path", "passthrough")

    // Review Focus 2: a bare host must gain a trailing slash, else `host/*` never matches it.
    t.eq(normalizeURL("https://youtube.com"), "youtube.com/", "bare host gains trailing slash")
    t.eq(normalizeURL("https://youtube.com/"), "youtube.com/", "explicit root stays root")
    t.expect(globMatches("youtube.com/*", normalizeURL("https://youtube.com") ?? ""),
             "bare host matches host/* glob")

    t.eq(normalizeURL("https://user:pw@example.com/p"), "example.com/p", "strips userinfo")
    t.eq(normalizeURL("not a url"), nil, "unparseable returns nil")
    t.eq(normalizeURL(""), nil, "empty returns nil")
```

`globMatches` is introduced in Task 4. To keep this task independently runnable, add the one-line helper now inside `URLNormalize.swift` (Task 4 will use the same function, not redefine it).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'normalizeURL' in scope`, `cannot find 'globMatches' in scope`.

- [ ] **Step 3: Write `URLNormalize.swift`**

```swift
import Foundation

/// Shell-style glob match using libc `fnmatch(3)`. No custom matcher, no dependency.
public func globMatches(_ pattern: String, _ subject: String) -> Bool {
    fnmatch(pattern, subject, 0) == 0
}

/// Reduce a URL to `host + path`, dropping scheme, userinfo, query, and fragment.
///
/// Query strings carry auth tokens, search terms, and session ids and contribute
/// nothing to classification, so they are discarded here — at collection — and
/// never written to disk. Spec §5.3, §11.
///
/// A URL with no path returns `host/` rather than `host`, because a rule glob of
/// the form `host/*` does not match a bare `host`.
public func normalizeURL(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Drop fragment then query. Doing it textually avoids URLComponents' tolerance
    // for inputs that are not really URLs.
    var s = trimmed
    if let h = s.firstIndex(of: "#") { s = String(s[s.startIndex..<h]) }
    if let q = s.firstIndex(of: "?") { s = String(s[s.startIndex..<q]) }

    // Drop scheme.
    if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }

    // Split host from path at the first "/".
    var host = s
    var path = ""
    if let slash = s.firstIndex(of: "/") {
        host = String(s[s.startIndex..<slash])
        path = String(s[slash...])
    }

    // Drop userinfo and port.
    if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
    if let colon = host.firstIndex(of: ":") { host = String(host[host.startIndex..<colon]) }

    // A host must look like a host: no spaces, and at least one dot.
    guard !host.isEmpty, !host.contains(" "), host.contains(".") else { return nil }

    return path.isEmpty ? host + "/" : host + path
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all eleven Task 3 assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/StalkerCore/URLNormalize.swift Sources/stalker-tests/main.swift
git commit -m "feat: URL normalisation to host+path, dropping query and fragment"
```

---

### Task 4: rules.toml parser

**Files:**
- Create: `Sources/StalkerCore/RulesFile.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `globMatches` from Task 3 (not redefined here).
- Produces:
  - `struct Rule` with `app: String?, appName: String?, context: String?, category: String`, and computed `tier: Int`
  - `struct RuleSet` with `defaultCategory: String, rules: [Rule]` (pre-sorted by tier)
  - `enum RulesError: Error, Equatable, CustomStringConvertible` with cases `syntax(line:text:)`, `unknownKey(line:key:)`, `missingCategory(line:)`, `keyOutsideRule(line:key:)`, `ruleMatchesEverything(line:)`, `emptyRuleSet`
  - `func parseRules(_ text: String, homeDirectory: String) throws -> RuleSet`

Supported TOML subset, exactly: `#` comments, blank lines, a top-level `default = "value"`, and `[[rule]]` headers each followed by `key = "value"` lines where key is one of `app`, `app_name`, `context`, `category`. Anything else throws. Spec §7.1.

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 4: rules file parsing ---
    let goodToml = """
    default = "unclear"

    [[rule]]
    app = "com.google.Chrome"
    category = "work"

    [[rule]]
    app = "com.microsoft.edgemac"
    category = "fun"

    [[rule]]
    app_name = "Google Meet"
    category = "work"

    [[rule]]
    context = "*/Casey/Work/*"
    category = "work"

    [[rule]]
    context = "*/Casey/Projects/*"
    category = "pet-project"
    """

    if let rs = try? parseRules(goodToml, homeDirectory: "/Users/alex") {
        t.eq(rs.defaultCategory, "unclear", "parses default category")
        t.eq(rs.rules.count, 5, "parses five rules")
        t.expect(rs.rules.contains { $0.app == "com.google.Chrome" && $0.category == "work" },
                 "parses Chrome rule")
        t.expect(rs.rules.contains { $0.appName == "Google Meet" && $0.category == "work" },
                 "parses PWA rule by app_name")
        t.expect(rs.rules.contains { $0.context == "*/Casey/Projects/*" && $0.category == "pet-project" },
                 "parses context rule")
    } else {
        t.expect(false, "good toml parses")
    }

    // Review Focus 3: a leading ~ must be expanded, else it never matches an absolute cwd.
    let tildeToml = """
    default = "unclear"

    [[rule]]
    context = "~/Work/*"
    category = "work"
    """
    if let rs = try? parseRules(tildeToml, homeDirectory: "/Users/alex") {
        t.eq(rs.rules.first?.context, "/Users/alex/Work/*", "expands leading tilde in context glob")
        t.expect(globMatches(rs.rules.first!.context!, "/Users/alex/Work/PM_Assistant"),
                 "expanded glob matches an absolute path")
    } else {
        t.expect(false, "tilde toml parses")
    }

    // Review Focus 5: malformed input must throw, never silently degrade.
    func parseThrows(_ s: String, _ name: String) {
        do {
            _ = try parseRules(s, homeDirectory: "/Users/alex")
            t.expect(false, name, "expected a throw but parsing succeeded")
        } catch {
            t.expect(true, name)
        }
    }
    parseThrows("default = \"unclear\"\n[[rule]]\napp = \"x\"\n", "rule without category throws")
    parseThrows("default = \"unclear\"\n[[rule]]\nbogus = \"x\"\ncategory = \"work\"\n", "unknown key throws")
    parseThrows("default = \"unclear\"\napp = \"x\"\n", "key outside a rule throws")
    parseThrows("default = \"unclear\"\n[[rule]]\ncategory = \"work\"\n", "rule matching everything throws")
    parseThrows("default = \"unclear\"\n", "empty rule set throws")
    parseThrows("this is not toml\n", "garbage throws")

    // Tier assignment.
    let tierToml = """
    default = "unclear"

    [[rule]]
    app = "com.google.Chrome"
    context = "youtube.com/*"
    category = "fun"

    [[rule]]
    context = "*/Work/*"
    category = "work"

    [[rule]]
    app = "com.google.Chrome"
    category = "work"
    """
    if let rs = try? parseRules(tierToml, homeDirectory: "/Users/alex") {
        t.eq(rs.rules.map(\.tier), [1, 2, 3], "rules are sorted by tier, most specific first")
    } else {
        t.expect(false, "tier toml parses")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'parseRules' in scope`.

- [ ] **Step 3: Write `RulesFile.swift`**

```swift
import Foundation

/// One classification rule. Spec §7.1.
///
/// `app` matches `Interval.bundleId`; `appName` matches `Interval.appName`.
/// Both exist because PWA bundle ids are opaque, install-specific hashes —
/// `Google Meet` is `com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan` —
/// which are unreadable and do not survive a reinstall.
///
/// If both `app` and `appName` are given, either matching satisfies the app
/// condition; they are two ways of naming the same thing, not an AND.
public struct Rule: Sendable, Equatable {
    public let app: String?
    public let appName: String?
    public let context: String?
    public let category: String

    public init(app: String?, appName: String?, context: String?, category: String) {
        self.app = app; self.appName = appName; self.context = context; self.category = category
    }

    /// Specificity tier. Lower wins. Spec §7.2.
    public var tier: Int {
        let hasApp = app != nil || appName != nil
        let hasContext = context != nil
        if hasApp && hasContext { return 1 }
        if hasContext { return 2 }
        return 3
    }
}

public struct RuleSet: Sendable, Equatable {
    public let defaultCategory: String
    /// Sorted by tier ascending; original file order preserved within a tier.
    public let rules: [Rule]

    public init(defaultCategory: String, rules: [Rule]) {
        self.defaultCategory = defaultCategory
        self.rules = rules
    }
}

public enum RulesError: Error, Equatable, CustomStringConvertible {
    case syntax(line: Int, text: String)
    case unknownKey(line: Int, key: String)
    case missingCategory(line: Int)
    case keyOutsideRule(line: Int, key: String)
    case ruleMatchesEverything(line: Int)
    case emptyRuleSet

    public var description: String {
        switch self {
        case .syntax(let l, let t):            return "rules.toml line \(l): cannot parse \"\(t)\""
        case .unknownKey(let l, let k):        return "rules.toml line \(l): unknown key \"\(k)\" (expected app, app_name, context, or category)"
        case .missingCategory(let l):          return "rules.toml line \(l): this [[rule]] has no category"
        case .keyOutsideRule(let l, let k):    return "rules.toml line \(l): \"\(k)\" appears before any [[rule]] header"
        case .ruleMatchesEverything(let l):    return "rules.toml line \(l): this [[rule]] has no app, app_name, or context, so it would match everything"
        case .emptyRuleSet:                    return "rules.toml contains no [[rule]] blocks"
        }
    }
}

/// Parse the supported TOML subset. Any deviation throws rather than being
/// skipped: a silently ignored typo would void a day of reporting without
/// any visible symptom. Spec §9.
public func parseRules(_ text: String, homeDirectory: String) throws -> RuleSet {
    var defaultCategory = "unclear"
    var rules: [Rule] = []

    var app: String?, appName: String?, context: String?, category: String?
    var ruleStartLine = 0
    var inRule = false

    func flush() throws {
        guard inRule else { return }
        guard let cat = category else { throw RulesError.missingCategory(line: ruleStartLine) }
        guard app != nil || appName != nil || context != nil else {
            throw RulesError.ruleMatchesEverything(line: ruleStartLine)
        }
        rules.append(Rule(app: app, appName: appName, context: context, category: cat))
        app = nil; appName = nil; context = nil; category = nil
    }

    for (idx, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let lineNo = idx + 1
        var line = String(rawLine)
        if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }

        if line == "[[rule]]" {
            try flush()
            inRule = true
            ruleStartLine = lineNo
            continue
        }

        guard let eq = line.firstIndex(of: "=") else {
            throw RulesError.syntax(line: lineNo, text: line)
        }
        let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            throw RulesError.syntax(line: lineNo, text: line)
        }
        value = String(value.dropFirst().dropLast())

        if !inRule {
            guard key == "default" else { throw RulesError.keyOutsideRule(line: lineNo, key: key) }
            defaultCategory = value
            continue
        }

        switch key {
        case "app":      app = value
        case "app_name": appName = value
        case "context":  context = expandTilde(value, home: homeDirectory)
        case "category": category = value
        default:         throw RulesError.unknownKey(line: lineNo, key: key)
        }
    }
    try flush()

    guard !rules.isEmpty else { throw RulesError.emptyRuleSet }

    // Stable sort by tier: most specific first. A stable sort keeps file order
    // within a tier, so rules cannot be broken by being written in the wrong
    // order — the usual footgun of first-match-wins lists. Spec §7.2.
    let sorted = rules.enumerated()
        .sorted { ($0.element.tier, $0.offset) < ($1.element.tier, $1.offset) }
        .map(\.element)

    return RuleSet(defaultCategory: defaultCategory, rules: sorted)
}

/// A rule written `~/Work/*` must match the absolute `/Users/alex/Work/...`
/// that the courier records, so the tilde is expanded at parse time.
func expandTilde(_ glob: String, home: String) -> String {
    if glob == "~" { return home }
    if glob.hasPrefix("~/") { return home + String(glob.dropFirst(1)) }
    return glob
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all Task 4 assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/StalkerCore/RulesFile.swift Sources/stalker-tests/main.swift
git commit -m "feat: rules.toml subset parser with tier sorting and hard errors"
```

---

### Task 5: Rule matcher

**Files:**
- Create: `Sources/StalkerCore/RuleMatcher.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `Rule`, `RuleSet` (Task 4), `globMatches` (Task 3), `Interval` (Task 2).
- Produces:
  - `func matches(_ rule: Rule, _ iv: Interval) -> Bool`
  - `func classify(_ iv: Interval, with rs: RuleSet) -> String` — first match in tier order, else `rs.defaultCategory`

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 5: rule matching ---
    func mkInterval(bundle: String?, name: String?, ctx: String?) -> Interval {
        Interval(id: nil, kind: .app, startedAt: 0, endedAt: 30,
                 bundleId: bundle, appName: name, contextKind: ctx == nil ? nil : .url,
                 context: ctx, title: nil, samples: 1, active: 1, engaged: 0)
    }

    let rsToml = """
    default = "unclear"

    [[rule]]
    app = "com.google.Chrome"
    category = "work"

    [[rule]]
    app = "com.microsoft.edgemac"
    category = "fun"

    [[rule]]
    app_name = "Google Meet"
    category = "work"

    [[rule]]
    context = "*/Casey/Work/*"
    category = "work"

    [[rule]]
    context = "*/Casey/Projects/*"
    category = "pet-project"

    [[rule]]
    app = "com.google.Chrome"
    context = "youtube.com/*"
    category = "fun"
    """
    let rs = try! parseRules(rsToml, homeDirectory: "/Users/alex")

    t.eq(classify(mkInterval(bundle: "com.google.Chrome", name: "Google Chrome",
                             ctx: "docs.google.com/document/d/1/edit"), with: rs),
         "work", "Chrome classifies as work")
    t.eq(classify(mkInterval(bundle: "com.microsoft.edgemac", name: "Microsoft Edge",
                             ctx: "www.youtube.com/watch"), with: rs),
         "fun", "Edge classifies as fun")

    // PWA: opaque bundle id, matched by name instead.
    t.eq(classify(mkInterval(bundle: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
                             name: "Google Meet", ctx: nil), with: rs),
         "work", "Google Meet classifies by app_name despite opaque bundle id")

    // Context-only rules are app-independent: same rule serves terminal cwd.
    t.eq(classify(mkInterval(bundle: "com.mitchellh.ghostty", name: "Ghostty",
                             ctx: "/Users/alex/Desktop/Casey/Work/PM_Assistant"), with: rs),
         "work", "Work directory classifies as work")
    t.eq(classify(mkInterval(bundle: "com.mitchellh.ghostty", name: "Ghostty",
                             ctx: "/Users/alex/Desktop/Casey/Projects/stalker"), with: rs),
         "pet-project", "Projects directory classifies as pet-project")

    // Tier 1 beats tier 3: the specific youtube-in-Chrome rule wins over Chrome=work.
    t.eq(classify(mkInterval(bundle: "com.google.Chrome", name: "Google Chrome",
                             ctx: "youtube.com/watch"), with: rs),
         "fun", "tier 1 app+context rule beats tier 3 app-only rule")

    t.eq(classify(mkInterval(bundle: "com.tinyspeck.slackmacgap", name: "Slack", ctx: nil), with: rs),
         "unclear", "unmatched falls through to default, never guessed")

    // A rule naming only app must not match a different app.
    t.expect(!matches(Rule(app: "com.google.Chrome", appName: nil, context: nil, category: "work"),
                      mkInterval(bundle: "com.apple.Notes", name: "Notes", ctx: nil)),
             "app rule does not match a different bundle id")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'classify' in scope`, `cannot find 'matches' in scope`.

- [ ] **Step 3: Write `RuleMatcher.swift`**

```swift
/// Does this rule apply to this interval?
///
/// Every condition the rule states must hold. Conditions it omits are ignored.
/// `app` and `appName` are alternatives: if either is stated and matches, the
/// app condition is satisfied.
public func matches(_ rule: Rule, _ iv: Interval) -> Bool {
    if rule.app != nil || rule.appName != nil {
        let byBundle = rule.app != nil && rule.app == iv.bundleId
        let byName = rule.appName != nil && rule.appName == iv.appName
        if !(byBundle || byName) { return false }
    }
    if let pattern = rule.context {
        guard let ctx = iv.context, globMatches(pattern, ctx) else { return false }
    }
    return true
}

/// Category for an interval. First match in tier order wins.
///
/// Classification happens here, at read time, never at collection time — which
/// is why a rule added in March re-classifies January. Spec §7.
public func classify(_ iv: Interval, with rs: RuleSet) -> String {
    for rule in rs.rules where matches(rule, iv) {
        return rule.category
    }
    return rs.defaultCategory
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all nine Task 5 assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/StalkerCore/RuleMatcher.swift Sources/stalker-tests/main.swift
git commit -m "feat: read-time rule matcher with tier precedence"
```

---

### Task 6: SQLite store

**Files:**
- Create: `Sources/StalkerCore/Store.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `Interval`, `Kind`, `ContextKind` (Task 2).
- Produces:
  - `enum StoreError: Error, Equatable` with cases `open(String)`, `sql(String)`, `missingId`
  - `final class Store` with `init(path: String) throws`, `migrate() throws`, `insert(_ iv: Interval) throws -> Int64`, `update(_ iv: Interval) throws`, `lastInterval() throws -> Interval?`, `intervals(from: Int, to: Int) throws -> [Interval]`
  - Pass `":memory:"` as path for tests.

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 6: store ---
    do {
        let store = try Store(path: ":memory:")
        try store.migrate()
        t.expect(true, "migrate succeeds on a fresh database")
        t.eq(try store.lastInterval() == nil, true, "fresh database has no last interval")

        var iv = Interval(id: nil, kind: .app, startedAt: 1000, endedAt: 1000,
                          bundleId: "com.google.Chrome", appName: "Google Chrome",
                          contextKind: .url, context: "docs.google.com/d/1/edit",
                          title: "Doc", samples: 1, active: 1, engaged: 0)
        let rowid = try store.insert(iv)
        t.expect(rowid > 0, "insert returns a rowid")
        iv.id = rowid

        if let back = try store.lastInterval() {
            t.eq(back.bundleId, "com.google.Chrome", "round-trips bundle id")
            t.eq(back.context, "docs.google.com/d/1/edit", "round-trips context")
            t.eq(back.contextKind, ContextKind.url, "round-trips context kind")
            t.eq(back.samples, 1, "round-trips samples")
            t.eq(back.id, rowid, "round-trips id")
        } else {
            t.expect(false, "lastInterval returns the inserted row")
        }

        // Bump in place: ended_at and counters move, no new row.
        iv.endedAt = 1030; iv.samples = 2; iv.active = 2; iv.engaged = 1
        try store.update(iv)
        if let back = try store.lastInterval() {
            t.eq(back.endedAt, 1030, "update bumps ended_at")
            t.eq(back.samples, 2, "update bumps samples")
            t.eq(back.engaged, 1, "update bumps engaged")
            t.eq(back.id, rowid, "update does not create a new row")
        } else {
            t.expect(false, "lastInterval after update")
        }

        // Nullable columns survive a round trip as nil, distinct from "".
        let bare = Interval(id: nil, kind: .gap, startedAt: 2000, endedAt: 3000,
                            bundleId: nil, appName: nil, contextKind: nil,
                            context: nil, title: nil, samples: 0, active: 0, engaged: 0)
        _ = try store.insert(bare)
        if let back = try store.lastInterval() {
            t.eq(back.kind, Kind.gap, "round-trips gap kind")
            t.eq(back.bundleId == nil, true, "nil bundle id stays nil, not empty string")
            t.eq(back.contextKind == nil, true, "nil context kind stays nil")
        } else {
            t.expect(false, "lastInterval for gap row")
        }

        // Range query.
        let rows = try store.intervals(from: 900, to: 1500)
        t.eq(rows.count, 1, "range query filters by time")
        t.eq(rows.first?.bundleId, "com.google.Chrome", "range query returns the right row")

        // 'denied' is a real, distinguishable value, not nil.
        let denied = Interval(id: nil, kind: .app, startedAt: 4000, endedAt: 4030,
                              bundleId: "com.tinyspeck.slackmacgap", appName: "Slack",
                              contextKind: .denied, context: nil, title: nil,
                              samples: 1, active: 1, engaged: 0)
        _ = try store.insert(denied)
        t.eq(try store.lastInterval()?.contextKind, ContextKind.denied,
             "denied context kind round-trips and is distinct from nil")

        // update without an id is a programming error, not a silent no-op.
        do {
            try store.update(Interval(id: nil, kind: .app, startedAt: 0, endedAt: 0,
                                      bundleId: nil, appName: nil, contextKind: nil,
                                      context: nil, title: nil, samples: 0, active: 0, engaged: 0))
            t.expect(false, "update without id throws")
        } catch {
            t.expect(true, "update without id throws")
        }
    } catch {
        t.expect(false, "store tests ran without throwing", "\(error)")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'Store' in scope`.

- [ ] **Step 3: Write `Store.swift`**

```swift
import Foundation
import SQLite3

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case open(String)
    case sql(String)
    case missingId

    public var description: String {
        switch self {
        case .open(let m):  return "cannot open database: \(m)"
        case .sql(let m):   return "sql error: \(m)"
        case .missingId:    return "cannot update an interval that has no id"
        }
    }
}

/// SQLite tells us to copy bound strings rather than borrow them.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The archive. Append-only in spirit: rows are inserted when an interval opens
/// and updated in place while it stays open. The sampler is the only writer,
/// which is why no busy-timeout or retry logic is needed. Spec §4, §6.
public final class Store {
    private var db: OpaquePointer?

    public init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.open(msg)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA busy_timeout=3000;")
    }

    deinit { if let db { sqlite3_close(db) } }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(msg)
        }
    }

    public func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS interval (
          id           INTEGER PRIMARY KEY,
          kind         TEXT    NOT NULL,
          started_at   INTEGER NOT NULL,
          ended_at     INTEGER NOT NULL,
          bundle_id    TEXT,
          app_name     TEXT,
          context_kind TEXT,
          context      TEXT,
          title        TEXT,
          samples      INTEGER NOT NULL,
          active       INTEGER NOT NULL,
          engaged      INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS ix_interval_time ON interval(started_at);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1');
        """)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.sql(msg)
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, i) }
    }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    public func insert(_ iv: Interval) throws -> Int64 {
        let stmt = try prepare("""
        INSERT INTO interval
          (kind, started_at, ended_at, bundle_id, app_name, context_kind, context, title,
           samples, active, engaged)
        VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11);
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, iv.kind.rawValue)
        sqlite3_bind_int64(stmt, 2, Int64(iv.startedAt))
        sqlite3_bind_int64(stmt, 3, Int64(iv.endedAt))
        bind(stmt, 4, iv.bundleId)
        bind(stmt, 5, iv.appName)
        bind(stmt, 6, iv.contextKind?.rawValue)
        bind(stmt, 7, iv.context)
        bind(stmt, 8, iv.title)
        sqlite3_bind_int64(stmt, 9, Int64(iv.samples))
        sqlite3_bind_int64(stmt, 10, Int64(iv.active))
        sqlite3_bind_int64(stmt, 11, Int64(iv.engaged))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    public func update(_ iv: Interval) throws {
        guard let id = iv.id else { throw StoreError.missingId }
        let stmt = try prepare("""
        UPDATE interval SET ended_at=?1, title=?2, samples=?3, active=?4, engaged=?5
        WHERE id=?6;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(iv.endedAt))
        bind(stmt, 2, iv.title)
        sqlite3_bind_int64(stmt, 3, Int64(iv.samples))
        sqlite3_bind_int64(stmt, 4, Int64(iv.active))
        sqlite3_bind_int64(stmt, 5, Int64(iv.engaged))
        sqlite3_bind_int64(stmt, 6, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func row(_ stmt: OpaquePointer?) -> Interval {
        Interval(
            id: sqlite3_column_int64(stmt, 0),
            kind: Kind(rawValue: text(stmt, 1) ?? "gap") ?? .gap,
            startedAt: Int(sqlite3_column_int64(stmt, 2)),
            endedAt: Int(sqlite3_column_int64(stmt, 3)),
            bundleId: text(stmt, 4),
            appName: text(stmt, 5),
            contextKind: text(stmt, 6).flatMap(ContextKind.init(rawValue:)),
            context: text(stmt, 7),
            title: text(stmt, 8),
            samples: Int(sqlite3_column_int64(stmt, 9)),
            active: Int(sqlite3_column_int64(stmt, 10)),
            engaged: Int(sqlite3_column_int64(stmt, 11))
        )
    }

    private static let selectColumns =
        "id, kind, started_at, ended_at, bundle_id, app_name, context_kind, context, title, samples, active, engaged"

    /// Most recently started interval — the one the sampler may still be extending.
    public func lastInterval() throws -> Interval? {
        let stmt = try prepare("SELECT \(Store.selectColumns) FROM interval ORDER BY started_at DESC, id DESC LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? row(stmt) : nil
    }

    /// All intervals overlapping [from, to).
    public func intervals(from: Int, to: Int) throws -> [Interval] {
        let stmt = try prepare("""
        SELECT \(Store.selectColumns) FROM interval
        WHERE ended_at > ?1 AND started_at < ?2
        ORDER BY started_at ASC, id ASC;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(from))
        sqlite3_bind_int64(stmt, 2, Int64(to))
        var out: [Interval] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all Task 6 assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/StalkerCore/Store.swift Sources/stalker-tests/main.swift
git commit -m "feat: SQLite interval store with WAL and nullable round-trips"
```

---

### Task 7: Reconciler and gap detection

**Files:**
- Create: `Sources/StalkerCore/Reconciler.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `Sample`, `Interval`, `IntervalKey` (Task 2), `Store` (Task 6).
- Produces:
  - `enum Transition: Equatable, Sendable` with cases `openFirst`, `bump`, `closeAndOpen`, `gapThenOpen(from: Int, to: Int)`
  - `func decide(open: Interval?, sample: Sample, samplePeriod: Int) -> Transition`
  - `func makeInterval(from s: Sample) -> Interval`
  - `final class Reconciler` with `init(store: Store, samplePeriod: Int)`, `loadOpen() throws`, `ingest(_ s: Sample) throws`, and read-only `open: Interval?`

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 7: reconciler and gap detection ---
    func mkSample(at: Int, bundle: String?, ctx: String?, kind: Kind = .app,
                  input: Bool = true, eng: Bool = false) -> Sample {
        Sample(at: at, kind: kind, bundleId: bundle, appName: bundle,
               contextKind: ctx == nil ? nil : .url, context: ctx, title: nil,
               hadInput: input, engaged: eng)
    }

    let openIv = makeInterval(from: mkSample(at: 1000, bundle: "com.google.Chrome", ctx: "a.com/x"))
    t.eq(decide(open: nil, sample: mkSample(at: 1000, bundle: "x", ctx: nil), samplePeriod: 30),
         Transition.openFirst, "no open interval opens the first one")
    t.eq(decide(open: openIv, sample: mkSample(at: 1030, bundle: "com.google.Chrome", ctx: "a.com/x"),
                samplePeriod: 30),
         Transition.bump, "same key bumps")
    t.eq(decide(open: openIv, sample: mkSample(at: 1030, bundle: "com.apple.Notes", ctx: nil),
                samplePeriod: 30),
         Transition.closeAndOpen, "different app closes and opens")
    t.eq(decide(open: openIv, sample: mkSample(at: 1030, bundle: "com.google.Chrome", ctx: "b.com/y"),
                samplePeriod: 30),
         Transition.closeAndOpen, "same app, different context closes and opens")

    // The spec's motivating case: lid closed at 18:00, opened at 09:00 must NOT
    // become one fifteen-hour interval of whatever was last in focus. Spec §6.4.
    t.eq(decide(open: openIv, sample: mkSample(at: 1000 + 54000, bundle: "com.google.Chrome",
                                               ctx: "a.com/x"), samplePeriod: 30),
         Transition.gapThenOpen(from: 1000, to: 55000), "a long jump produces a gap, not a giant interval")

    // Boundary: exactly 2x the period is still contiguous; one second more is a gap.
    t.eq(decide(open: openIv, sample: mkSample(at: 1060, bundle: "com.google.Chrome", ctx: "a.com/x"),
                samplePeriod: 30),
         Transition.bump, "exactly 2x period still bumps")
    t.eq(decide(open: openIv, sample: mkSample(at: 1061, bundle: "com.google.Chrome", ctx: "a.com/x"),
                samplePeriod: 30),
         Transition.gapThenOpen(from: 1000, to: 1061), "one second past 2x period is a gap")

    // End-to-end through the store.
    do {
        let store = try Store(path: ":memory:")
        try store.migrate()
        let r = Reconciler(store: store, samplePeriod: 30)

        try r.ingest(mkSample(at: 1000, bundle: "com.google.Chrome", ctx: "a.com/x", input: true))
        try r.ingest(mkSample(at: 1030, bundle: "com.google.Chrome", ctx: "a.com/x", input: true))
        try r.ingest(mkSample(at: 1060, bundle: "com.google.Chrome", ctx: "a.com/x",
                              input: false, eng: true))
        t.eq(r.open?.samples, 3, "three ticks accumulate into one interval")
        t.eq(r.open?.active, 2, "active counts only ticks with input")
        t.eq(r.open?.engaged, 1, "engaged counts only ticks with media playing")
        t.eq(r.open?.endedAt, 1060, "ended_at follows the latest tick")

        try r.ingest(mkSample(at: 1090, bundle: "com.mitchellh.ghostty", ctx: "/Users/alex/Work/x"))
        t.eq(r.open?.bundleId, "com.mitchellh.ghostty", "app change opens a new interval")
        t.eq(r.open?.samples, 1, "new interval starts its counters at one")

        let all = try store.intervals(from: 0, to: 99999)
        t.eq(all.count, 2, "two intervals persisted, not five rows")

        // Gap row is written, and the pre-gap interval is not stretched.
        try r.ingest(mkSample(at: 1090 + 54000, bundle: "com.mitchellh.ghostty", ctx: "/Users/alex/Work/x"))
        let withGap = try store.intervals(from: 0, to: 999999)
        t.expect(withGap.contains { $0.kind == .gap }, "a gap row is written")
        if let g = withGap.first(where: { $0.kind == .gap }) {
            t.eq(g.startedAt, 1090, "gap starts where the previous interval ended")
            t.eq(g.endedAt, 55090, "gap ends at the returning tick")
        }
        if let ghostty = withGap.first(where: { $0.bundleId == "com.mitchellh.ghostty" }) {
            t.eq(ghostty.endedAt, 1090, "pre-gap interval was not stretched across the gap")
        }
    } catch {
        t.expect(false, "reconciler store tests ran without throwing", "\(error)")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'decide' in scope`, `cannot find 'Reconciler' in scope`, `cannot find 'makeInterval' in scope`.

- [ ] **Step 3: Write `Reconciler.swift`**

```swift
public enum Transition: Equatable, Sendable {
    case openFirst
    case bump
    case closeAndOpen
    case gapThenOpen(from: Int, to: Int)
}

/// Pure transition decision, so every edge case is unit-testable without a database.
///
/// The gap check comes before the key check on purpose. After a fifteen-hour
/// sleep the key is usually unchanged — the same app is still frontmost — so a
/// key-first ordering would silently bump one interval across the whole night.
/// Spec §6.4.
public func decide(open: Interval?, sample: Sample, samplePeriod: Int) -> Transition {
    guard let open else { return .openFirst }
    if sample.at - open.endedAt > 2 * samplePeriod {
        return .gapThenOpen(from: open.endedAt, to: sample.at)
    }
    return open.key == sample.key ? .bump : .closeAndOpen
}

/// A fresh interval covering exactly one sample.
public func makeInterval(from s: Sample) -> Interval {
    Interval(id: nil, kind: s.kind, startedAt: s.at, endedAt: s.at,
             bundleId: s.bundleId, appName: s.appName,
             contextKind: s.contextKind, context: s.context, title: s.title,
             samples: 1, active: s.hadInput ? 1 : 0, engaged: s.engaged ? 1 : 0)
}

/// Applies transitions to the store.
///
/// Rows are INSERTed when an interval opens and UPDATEd on every tick, so a
/// killed sampler loses at most one tick rather than the whole open interval.
/// Spec §6.3.
public final class Reconciler {
    private let store: Store
    private let samplePeriod: Int
    public private(set) var open: Interval?

    public init(store: Store, samplePeriod: Int) {
        self.store = store
        self.samplePeriod = samplePeriod
    }

    /// Adopt the most recent row as the open interval, so a restarted sampler
    /// continues an interval instead of fragmenting it.
    public func loadOpen() throws {
        open = try store.lastInterval()
    }

    public func ingest(_ s: Sample) throws {
        switch decide(open: open, sample: s, samplePeriod: samplePeriod) {
        case .openFirst:
            try insertNew(s)

        case .bump:
            guard var iv = open else { try insertNew(s); return }
            iv.endedAt = s.at
            iv.samples += 1
            if s.hadInput { iv.active += 1 }
            if s.engaged { iv.engaged += 1 }
            if let title = s.title { iv.title = title }
            try store.update(iv)
            open = iv

        case .closeAndOpen:
            if var iv = open {
                iv.endedAt = max(iv.endedAt, iv.startedAt)
                try store.update(iv)
            }
            try insertNew(s)

        case .gapThenOpen(let from, let to):
            var gap = Interval(id: nil, kind: .gap, startedAt: from, endedAt: to,
                               bundleId: nil, appName: nil, contextKind: nil,
                               context: nil, title: nil, samples: 0, active: 0, engaged: 0)
            gap.id = try store.insert(gap)
            try insertNew(s)
        }
    }

    private func insertNew(_ s: Sample) throws {
        var iv = makeInterval(from: s)
        iv.id = try store.insert(iv)
        open = iv
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all Task 7 assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/StalkerCore/Reconciler.swift Sources/stalker-tests/main.swift
git commit -m "feat: interval reconciler with gap detection"
```

---

### Task 8: Courier reader

**Files:**
- Create: `Sources/StalkerCore/Courier.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `struct CourierReading: Equatable, Sendable` with `at: Int, cwd: String`
  - `func parseCourierLine(_ line: String) -> CourierReading?`
  - `func newestReading(_ readings: [CourierReading], now: Int, maxAgeSecs: Int) -> CourierReading?`
  - `func readCourierDir(_ dir: String, now: Int, maxAgeSecs: Int) -> CourierReading?`
  - `let courierMaxAgeSecs = 86_400`

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 8: courier reader ---
    t.eq(parseCourierLine("1790704439 /Users/alex/Desktop/Casey/Work/PM_Assistant"),
         CourierReading(at: 1790704439, cwd: "/Users/alex/Desktop/Casey/Work/PM_Assistant"),
         "parses a normal courier line")

    // Review Focus 1: splitting on every space would truncate the cwd to its
    // first word, and the directory rule would then never match.
    t.eq(parseCourierLine("1790704439 /Users/alex/Library/Application Support/thing"),
         CourierReading(at: 1790704439, cwd: "/Users/alex/Library/Application Support/thing"),
         "a path containing spaces survives intact")
    t.eq(parseCourierLine("1790704439 /a/b c d/e")?.cwd, "/a/b c d/e",
         "splits on the first space only")

    t.eq(parseCourierLine("1790704439 /x\n")?.cwd, "/x", "trailing newline is trimmed")
    t.eq(parseCourierLine("nodigits /x"), nil, "non-numeric timestamp returns nil")
    t.eq(parseCourierLine("1790704439"), nil, "line with no path returns nil")
    t.eq(parseCourierLine(""), nil, "empty line returns nil")
    t.eq(parseCourierLine("1790704439 "), nil, "blank path returns nil")

    let readings = [
        CourierReading(at: 1000 - 400, cwd: "/Users/alex/Desktop/Casey/Work/PM_Assistant"),
        CourierReading(at: 1000 - 12,  cwd: "/Users/alex/Desktop/Casey/Projects/stalker"),
        CourierReading(at: 1000 - 90,  cwd: "/Users/alex/Desktop/Casey/Work/Analytics"),
    ]
    t.eq(newestReading(readings, now: 1000, maxAgeSecs: 86_400)?.cwd,
         "/Users/alex/Desktop/Casey/Projects/stalker",
         "newest reading wins — this is the focused-shell attribution rule")
    t.eq(newestReading(readings, now: 1_000_000, maxAgeSecs: 86_400), nil,
         "readings older than the max age are ignored")
    t.eq(newestReading([], now: 1000, maxAgeSecs: 86_400), nil, "empty input returns nil")

    // Directory read against real files.
    do {
        let dir = NSTemporaryDirectory() + "stalker-courier-test-\(Int(Date().timeIntervalSince1970))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "900 /Users/alex/Work/old".write(toFile: dir + "/ttys000", atomically: true, encoding: .utf8)
        try "988 /Users/alex/Projects/new".write(toFile: dir + "/ttys001", atomically: true, encoding: .utf8)
        try "garbage".write(toFile: dir + "/ttys002", atomically: true, encoding: .utf8)
        t.eq(readCourierDir(dir, now: 1000, maxAgeSecs: 86_400)?.cwd, "/Users/alex/Projects/new",
             "directory read picks the newest valid file and skips garbage")
        try FileManager.default.removeItem(atPath: dir)
        t.eq(readCourierDir(dir, now: 1000, maxAgeSecs: 86_400), nil,
             "missing directory returns nil rather than throwing")
    } catch {
        t.expect(false, "courier directory test ran without throwing", "\(error)")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'parseCourierLine' in scope`.

- [ ] **Step 3: Write `Courier.swift`**

```swift
import Foundation

/// Stale courier files from closed terminals are ignored past this age. Spec §5.3.
public let courierMaxAgeSecs = 86_400

public struct CourierReading: Equatable, Sendable {
    public let at: Int
    public let cwd: String
    public init(at: Int, cwd: String) { self.at = at; self.cwd = cwd }
}

/// Parse one courier file: `<unix-seconds> <absolute-path>`.
///
/// Split on the FIRST space only. Paths legitimately contain spaces
/// (`Application Support`, most user folders), and splitting on every space
/// would truncate the cwd to its first word — after which the directory rule
/// silently never matches.
public func parseCourierLine(_ line: String) -> CourierReading? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let space = trimmed.firstIndex(of: " ") else { return nil }
    guard let at = Int(trimmed[trimmed.startIndex..<space]) else { return nil }
    let cwd = String(trimmed[trimmed.index(after: space)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cwd.isEmpty else { return nil }
    return CourierReading(at: at, cwd: cwd)
}

/// The focused shell is the one that most recently ran a command or changed
/// directory. macOS exposes no way to ask which terminal tab has focus, and
/// Ghostty exposes no tty or working directory through scripting, so this
/// timestamp comparison is the attribution rule. Spec §5.3.
public func newestReading(_ readings: [CourierReading], now: Int, maxAgeSecs: Int) -> CourierReading? {
    readings
        .filter { now - $0.at <= maxAgeSecs }
        .max { $0.at < $1.at }
}

/// Read every courier file in `dir`. Unreadable or malformed files are skipped
/// rather than failing the tick — a broken file must not stop collection.
public func readCourierDir(_ dir: String, now: Int, maxAgeSecs: Int) -> CourierReading? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
    var readings: [CourierReading] = []
    for name in names {
        guard let text = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8),
              let r = parseCourierLine(text) else { continue }
        readings.append(r)
    }
    return newestReading(readings, now: now, maxAgeSecs: maxAgeSecs)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all Task 8 assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/StalkerCore/Courier.swift Sources/stalker-tests/main.swift
git commit -m "feat: courier reader with first-space-only parsing"
```

---

### Task 9: Report bucketing and rendering

**Files:**
- Create: `Sources/StalkerCore/Report.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `Interval` (Task 2), `RuleSet` / `classify` (Tasks 4–5).
- Produces:
  - `func bucketStart(_ ts: Int, bucketSecs: Int) -> Int`
  - `func overlapSeconds(_ iv: Interval, bucketStart: Int, bucketEnd: Int) -> Int`
  - `struct Slice: Equatable, Sendable` with `bucketStart: Int, category: String, kind: Kind, appName: String?, context: String?, seconds: Int`
  - `func slice(_ ivs: [Interval], bucketSecs: Int, rules: RuleSet) -> [Slice]`
  - `struct CategoryTotal: Equatable, Sendable` with `category: String, seconds: Int, byContext: [ContextTotal]`
  - `struct ContextTotal: Equatable, Sendable` with `label: String, seconds: Int`
  - `func totals(_ slices: [Slice]) -> [CategoryTotal]`
  - `func render(_ ivs: [Interval], bucketSecs: Int, rules: RuleSet, timeZone: TimeZone) -> String`
  - `let bucketSeconds = 1800`

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 9: report ---
    t.eq(bucketStart(1800, bucketSecs: 1800), 1800, "exact boundary is its own bucket")
    t.eq(bucketStart(1900, bucketSecs: 1800), 1800, "mid-bucket rounds down")
    t.eq(bucketStart(3599, bucketSecs: 1800), 1800, "last second of a bucket rounds down")

    func iv(_ start: Int, _ end: Int, bundle: String?, ctx: String?, kind: Kind = .app) -> Interval {
        Interval(id: nil, kind: kind, startedAt: start, endedAt: end,
                 bundleId: bundle, appName: bundle, contextKind: ctx == nil ? nil : .url,
                 context: ctx, title: nil, samples: 1, active: 1, engaged: 0)
    }

    t.eq(overlapSeconds(iv(0, 600, bundle: "x", ctx: nil), bucketStart: 0, bucketEnd: 1800), 600,
         "interval fully inside a bucket contributes its whole duration")
    t.eq(overlapSeconds(iv(1500, 2100, bundle: "x", ctx: nil), bucketStart: 0, bucketEnd: 1800), 300,
         "interval spanning a boundary contributes only its overlap")
    t.eq(overlapSeconds(iv(1500, 2100, bundle: "x", ctx: nil), bucketStart: 1800, bucketEnd: 3600), 300,
         "the remainder lands in the next bucket")
    t.eq(overlapSeconds(iv(5000, 6000, bundle: "x", ctx: nil), bucketStart: 0, bucketEnd: 1800), 0,
         "non-overlapping interval contributes nothing")

    // Review Focus 4: a clock correction can leave ended_at before started_at.
    // A negative duration would corrupt every total it lands in.
    t.eq(overlapSeconds(iv(1000, 400, bundle: "x", ctx: nil), bucketStart: 0, bucketEnd: 1800), 0,
         "reversed clock yields zero seconds, never a negative duration")

    let rulesToml = """
    default = "unclear"

    [[rule]]
    app = "com.google.Chrome"
    category = "work"

    [[rule]]
    app = "com.microsoft.edgemac"
    category = "fun"
    """
    let reportRules = try! parseRules(rulesToml, homeDirectory: "/Users/alex")

    let spanning = [iv(1500, 2100, bundle: "com.google.Chrome", ctx: "docs.google.com/d")]
    let slices = slice(spanning, bucketSecs: 1800, rules: reportRules)
    t.eq(slices.count, 2, "an interval spanning a boundary produces two slices")
    t.eq(slices.reduce(0) { $0 + $1.seconds }, 600, "slices preserve the total duration")
    t.expect(slices.allSatisfy { $0.category == "work" }, "both slices carry the same category")

    let mixed = [
        iv(0, 900, bundle: "com.google.Chrome", ctx: "docs.google.com/d"),
        iv(900, 1800, bundle: "com.microsoft.edgemac", ctx: "youtube.com/watch"),
        iv(1800, 2400, bundle: "com.tinyspeck.slackmacgap", ctx: nil),
    ]
    let tot = totals(slice(mixed, bucketSecs: 1800, rules: reportRules))
    t.eq(tot.first { $0.category == "work" }?.seconds, 900, "work total")
    t.eq(tot.first { $0.category == "fun" }?.seconds, 900, "fun total")
    t.eq(tot.first { $0.category == "unclear" }?.seconds, 600, "unmatched time totals under unclear")
    t.expect(tot.first!.seconds >= tot.last!.seconds, "totals are sorted by seconds descending")

    // The per-category context breakdown is what makes habit drift visible:
    // youtube time sitting inside `work` should be listed, not hidden in a total.
    let drift = [
        iv(0, 600, bundle: "com.google.Chrome", ctx: "docs.google.com/d"),
        iv(600, 900, bundle: "com.google.Chrome", ctx: "youtube.com/watch"),
    ]
    let driftTotals = totals(slice(drift, bucketSecs: 1800, rules: reportRules))
    t.eq(driftTotals.count, 1, "both intervals classify as work")
    t.eq(driftTotals.first?.byContext.count, 2, "work breaks down into two contexts")
    t.eq(driftTotals.first?.byContext.first?.seconds, 600,
         "context breakdown is sorted by seconds descending")

    let text = render(mixed, bucketSecs: 1800, rules: reportRules, timeZone: TimeZone(identifier: "UTC")!)
    t.expect(text.contains("work"), "rendered report names categories")
    t.expect(text.contains("TOTALS"), "rendered report has a totals section")
    t.expect(text.contains("unclear"), "rendered report surfaces unclear time")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'bucketStart' in scope`.

- [ ] **Step 3: Write `Report.swift`**

```swift
import Foundation

public let bucketSeconds = 1800

/// Absolute-time bucket alignment. For every time zone whose offset is a whole
/// multiple of 30 minutes this lands on local :00 and :30. Zones offset by 45
/// minutes (for example Asia/Kathmandu) will show :15 and :45 labels — odd to
/// read, but not wrong.
public func bucketStart(_ ts: Int, bucketSecs: Int) -> Int {
    ts - (ts % bucketSecs)
}

/// Seconds of `iv` that fall inside [bucketStart, bucketEnd).
///
/// `endedAt` is clamped to be at least `startedAt` first: a clock correction can
/// leave a row with `ended_at < started_at`, and a negative duration would
/// corrupt every total it is summed into.
public func overlapSeconds(_ iv: Interval, bucketStart: Int, bucketEnd: Int) -> Int {
    let ivEnd = max(iv.endedAt, iv.startedAt)
    let s = max(iv.startedAt, bucketStart)
    let e = min(ivEnd, bucketEnd)
    return max(0, e - s)
}

public struct Slice: Equatable, Sendable {
    public let bucketStart: Int
    public let category: String
    public let kind: Kind
    public let appName: String?
    public let context: String?
    public let seconds: Int
}

/// Cut intervals at bucket boundaries, classifying each as it goes.
public func slice(_ ivs: [Interval], bucketSecs: Int, rules: RuleSet) -> [Slice] {
    var out: [Slice] = []
    for iv in ivs {
        let ivEnd = max(iv.endedAt, iv.startedAt)
        guard ivEnd > iv.startedAt else { continue }
        let category = iv.kind == .app ? classify(iv, with: rules) : iv.kind.rawValue
        var b = bucketStart(iv.startedAt, bucketSecs: bucketSecs)
        while b < ivEnd {
            let secs = overlapSeconds(iv, bucketStart: b, bucketEnd: b + bucketSecs)
            if secs > 0 {
                out.append(Slice(bucketStart: b, category: category, kind: iv.kind,
                                 appName: iv.appName, context: iv.context, seconds: secs))
            }
            b += bucketSecs
        }
    }
    return out
}

public struct ContextTotal: Equatable, Sendable {
    public let label: String
    public let seconds: Int
}

public struct CategoryTotal: Equatable, Sendable {
    public let category: String
    public let seconds: Int
    public let byContext: [ContextTotal]
}

/// Totals per category, each broken down by context.
///
/// The breakdown is deliberate: a rule like `Chrome = work` is a habit, not a
/// fact, so youtube time sitting inside `work` must be visible rather than
/// folded into a flattering total. Spec §8.
public func totals(_ slices: [Slice]) -> [CategoryTotal] {
    var byCategory: [String: Int] = [:]
    var byCategoryContext: [String: [String: Int]] = [:]

    for s in slices {
        byCategory[s.category, default: 0] += s.seconds
        let label = s.context ?? s.appName ?? "(unknown)"
        byCategoryContext[s.category, default: [:]][label, default: 0] += s.seconds
    }

    return byCategory
        .map { cat, secs in
            let contexts = (byCategoryContext[cat] ?? [:])
                .map { ContextTotal(label: $0.key, seconds: $0.value) }
                .sorted { ($0.seconds, $1.label) > ($1.seconds, $0.label) }
            return CategoryTotal(category: cat, seconds: secs, byContext: contexts)
        }
        .sorted { ($0.seconds, $1.category) > ($1.seconds, $0.category) }
}

private func hhmm(_ ts: Int, _ tz: TimeZone) -> String {
    let f = DateFormatter()
    f.timeZone = tz
    f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
}

private func dur(_ secs: Int) -> String {
    let h = secs / 3600, m = (secs % 3600) / 60
    return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
}

public func render(_ ivs: [Interval], bucketSecs: Int, rules: RuleSet, timeZone: TimeZone) -> String {
    let all = slice(ivs, bucketSecs: bucketSecs, rules: rules)
    var lines: [String] = []

    // Per bucket, the category that took the most time, with its top context.
    let buckets = Set(all.map(\.bucketStart)).sorted()
    for b in buckets {
        let here = all.filter { $0.bucketStart == b }
        guard let top = here.max(by: { $0.seconds < $1.seconds }) else { continue }
        let label = top.context ?? top.appName ?? "—"
        lines.append("\(hhmm(b, timeZone)) ─ \(hhmm(b + bucketSecs, timeZone))   "
                     + top.category.padding(toLength: 12, withPad: " ", startingAt: 0)
                     + "\(top.appName ?? "—")  \(label)")
    }

    lines.append("")
    lines.append("TOTALS")
    for ct in totals(all) {
        lines.append("  " + ct.category.padding(toLength: 14, withPad: " ", startingAt: 0) + dur(ct.seconds))
        for c in ct.byContext.prefix(6) {
            lines.append("    " + c.label.padding(toLength: 44, withPad: " ", startingAt: 0) + dur(c.seconds))
        }
    }
    return lines.joined(separator: "\n")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all Task 9 assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/StalkerCore/Report.swift Sources/stalker-tests/main.swift
git commit -m "feat: 30-minute bucketing, totals, and report rendering"
```

---

### Task 10: Probe protocols and the tick

**Files:**
- Create: `Sources/StalkerCore/Probes.swift`
- Create: `Sources/StalkerCore/Tick.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `Sample`, `Kind`, `ContextKind` (Task 2), `CourierReading` (Task 8).
- Produces:
  - `struct FocusInfo: Equatable, Sendable` with `bundleId: String?, appName: String?, pid: Int32`
  - `enum ContextResult: Equatable, Sendable` with cases `none`, `denied`, `value(ContextKind, String, title: String?)`
  - `protocol FocusProbe { func frontmost() -> FocusInfo? }`
  - `protocol IdleProbe { func inputIdleSeconds() -> Double }`
  - `protocol LockProbe { func isScreenLocked() -> Bool }`
  - `protocol EngagementProbe { func isEngaged(pid: Int32) -> Bool }`
  - `protocol ContextProbe { func context(for focus: FocusInfo) -> ContextResult }`
  - `protocol CourierProbe { func newest(now: Int) -> CourierReading? }`
  - `struct TickConfig: Sendable` with `samplePeriod: Int, idleThreshold: Int, terminalBundleIds: Set<String>`, plus `static let `default``
  - `struct Probes: Sendable` bundling the six probes
  - `func makeSample(now: Int, previous: Sample?, config: TickConfig, probes: Probes) -> Sample`

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 10: the tick ---
    struct FakeFocus: FocusProbe {
        let info: FocusInfo?
        func frontmost() -> FocusInfo? { info }
    }
    struct FakeIdle: IdleProbe {
        let secs: Double
        func inputIdleSeconds() -> Double { secs }
    }
    struct FakeLock: LockProbe {
        let locked: Bool
        func isScreenLocked() -> Bool { locked }
    }
    struct FakeEngagement: EngagementProbe {
        let engaged: Bool
        func isEngaged(pid: Int32) -> Bool { engaged }
    }
    struct FakeContext: ContextProbe {
        let result: ContextResult
        func context(for focus: FocusInfo) -> ContextResult { result }
    }
    struct FakeCourier: CourierProbe {
        let reading: CourierReading?
        func newest(now: Int) -> CourierReading? { reading }
    }

    let cfg = TickConfig(samplePeriod: 30, idleThreshold: 180,
                         terminalBundleIds: ["com.mitchellh.ghostty"])
    let chrome = FocusInfo(bundleId: "com.google.Chrome", appName: "Google Chrome", pid: 21090)
    let edge = FocusInfo(bundleId: "com.microsoft.edgemac", appName: "Microsoft Edge", pid: 1958)
    let ghostty = FocusInfo(bundleId: "com.mitchellh.ghostty", appName: "Ghostty", pid: 3065)

    func probes(_ f: FocusInfo?, idle: Double, locked: Bool = false, engaged: Bool = false,
                ctx: ContextResult = .none, courier: CourierReading? = nil) -> Probes {
        Probes(focus: FakeFocus(info: f), idle: FakeIdle(secs: idle), lock: FakeLock(locked: locked),
               engagement: FakeEngagement(engaged: engaged), context: FakeContext(result: ctx),
               courier: FakeCourier(reading: courier))
    }

    // Locked screen beats everything else.
    t.eq(makeSample(now: 1000, previous: nil, config: cfg,
                    probes: probes(chrome, idle: 5, locked: true)).kind,
         Kind.locked, "locked screen yields kind locked")

    // No frontmost app at all (login window) is missing data, not activity.
    t.eq(makeSample(now: 1000, previous: nil, config: cfg, probes: probes(nil, idle: 5)).kind,
         Kind.gap, "no frontmost app yields kind gap")

    // Normal typing.
    let typing = makeSample(now: 1000, previous: nil, config: cfg,
                            probes: probes(chrome, idle: 5,
                                           ctx: .value(.url, "docs.google.com/d/1/edit", title: "Doc")))
    t.eq(typing.kind, Kind.app, "active use yields kind app")
    t.eq(typing.hadInput, true, "input within the sample period counts as input")
    t.eq(typing.engaged, false, "engagement is not checked while actively typing")
    t.eq(typing.context, "docs.google.com/d/1/edit", "context is captured while active")
    t.eq(typing.contextKind, ContextKind.url, "context kind is url for a browser")

    // Idle with nothing playing.
    let away = makeSample(now: 1000, previous: nil, config: cfg,
                          probes: probes(chrome, idle: 300, engaged: false,
                                         ctx: .value(.url, "docs.google.com/d/1/edit", title: nil)))
    t.eq(away.kind, Kind.idle, "no input past the threshold and nothing playing yields idle")
    t.eq(away.hadInput, false, "no input in this period")

    // The YouTube case: no input for minutes, but a video is playing.
    let watching = makeSample(now: 1000, previous: nil, config: cfg,
                              probes: probes(edge, idle: 600, engaged: true,
                                             ctx: .value(.url, "www.youtube.com/watch", title: nil)))
    t.eq(watching.kind, Kind.app, "media playing keeps a no-input tick out of idle")
    t.eq(watching.engaged, true, "engagement is recorded")
    t.eq(watching.hadInput, false, "watching is not input")

    // A terminal takes its context from the courier, not the context probe.
    let term = makeSample(now: 1000, previous: nil, config: cfg,
                          probes: probes(ghostty, idle: 5, ctx: .value(.title, "ignored", title: nil),
                                         courier: CourierReading(at: 995, cwd: "/Users/alex/Work/x")))
    t.eq(term.contextKind, ContextKind.cwd, "terminal context kind is cwd")
    t.eq(term.context, "/Users/alex/Work/x", "terminal context comes from the courier")

    // A terminal with no courier file falls back to the context probe.
    let termNoCourier = makeSample(now: 1000, previous: nil, config: cfg,
                                   probes: probes(ghostty, idle: 5,
                                                  ctx: .value(.title, "Claude Code", title: nil)))
    t.eq(termNoCourier.contextKind, ContextKind.title,
         "terminal with no courier reading falls back to the window title")

    // Revoked permission must be distinguishable from "no context to read".
    t.eq(makeSample(now: 1000, previous: nil, config: cfg,
                    probes: probes(chrome, idle: 5, ctx: .denied)).contextKind,
         ContextKind.denied, "denied permission is recorded as denied, not nil")
    t.eq(makeSample(now: 1000, previous: nil, config: cfg,
                    probes: probes(chrome, idle: 5, ctx: .none)).contextKind,
         nil, "an app with no context yields nil context kind")

    // Continuing idle must NOT re-query, and must carry context forward.
    // If it returned nil context the IntervalKey would change every tick and the
    // reconciler would open a new interval each time.
    let firstIdle = makeSample(now: 1000, previous: typing, config: cfg,
                               probes: probes(chrome, idle: 300,
                                              ctx: .value(.url, "docs.google.com/d/1/edit", title: nil)))
    let secondIdle = makeSample(now: 1030, previous: firstIdle, config: cfg,
                                probes: probes(chrome, idle: 330, ctx: .none))
    t.eq(secondIdle.context, "docs.google.com/d/1/edit",
         "continuing idle carries the captured context forward")
    t.eq(firstIdle.key, secondIdle.key, "consecutive idle ticks share one interval key")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find type 'FocusProbe' in scope`, `cannot find 'makeSample' in scope`.

- [ ] **Step 3: Write `Probes.swift`**

```swift
public struct FocusInfo: Equatable, Sendable {
    public let bundleId: String?
    public let appName: String?
    public let pid: Int32
    public init(bundleId: String?, appName: String?, pid: Int32) {
        self.bundleId = bundleId; self.appName = appName; self.pid = pid
    }
}

/// What a context lookup produced.
///
/// `denied` exists so a revoked Accessibility grant is distinguishable from an
/// app that simply has nothing to report. Spec §6.2, §9.
public enum ContextResult: Equatable, Sendable {
    case none
    case denied
    case value(ContextKind, String, title: String?)
}

public protocol FocusProbe: Sendable { func frontmost() -> FocusInfo? }
public protocol IdleProbe: Sendable { func inputIdleSeconds() -> Double }
public protocol LockProbe: Sendable { func isScreenLocked() -> Bool }
public protocol EngagementProbe: Sendable { func isEngaged(pid: Int32) -> Bool }
public protocol ContextProbe: Sendable { func context(for focus: FocusInfo) -> ContextResult }
public protocol CourierProbe: Sendable { func newest(now: Int) -> CourierReading? }

public struct Probes: Sendable {
    public let focus: any FocusProbe
    public let idle: any IdleProbe
    public let lock: any LockProbe
    public let engagement: any EngagementProbe
    public let context: any ContextProbe
    public let courier: any CourierProbe

    public init(focus: any FocusProbe, idle: any IdleProbe, lock: any LockProbe,
                engagement: any EngagementProbe, context: any ContextProbe,
                courier: any CourierProbe) {
        self.focus = focus; self.idle = idle; self.lock = lock
        self.engagement = engagement; self.context = context; self.courier = courier
    }
}

public struct TickConfig: Sendable {
    public let samplePeriod: Int
    public let idleThreshold: Int
    public let terminalBundleIds: Set<String>

    public init(samplePeriod: Int, idleThreshold: Int, terminalBundleIds: Set<String>) {
        self.samplePeriod = samplePeriod
        self.idleThreshold = idleThreshold
        self.terminalBundleIds = terminalBundleIds
    }

    /// Spec §5.1, §5.4.
    public static let `default` = TickConfig(
        samplePeriod: 30,
        idleThreshold: 180,
        terminalBundleIds: ["com.mitchellh.ghostty", "com.apple.Terminal", "net.kovidgoyal.kitty",
                            "com.googlecode.iterm2", "dev.warp.Warp-Stable", "co.zeit.hyper"]
    )
}
```

- [ ] **Step 4: Write `Tick.swift`**

```swift
/// Assemble one observation. Pure apart from the injected probes, so every
/// branch is testable without touching a real macOS API. Spec §5.2.
public func makeSample(now: Int, previous: Sample?, config: TickConfig, probes: Probes) -> Sample {
    // A locked screen means you left; nothing else about the machine matters.
    if probes.lock.isScreenLocked() {
        return Sample(at: now, kind: .locked, bundleId: nil, appName: nil,
                      contextKind: nil, context: nil, title: nil,
                      hadInput: false, engaged: false)
    }

    // No frontmost application (login window, fast user switch) is missing data,
    // not activity, so it is recorded as a gap rather than attributed to anything.
    guard let focus = probes.focus.frontmost() else {
        return Sample(at: now, kind: .gap, bundleId: nil, appName: nil,
                      contextKind: nil, context: nil, title: nil,
                      hadInput: false, engaged: false)
    }

    let inputIdleSecs = probes.idle.inputIdleSeconds()
    let hadInput = inputIdleSecs < Double(config.samplePeriod)

    // The engagement check is a tiebreaker, reached only once the no-input
    // threshold trips — so it costs nothing while you are typing. Spec §5.4.
    var engaged = false
    var kind = Kind.app
    if inputIdleSecs > Double(config.idleThreshold) {
        engaged = probes.engagement.isEngaged(pid: focus.pid)
        kind = engaged ? .app : .idle
    }

    // Capture context when active, and once on the transition into idle.
    // While idle continues, nothing can have changed — with no input, focus and
    // URL cannot move — so the previous context is carried forward rather than
    // re-queried. Carrying it forward also keeps IntervalKey stable; returning
    // nil would open a new interval on every idle tick. Spec §5.2.
    let enteringIdle = (kind == .idle) && (previous?.kind != .idle)
    let shouldCapture = (kind == .app) || enteringIdle

    var contextKind: ContextKind?
    var context: String?
    var title: String?

    if shouldCapture {
        // Terminals are served by the courier, not by Accessibility: macOS
        // exposes no way to ask which terminal tab has focus. Spec §5.3.
        if let bundle = focus.bundleId, config.terminalBundleIds.contains(bundle),
           let reading = probes.courier.newest(now: now) {
            contextKind = .cwd
            context = reading.cwd
        } else {
            switch probes.context.context(for: focus) {
            case .none:
                break
            case .denied:
                contextKind = .denied
            case .value(let k, let v, let ttl):
                contextKind = k
                context = v
                title = ttl
            }
        }
    } else {
        contextKind = previous?.contextKind
        context = previous?.context
        title = previous?.title
    }

    return Sample(at: now, kind: kind, bundleId: focus.bundleId, appName: focus.appName,
                  contextKind: contextKind, context: context, title: title,
                  hadInput: hadInput, engaged: engaged)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all Task 10 assertions `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/StalkerCore/Probes.swift Sources/StalkerCore/Tick.swift Sources/stalker-tests/main.swift
git commit -m "feat: probe protocols and engagement-aware tick assembly"
```

---

### Task 11: Focus, idle, and lock probes

**Files:**
- Create: `Sources/StalkerMac/SystemProbes.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `FocusProbe`, `IdleProbe`, `LockProbe`, `FocusInfo` (Task 10), `CourierProbe`, `CourierReading` (Tasks 8, 10).
- Produces: `struct SystemFocusProbe: FocusProbe`, `struct SystemIdleProbe: IdleProbe`, `struct SystemLockProbe: LockProbe`, `struct DirectoryCourierProbe: CourierProbe` with `init(dir: String, maxAgeSecs: Int = courierMaxAgeSecs)`.

- [ ] **Step 1: Write the failing tests**

Add `import StalkerMac` at the top of `main.swift` if not already present, then add to `run()`:

```swift
    // --- Task 11: system probes (smoke tests against the real machine) ---
    let sysFocus = SystemFocusProbe()
    if let f = sysFocus.frontmost() {
        t.expect(f.pid > 0, "focus probe returns a real pid (\(f.appName ?? "?") pid \(f.pid))")
        t.expect(!(f.appName ?? "").isEmpty, "focus probe returns an app name")
    } else {
        t.expect(false, "focus probe returns a frontmost app")
    }

    let sysIdle = SystemIdleProbe()
    t.expect(sysIdle.inputIdleSeconds() >= 0, "idle probe returns a non-negative value")

    let sysLock = SystemLockProbe()
    let locked = sysLock.isScreenLocked()
    t.eq(locked, false, "screen is not locked while the tests run")

    do {
        let dir = NSTemporaryDirectory() + "stalker-probe-test-\(Int(Date().timeIntervalSince1970))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let nowSecs = Int(Date().timeIntervalSince1970)
        try "\(nowSecs) /Users/alex/Desktop/Casey/Work/PM_Assistant"
            .write(toFile: dir + "/ttys000", atomically: true, encoding: .utf8)
        let cp = DirectoryCourierProbe(dir: dir)
        t.eq(cp.newest(now: nowSecs)?.cwd, "/Users/alex/Desktop/Casey/Work/PM_Assistant",
             "courier probe reads the newest file")
        try FileManager.default.removeItem(atPath: dir)
    } catch {
        t.expect(false, "courier probe test ran without throwing", "\(error)")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'SystemFocusProbe' in scope`.

- [ ] **Step 3: Write `SystemProbes.swift`**

```swift
import Cocoa
import Foundation
import StalkerCore

/// Frontmost application. Requires no permission — verified.
public struct SystemFocusProbe: FocusProbe {
    public init() {}
    public func frontmost() -> FocusInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FocusInfo(bundleId: app.bundleIdentifier,
                         appName: app.localizedName,
                         pid: app.processIdentifier)
    }
}

/// Seconds since the last input event of ANY kind.
///
/// `kCGAnyInputEventType` (`~0`) is the union of input types: key presses,
/// modifier changes, cursor movement, scroll, clicks, and drags. Verified —
/// the ANY reading tracked the minimum of the individual types on every sample,
/// and agreed with `ioreg` HIDIdleTime to within 0.2 s.
///
/// This is why moving the trackpad or scrolling counts as activity, and why a
/// 180 s threshold genuinely means hands off. Spec §5.4.
public struct SystemIdleProbe: IdleProbe {
    public init() {}
    public func inputIdleSeconds() -> Double {
        guard let anyType = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyType)
    }
}

/// Whether the screen is locked.
public struct SystemLockProbe: LockProbe {
    public init() {}
    public func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

/// Reads the courier directory the zsh hook writes into.
public struct DirectoryCourierProbe: CourierProbe {
    let dir: String
    let maxAgeSecs: Int
    public init(dir: String, maxAgeSecs: Int = courierMaxAgeSecs) {
        self.dir = dir; self.maxAgeSecs = maxAgeSecs
    }
    public func newest(now: Int) -> CourierReading? {
        readCourierDir(dir, now: now, maxAgeSecs: maxAgeSecs)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all Task 11 assertions `ok`, exit 0. The focus probe will name whichever app is frontmost.

- [ ] **Step 5: Commit**

```bash
git add Sources/StalkerMac/SystemProbes.swift Sources/stalker-tests/main.swift
git commit -m "feat: focus, idle, lock, and courier system probes"
```

---

### Task 12: Engagement probe

**Files:**
- Create: `Sources/StalkerCore/EngagementFilter.swift`
- Create: `Sources/StalkerMac/PowerAssertionProbe.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `EngagementProbe` (Task 10).
- Produces:
  - `struct AssertionRecord: Equatable, Sendable` with `type: String, name: String`
  - `func isEngaged(assertionsByPid: [Int32: [AssertionRecord]], pid: Int32) -> Bool` in `StalkerCore` — the pure decision
  - `struct PowerAssertionProbe: EngagementProbe` in `StalkerMac` — the IOKit call feeding it

The pure filter is separate from the IOKit call specifically so the pid-scoping rule can be tested with a fabricated assertion table.

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 12: engagement filter ---
    // Fixture drawn from a real probe run while a video played in Edge, including
    // the five permanent system assertions that were present at the same time.
    let assertionTable: [Int32: [AssertionRecord]] = [
        1958: [AssertionRecord(type: "NoIdleSleepAssertion", name: "Playing audio"),
               AssertionRecord(type: "NoDisplaySleepAssertion", name: "Video Wake Lock")],
        419:  [AssertionRecord(type: "UserIsActive", name: "com.apple.iohideventsystem.queue.tickle")],
        358:  [AssertionRecord(type: "PreventUserIdleSystemSleep", name: "Powerd - Prevent sleep while display is on"),
               AssertionRecord(type: "InternalPreventDisplaySleep", name: "com.apple.powermanagement.delayDisplayOff")],
        434:  [AssertionRecord(type: "PreventUserIdleSystemSleep", name: "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep")],
        40890: [AssertionRecord(type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool")],
    ]

    t.eq(isEngaged(assertionsByPid: assertionTable, pid: 1958), true,
         "Edge holding a Video Wake Lock counts as engaged")
    t.eq(isEngaged(assertionsByPid: [1958: [AssertionRecord(type: "NoIdleSleepAssertion", name: "Playing audio")]],
                   pid: 1958), true,
         "an audio-only assertion counts as engaged")
    t.eq(isEngaged(assertionsByPid: [1958: [AssertionRecord(type: "NoDisplaySleepAssertion", name: "Video Wake Lock")]],
                   pid: 1958), true,
         "a muted video's display assertion still counts as engaged")

    // The trap found while probing: five system processes hold assertions
    // permanently. An unscoped check would report engagement 24/7 and idle
    // detection would never fire at all.
    t.eq(isEngaged(assertionsByPid: assertionTable, pid: 21090), false,
         "system assertions held by powerd, coreaudiod, caffeinate must not count for another pid")
    t.eq(isEngaged(assertionsByPid: assertionTable, pid: 358), false,
         "powerd's own PreventUserIdleSystemSleep is the wrong type and does not count")
    t.eq(isEngaged(assertionsByPid: assertionTable, pid: 434), false,
         "coreaudiod's speaker assertion does not count")
    t.eq(isEngaged(assertionsByPid: assertionTable, pid: 40890), false,
         "a caffeinate hold does not count as you watching something")
    t.eq(isEngaged(assertionsByPid: assertionTable, pid: 419), false,
         "WindowServer's UserIsActive does not count")
    t.eq(isEngaged(assertionsByPid: [:], pid: 1958), false, "empty table is not engaged")

    // Live smoke test: nothing should be playing while the tests run, but the
    // call must succeed and return a Bool rather than crash.
    let livePid = SystemFocusProbe().frontmost()?.pid ?? 0
    let liveEngaged = PowerAssertionProbe().isEngaged(pid: livePid)
    t.expect(liveEngaged == true || liveEngaged == false,
             "power assertion probe runs against the live system (engaged=\(liveEngaged))")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'AssertionRecord' in scope`.

- [ ] **Step 3: Write `EngagementFilter.swift`**

```swift
public struct AssertionRecord: Equatable, Sendable {
    public let type: String
    public let name: String
    public init(type: String, name: String) { self.type = type; self.name = name }
}

/// Assertion types that mean "media is playing in this app".
private let displayAssertionTypes: Set<String> = [
    "NoDisplaySleepAssertion",           // taken by video players, mute or not
    "PreventUserIdleDisplaySleep",       // the older public name for the same intent
]

/// Is media playing in the given process?
///
/// Scoped to one pid on purpose. Probing found five assertions held permanently
/// by system processes — `powerd`, `coreaudiod`, `caffeinate`, and WindowServer's
/// `UserIsActive` — so a check of the form "does any display assertion exist"
/// would report engagement 24/7 and idle detection would never fire. Spec §5.4.
public func isEngaged(assertionsByPid: [Int32: [AssertionRecord]], pid: Int32) -> Bool {
    guard let held = assertionsByPid[pid] else { return false }
    for a in held {
        if displayAssertionTypes.contains(a.type) { return true }
        // Audio playback surfaces as an idle-sleep assertion whose name says so.
        // The type alone is too broad: caffeinate and powerd use the same type.
        if a.type == "NoIdleSleepAssertion" && a.name.lowercased().contains("playing audio") {
            return true
        }
    }
    return false
}
```

- [ ] **Step 4: Write `PowerAssertionProbe.swift`**

```swift
import Foundation
import IOKit.pwr_mgt
import StalkerCore

/// Reads per-process power assertions. Requires no permission — verified.
public struct PowerAssertionProbe: EngagementProbe {
    public init() {}

    public func isEngaged(pid: Int32) -> Bool {
        StalkerCore.isEngaged(assertionsByPid: snapshot(), pid: pid)
    }

    func snapshot() -> [Int32: [AssertionRecord]] {
        var out: [Int32: [AssertionRecord]] = [:]
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return out
        }
        for (pidNum, list) in dict {
            let pid = pidNum.int32Value
            var records: [AssertionRecord] = []
            for entry in list {
                let type = entry["AssertType"] as? String ?? ""
                let name = entry["AssertName"] as? String ?? ""
                guard !type.isEmpty else { continue }
                records.append(AssertionRecord(type: type, name: name))
            }
            if !records.isEmpty { out[pid] = records }
        }
        return out
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all Task 12 assertions `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/StalkerCore/EngagementFilter.swift Sources/StalkerMac/PowerAssertionProbe.swift Sources/stalker-tests/main.swift
git commit -m "feat: pid-scoped engagement detection via power assertions"
```

---

### Task 13: Accessibility context probe

**Files:**
- Create: `Sources/StalkerCore/ContextClassifier.swift`
- Create: `Sources/StalkerMac/AccessibilityContextProbe.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `ContextProbe`, `ContextResult`, `FocusInfo` (Task 10), `normalizeURL` (Task 3).
- Produces:
  - `func classifyContextValue(axURL: String?, axDocument: String?, axTitle: String?) -> ContextResult` in `StalkerCore`
  - `struct AccessibilityContextProbe: ContextProbe` in `StalkerMac`, with `init(messagingTimeout: Float = 1.0)`

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 13: context classification ---
    t.eq(classifyContextValue(axURL: "https://docs.google.com/document/d/1Wk/edit?tab=t.0",
                              axDocument: nil, axTitle: "Doc"),
         ContextResult.value(.url, "docs.google.com/document/d/1Wk/edit", title: "Doc"),
         "a URL wins and is normalised to host+path")
    t.eq(classifyContextValue(axURL: nil, axDocument: "file:///Users/alex/Desktop/paper.pdf",
                              axTitle: "paper.pdf"),
         ContextResult.value(.file, "/Users/alex/Desktop/paper.pdf", title: "paper.pdf"),
         "a document file URL becomes a plain path")
    t.eq(classifyContextValue(axURL: nil, axDocument: nil, axTitle: "✳ Claude Code"),
         ContextResult.value(.title, "✳ Claude Code", title: "✳ Claude Code"),
         "window title is the fallback context")
    t.eq(classifyContextValue(axURL: nil, axDocument: nil, axTitle: nil),
         ContextResult.none,
         "nothing available yields none, which is distinct from denied")
    t.eq(classifyContextValue(axURL: nil, axDocument: nil, axTitle: ""),
         ContextResult.none,
         "an empty title is treated as nothing, not as an empty context")
    t.eq(classifyContextValue(axURL: "not a url", axDocument: nil, axTitle: "Some Window"),
         ContextResult.value(.title, "Some Window", title: "Some Window"),
         "an unparseable URL falls through to the title rather than storing garbage")

    // Live probe. Accessibility is expected NOT to be granted before install
    // step 7, so this must report denied rather than crash or hang.
    // NOTE: add `import ApplicationServices` to the top of main.swift for
    // AXIsProcessTrusted, alongside the existing Foundation/StalkerCore/StalkerMac.
    let axProbe = AccessibilityContextProbe()
    if let f = SystemFocusProbe().frontmost() {
        let result = axProbe.context(for: f)
        if AXIsProcessTrusted() {
            t.expect(result != .denied, "AX granted: probe returns a real result")
        } else {
            t.eq(result, ContextResult.denied,
                 "AX not granted: probe reports denied, never silently nil")
        }
    } else {
        t.expect(false, "live AX probe had a frontmost app to query")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'classifyContextValue' in scope`.

- [ ] **Step 3: Write `ContextClassifier.swift`**

```swift
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
```

- [ ] **Step 4: Write `AccessibilityContextProbe.swift`**

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all Task 13 assertions `ok`, exit 0. Before Accessibility is granted, the live assertion takes the `denied` branch — that is the correct result, not a failure.

- [ ] **Step 6: Commit**

```bash
git add Sources/StalkerCore/ContextClassifier.swift Sources/StalkerMac/AccessibilityContextProbe.swift Sources/stalker-tests/main.swift
git commit -m "feat: Accessibility context probe with timeout and denied reporting"
```

---

### Task 14: Paths, argument parsing, and the CLI

**Files:**
- Create: `Sources/StalkerCore/Paths.swift`
- Create: `Sources/StalkerCore/Args.swift`
- Create: `Sources/stalker/main.swift`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–13.
- Produces:
  - `struct Paths: Sendable` with `dataDir, dbPath, courierDir, rulesPath: String` and `static func standard(home: String) -> Paths`
  - `enum Command: Equatable, Sendable` with cases `sample`, `report(date: String?)`, `doctor`, `help`
  - `func parseArgs(_ args: [String]) -> Command`
  - `func dayRange(_ dateString: String?, now: Int, timeZone: TimeZone) -> (from: Int, to: Int)`
  - Executable `stalker` supporting `stalker sample`, `stalker report [--date YYYY-MM-DD]`, `stalker doctor`

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 14: paths and argument parsing ---
    let paths = Paths.standard(home: "/Users/alex")
    t.eq(paths.dataDir, "/Users/alex/Library/Application Support/stalker", "data dir path")
    t.eq(paths.dbPath, "/Users/alex/Library/Application Support/stalker/stalker.db", "db path")
    t.eq(paths.courierDir, "/Users/alex/Library/Application Support/stalker/shell", "courier dir path")
    t.eq(paths.rulesPath, "/Users/alex/.config/stalker/rules.toml", "rules path is under .config")

    t.eq(parseArgs(["sample"]), Command.sample, "parses sample")
    t.eq(parseArgs(["doctor"]), Command.doctor, "parses doctor")
    t.eq(parseArgs(["report"]), Command.report(date: nil), "parses report with no date")
    t.eq(parseArgs(["report", "--date", "2026-09-30"]), Command.report(date: "2026-09-30"),
         "parses report with a date")
    t.eq(parseArgs([]), Command.help, "no arguments yields help")
    t.eq(parseArgs(["bogus"]), Command.help, "unknown command yields help")
    t.eq(parseArgs(["report", "--date"]), Command.help, "--date with no value yields help")

    let utc = TimeZone(identifier: "UTC")!
    let r = dayRange("2026-09-30", now: 0, timeZone: utc)
    t.eq(r.to - r.from, 86_400, "an explicit date spans exactly one day")
    let today = dayRange(nil, now: 1_790_000_000, timeZone: utc)
    t.expect(today.from <= 1_790_000_000 && 1_790_000_000 < today.to,
             "a nil date spans the day containing now")
    t.eq(today.from % 86_400, 0, "UTC day starts on a day boundary")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'Paths' in scope`.

- [ ] **Step 3: Write `Paths.swift` and `Args.swift`**

`Paths.swift`:

```swift
import Foundation

/// Config lives under `.config` and data under `Application Support`, so rules
/// stay hand-owned and version-controllable while the database stays
/// machine-owned and never hand-edited. Spec §6.1.
public struct Paths: Sendable {
    public let dataDir: String
    public let dbPath: String
    public let courierDir: String
    public let rulesPath: String

    public static func standard(home: String) -> Paths {
        let data = home + "/Library/Application Support/stalker"
        return Paths(dataDir: data,
                     dbPath: data + "/stalker.db",
                     courierDir: data + "/shell",
                     rulesPath: home + "/.config/stalker/rules.toml")
    }
}
```

`Args.swift`:

```swift
import Foundation

public enum Command: Equatable, Sendable {
    case sample
    case report(date: String?)
    case doctor
    case help
}

public func parseArgs(_ args: [String]) -> Command {
    guard let first = args.first else { return .help }
    switch first {
    case "sample": return .sample
    case "doctor": return .doctor
    case "report":
        guard args.count > 1 else { return .report(date: nil) }
        guard args[1] == "--date", args.count > 2 else { return .help }
        return .report(date: args[2])
    default: return .help
    }
}

/// Start and end of the requested day, in unix seconds.
public func dayRange(_ dateString: String?, now: Int, timeZone: TimeZone) -> (from: Int, to: Int) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone

    let reference: Date
    if let dateString {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        reference = f.date(from: dateString) ?? Date(timeIntervalSince1970: TimeInterval(now))
    } else {
        reference = Date(timeIntervalSince1970: TimeInterval(now))
    }

    let start = cal.startOfDay(for: reference)
    let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
}
```

- [ ] **Step 4: Write `Sources/stalker/main.swift`**

```swift
import ApplicationServices   // AXIsProcessTrusted, used by `doctor`
import Foundation
import StalkerCore
import StalkerMac

let home = FileManager.default.homeDirectoryForCurrentUser.path
let paths = Paths.standard(home: home)
let config = TickConfig.default

func loadRules() -> RuleSet? {
    guard let text = try? String(contentsOfFile: paths.rulesPath, encoding: .utf8) else {
        FileHandle.standardError.write("no rules file at \(paths.rulesPath)\n".data(using: .utf8)!)
        return nil
    }
    do {
        return try parseRules(text, homeDirectory: home)
    } catch {
        // A typo must fail loudly. Degrading to "everything unclear" would void a
        // day of reporting with no visible symptom. Spec §9.
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        return nil
    }
}

func makeProbes() -> Probes {
    Probes(focus: SystemFocusProbe(),
           idle: SystemIdleProbe(),
           lock: SystemLockProbe(),
           engagement: PowerAssertionProbe(),
           context: AccessibilityContextProbe(),
           courier: DirectoryCourierProbe(dir: paths.courierDir))
}

/// One tick. launchd invokes this every 30 seconds, so the process is short-lived
/// and the open interval is recovered from the database rather than held in memory.
func runSample() -> Int32 {
    do {
        let store = try Store(path: paths.dbPath)
        try store.migrate()
        let reconciler = Reconciler(store: store, samplePeriod: config.samplePeriod)
        try reconciler.loadOpen()
        let previous = reconciler.open.map { iv in
            Sample(at: iv.endedAt, kind: iv.kind, bundleId: iv.bundleId, appName: iv.appName,
                   contextKind: iv.contextKind, context: iv.context, title: iv.title,
                   hadInput: false, engaged: false)
        }
        let now = Int(Date().timeIntervalSince1970)
        let sample = makeSample(now: now, previous: previous, config: config, probes: makeProbes())
        try reconciler.ingest(sample)
        return 0
    } catch {
        FileHandle.standardError.write("sample failed: \(error)\n".data(using: .utf8)!)
        return 1
    }
}

func runReport(date: String?) -> Int32 {
    guard let rules = loadRules() else { return 1 }
    do {
        let store = try Store(path: paths.dbPath)
        try store.migrate()
        let tz = TimeZone.current
        let range = dayRange(date, now: Int(Date().timeIntervalSince1970), timeZone: tz)
        let ivs = try store.intervals(from: range.from, to: range.to)
        if ivs.isEmpty {
            print("no data for that day")
            return 0
        }
        print(render(ivs, bucketSecs: bucketSeconds, rules: rules, timeZone: tz))
        return 0
    } catch {
        FileHandle.standardError.write("report failed: \(error)\n".data(using: .utf8)!)
        return 1
    }
}

func runDoctor() -> Int32 {
    var problems = 0
    func check(_ ok: Bool, _ label: String, _ hint: String = "") {
        print("  \(ok ? "ok  " : "FAIL") \(label)")
        if !ok {
            problems += 1
            if !hint.isEmpty { print("       → \(hint)") }
        }
    }

    print("stalker doctor")

    let fm = FileManager.default
    check(fm.fileExists(atPath: paths.dataDir), "data directory exists",
          "run scripts/install.sh")
    check(fm.isWritableFile(atPath: paths.dataDir), "data directory is writable")
    check(fm.fileExists(atPath: paths.courierDir), "courier directory exists",
          "run scripts/install.sh")
    check(fm.fileExists(atPath: paths.rulesPath), "rules file exists",
          "write \(paths.rulesPath)")
    check(loadRules() != nil, "rules file parses")

    check(SystemFocusProbe().frontmost() != nil, "focus probe works")
    check(SystemIdleProbe().inputIdleSeconds() >= 0, "idle probe works")

    // Accessibility, plus the AX latency the spec leaves open as item 1.
    let trusted = AXIsProcessTrusted()
    check(trusted, "Accessibility granted",
          "System Settings → Privacy & Security → Accessibility, add this binary")
    if trusted, let f = SystemFocusProbe().frontmost() {
        let probe = AccessibilityContextProbe()
        let t0 = Date()
        _ = probe.context(for: f)
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "  ok   AX call latency: %.1f ms", ms))
        if ms > 90 {
            print("       → slower than AppleScript's measured 90 ms; see spec open item 1")
        }
    }

    // Time Machine exclusion, spec §11.
    let excl = Process()
    excl.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
    excl.arguments = ["isexcluded", paths.dataDir]
    let pipe = Pipe()
    excl.standardOutput = pipe
    try? excl.run()
    excl.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    check(out.contains("[Excluded]"), "database excluded from Time Machine",
          "tmutil addexclusion \"\(paths.dataDir)\"")

    print(problems == 0 ? "\nall checks passed" : "\n\(problems) problem(s)")
    return problems == 0 ? 0 : 1
}

let status: Int32
switch parseArgs(Array(CommandLine.arguments.dropFirst())) {
case .sample:              status = runSample()
case .report(let date):    status = runReport(date: date)
case .doctor:              status = runDoctor()
case .help:
    print("""
    stalker — local activity tracker

      stalker sample                    take one observation (launchd calls this)
      stalker report [--date YYYY-MM-DD] 30-minute report, default today
      stalker doctor                    verify permissions and setup
    """)
    status = 0
}
exit(status)
```

- [ ] **Step 5: Run tests, then exercise the CLI end to end**

Run: `swift run stalker-tests`
Expected: all Task 14 assertions `ok`, exit 0.

Run: `swift run stalker help`
Expected: the usage text.

Run: `swift run stalker doctor`
Expected: it runs and reports failures for the not-yet-created directories and the not-yet-granted Accessibility permission. Those failures are correct at this point — Task 15 creates the directories.

- [ ] **Step 6: Commit**

```bash
git add Sources/StalkerCore/Paths.swift Sources/StalkerCore/Args.swift Sources/stalker/main.swift Sources/stalker-tests/main.swift
git commit -m "feat: CLI with sample, report, and doctor subcommands"
```

---

### Task 15: Shell hook, launchd agent, and installer

**Files:**
- Create: `scripts/stalker.zsh`
- Create: `scripts/stalker.sample.plist`
- Create: `scripts/install.sh`
- Create: `scripts/rules.toml.default`
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `stalker` binary (Task 14), `parseCourierLine` (Task 8).
- Produces: installable shell hook, launchd plist, and an idempotent installer.

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 15: install artefacts ---
    let repo = FileManager.default.currentDirectoryPath
    let fm2 = FileManager.default
    t.expect(fm2.fileExists(atPath: repo + "/scripts/stalker.zsh"), "shell hook exists")
    t.expect(fm2.fileExists(atPath: repo + "/scripts/stalker.sample.plist"), "launchd plist exists")
    t.expect(fm2.fileExists(atPath: repo + "/scripts/install.sh"), "installer exists")
    t.expect(fm2.fileExists(atPath: repo + "/scripts/rules.toml.default"), "default rules exist")

    // The hook must use only zsh builtins. A subprocess costs ~5 ms per command
    // instead of ~0.06 ms, which is felt at the prompt.
    if let hook = try? String(contentsOfFile: repo + "/scripts/stalker.zsh", encoding: .utf8) {
        t.expect(hook.contains("zmodload zsh/datetime"),
                 "hook loads zsh/datetime for builtin EPOCHSECONDS")
        t.expect(hook.contains("$EPOCHSECONDS"), "hook uses builtin EPOCHSECONDS")
        t.expect(!hook.contains("$(date"), "hook does not spawn date")
        t.expect(!hook.contains("sqlite3"), "hook does not touch the database")
        t.expect(hook.contains("add-zsh-hook preexec"), "hook registers preexec")
        t.expect(hook.contains("add-zsh-hook chpwd"), "hook registers chpwd")
    } else {
        t.expect(false, "shell hook is readable")
    }

    // The default rules must parse with the very parser that will read them.
    if let defaults = try? String(contentsOfFile: repo + "/scripts/rules.toml.default", encoding: .utf8) {
        do {
            let rs = try parseRules(defaults, homeDirectory: "/Users/alex")
            t.expect(rs.rules.count >= 4, "default rules contain at least four rules")
            t.eq(rs.defaultCategory, "unclear", "default category is unclear")
        } catch {
            t.expect(false, "default rules parse", "\(error)")
        }
    } else {
        t.expect(false, "default rules are readable")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `FAIL shell hook exists`, and the other Task 15 assertions failing.

- [ ] **Step 3: Write the shell hook and default rules**

`scripts/stalker.zsh`:

```zsh
# stalker courier hook. Source this from ~/.zshrc.
#
# Writes one line — "<unix-seconds> <cwd>" — to a per-tty file, overwriting it.
# The file never grows; the whole directory stays around 16K. The sampler reads
# these files on its own 30-second tick and takes the newest as the focused
# shell's directory.
#
# Builtins only, no subprocess: measured at 0.0587 ms per command. The naive
# version that shells out to sqlite3 measured 4.91 ms, which is felt at the prompt.

zmodload zsh/datetime

STALKER_COURIER_DIR="${HOME}/Library/Application Support/stalker/shell"

_stalker_courier() {
  [[ -d "$STALKER_COURIER_DIR" ]] || return 0
  print -r -- "$EPOCHSECONDS $PWD" > "$STALKER_COURIER_DIR/${TTY:t}"
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _stalker_courier
add-zsh-hook chpwd   _stalker_courier
```

`scripts/rules.toml.default`:

```toml
# stalker classification rules.
#
# Categories are applied when a report is generated, never when data is
# collected — so any rule you add here re-classifies your whole history.
#
# Precedence is by specificity, not file order:
#   tier 1  app (or app_name) AND context
#   tier 2  context only
#   tier 3  app (or app_name) only

default = "unclear"

[[rule]]
app = "com.google.Chrome"
category = "work"

[[rule]]
app = "com.microsoft.edgemac"
category = "fun"

# PWA bundle ids are opaque, install-specific hashes, so match these by name.
[[rule]]
app_name = "Google Meet"
category = "work"

[[rule]]
app_name = "Gmail"
category = "work"

[[rule]]
app_name = "Google Calendar"
category = "work"

[[rule]]
app = "com.tinyspeck.slackmacgap"
category = "work"

# Path rules are app-independent: they cover terminal directories, Finder
# folders, and open documents with the same pattern.
[[rule]]
context = "*/Casey/Work/*"
category = "work"

[[rule]]
context = "*/Casey/Projects/*"
category = "pet-project"
```

- [ ] **Step 4: Write the launchd plist and installer**

`scripts/stalker.sample.plist` — `install.sh` rewrites `__BINARY__` with the real path:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>stalker.sample</string>
    <key>ProgramArguments</key>
    <array>
        <string>__BINARY__</string>
        <string>sample</string>
    </array>
    <key>StartInterval</key>
    <integer>30</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/stalker.err</string>
</dict>
</plist>
```

`scripts/install.sh`:

```bash
#!/bin/bash
# Idempotent installer. Safe to re-run.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Note: "~/..." inside double quotes does NOT expand. Always use "$HOME/...".
DATA_DIR="$HOME/Library/Application Support/stalker"
CONFIG_DIR="$HOME/.config/stalker"
BIN_DIR="$HOME/.local/bin"
BINARY="$BIN_DIR/stalker"
PLIST="$HOME/Library/LaunchAgents/stalker.sample.plist"

echo "1. building"
cd "$REPO"
swift build -c release
mkdir -p "$BIN_DIR"
cp "$(swift build -c release --show-bin-path)/stalker" "$BINARY"

echo "2. creating directories"
mkdir -p "$DATA_DIR/shell" "$CONFIG_DIR" "$HOME/Library/LaunchAgents"

echo "3. excluding the database from Time Machine"
tmutil addexclusion "$DATA_DIR"
tmutil isexcluded "$DATA_DIR"

echo "4. installing default rules (existing file is kept)"
if [ -f "$CONFIG_DIR/rules.toml" ]; then
  echo "   rules.toml already exists, leaving it alone"
else
  cp "$REPO/scripts/rules.toml.default" "$CONFIG_DIR/rules.toml"
fi

echo "5. shell hook"
HOOK_LINE="source \"$REPO/scripts/stalker.zsh\""
if grep -qF "$HOOK_LINE" "$HOME/.zshrc" 2>/dev/null; then
  echo "   hook already sourced from ~/.zshrc"
else
  printf '\n# stalker courier hook\n%s\n' "$HOOK_LINE" >> "$HOME/.zshrc"
  echo "   added to ~/.zshrc — open a new terminal tab for it to take effect"
fi

echo "6. launchd agent"
sed "s|__BINARY__|$BINARY|" "$REPO/scripts/stalker.sample.plist" > "$PLIST"
plutil -lint "$PLIST"
launchctl bootout "gui/$UID/stalker.sample" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "   loaded"

echo
echo "7. REMAINING MANUAL STEP"
echo "   Grant Accessibility to:  $BINARY"
echo "   System Settings → Privacy & Security → Accessibility"
echo
echo "8. then verify:  $BINARY doctor"
```

```bash
chmod +x scripts/install.sh
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all Task 15 assertions `ok`, exit 0.

- [ ] **Step 6: Verify the plist and hook for real**

Run: `plutil -lint scripts/stalker.sample.plist`
Expected: `scripts/stalker.sample.plist: OK`

Run the hook's cost in isolation, confirming the measured figure:

```bash
mkdir -p /tmp/stalker-hook-test
zsh -c 'zmodload zsh/datetime
D=/tmp/stalker-hook-test; ID=ttys000
hook() { print -r -- "$EPOCHSECONDS $PWD" > $D/$ID }
typeset -F SECONDS=0
for i in {1..2000}; do hook; done
printf "%.4f ms per command\n" $(( SECONDS*1000/2000 ))'
cat /tmp/stalker-hook-test/ttys000
rm -rf /tmp/stalker-hook-test
```

Expected: under 0.2 ms per command, and one line of the form `<digits> <path>`.

- [ ] **Step 7: Commit**

```bash
git add scripts/ Sources/stalker-tests/main.swift
git commit -m "feat: shell hook, launchd agent, and installer"
```

---

### Task 16: Browser AppleScript fallback

**Files:**
- Create: `Sources/StalkerCore/FallbackDecision.swift`
- Create: `Sources/StalkerMac/BrowserAppleScriptProbe.swift`
- Modify: `Sources/stalker/main.swift` (the `makeProbes()` function)
- Modify: `Sources/stalker-tests/main.swift`

**Interfaces:**
- Consumes: `ContextProbe`, `ContextResult`, `FocusInfo` (Task 10), `normalizeURL` (Task 3), `AccessibilityContextProbe` (Task 13).
- Produces:
  - `let browserBundleIds: Set<String>` and `func shouldFallBack(primary: ContextResult, bundleId: String?, browserBundleIds: Set<String>) -> Bool` in `StalkerCore`
  - `struct BrowserAppleScriptProbe: Sendable` with `init(timeoutSeconds: Int = 2)` and `func url(bundleId: String) -> String?`
  - `struct FallbackContextProbe: ContextProbe` with `init(primary: any ContextProbe, fallback: BrowserAppleScriptProbe, browserBundleIds: Set<String>)`

Spec §5.3 keeps AppleScript as a browser-only fallback for when Accessibility returns nothing. Automation to Chrome and Edge is already granted on this machine — verified, both returned live URLs.

- [ ] **Step 1: Write the failing tests**

Add to `run()`:

```swift
    // --- Task 16: browser AppleScript fallback ---
    let browsers = browserBundleIds

    t.eq(shouldFallBack(primary: .none, bundleId: "com.google.Chrome", browserBundleIds: browsers),
         true, "AX returning nothing for a browser falls back to AppleScript")
    t.eq(shouldFallBack(primary: .none, bundleId: "com.apple.Notes", browserBundleIds: browsers),
         false, "a non-browser does not fall back")
    t.eq(shouldFallBack(primary: .value(.url, "a.com/x", title: nil),
                        bundleId: "com.google.Chrome", browserBundleIds: browsers),
         false, "a successful AX result is not second-guessed")
    t.eq(shouldFallBack(primary: .value(.title, "Some Window", title: "Some Window"),
                        bundleId: "com.google.Chrome", browserBundleIds: browsers),
         true, "a browser yielding only a title still falls back to get the URL")

    // Deliberate: a denied grant must NOT be papered over by the fallback.
    // Recording `denied` is the only way a revoked permission stays visible.
    t.eq(shouldFallBack(primary: .denied, bundleId: "com.google.Chrome", browserBundleIds: browsers),
         false, "denied is reported, never silently replaced by the fallback")

    t.eq(shouldFallBack(primary: .none, bundleId: nil, browserBundleIds: browsers),
         false, "a nil bundle id cannot be a known browser")

    // Live: Automation to Chrome is already granted, so if Chrome is running this
    // returns a real URL. If Chrome is not running, nil is the correct answer.
    let asProbe = BrowserAppleScriptProbe()
    let chromeRunning = NSWorkspace.shared.runningApplications
        .contains { $0.bundleIdentifier == "com.google.Chrome" }
    let liveURL = asProbe.url(bundleId: "com.google.Chrome")
    if chromeRunning {
        t.expect(liveURL != nil, "AppleScript returns a URL for a running Chrome (\(liveURL ?? "nil"))")
    } else {
        t.eq(liveURL, nil, "AppleScript returns nil when Chrome is not running")
    }

    // An unknown application must not hang or crash the tick.
    t.eq(asProbe.url(bundleId: "com.example.NotAnApp"), nil,
         "an unknown bundle id returns nil rather than hanging")

    // Composite probe: falls through to the fallback and normalises the result.
    struct NoneProbe: ContextProbe {
        func context(for focus: FocusInfo) -> ContextResult { .none }
    }
    let composite = FallbackContextProbe(primary: NoneProbe(), fallback: asProbe,
                                         browserBundleIds: browsers)
    let notesResult = composite.context(for: FocusInfo(bundleId: "com.apple.Notes",
                                                      appName: "Notes", pid: 1))
    t.eq(notesResult, ContextResult.none, "composite returns none for a non-browser")
```

Add `import Cocoa` to the top of `Sources/stalker-tests/main.swift` for `NSWorkspace`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run stalker-tests`
Expected: `cannot find 'shouldFallBack' in scope`, `cannot find 'BrowserAppleScriptProbe' in scope`.

- [ ] **Step 3: Write `FallbackDecision.swift`**

```swift
/// Browsers whose URL can be read by AppleScript. Automation to Chrome and Edge
/// is already granted on this machine — both returned live URLs when probed.
public let browserBundleIds: Set<String> = [
    "com.google.Chrome",
    "com.microsoft.edgemac",
    "com.apple.Safari",
    "company.thebrowser.Browser",   // Arc
    "com.brave.Browser",
]

/// Should the AppleScript fallback run?
///
/// Only when Accessibility produced no URL for a known browser. Two cases are
/// deliberately excluded:
///
/// - `.denied` never falls back. Recording `denied` is the only way a revoked
///   Accessibility grant stays visible; silently substituting AppleScript would
///   hide it and the `denied` column would never fire. Spec §9.
/// - A `.url` result is not second-guessed — AX already answered.
///
/// A browser yielding only a `.title` does fall back, because the title is not
/// the URL and the URL is what classification needs.
public func shouldFallBack(primary: ContextResult, bundleId: String?,
                           browserBundleIds: Set<String>) -> Bool {
    guard let bundleId, browserBundleIds.contains(bundleId) else { return false }
    switch primary {
    case .denied:                 return false
    case .value(.url, _, _):      return false
    case .none, .value:           return true
    }
}
```

- [ ] **Step 4: Write `BrowserAppleScriptProbe.swift`**

```swift
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
```

- [ ] **Step 5: Wire it into the CLI**

In `Sources/stalker/main.swift`, replace the `context:` line of `makeProbes()`:

```swift
func makeProbes() -> Probes {
    Probes(focus: SystemFocusProbe(),
           idle: SystemIdleProbe(),
           lock: SystemLockProbe(),
           engagement: PowerAssertionProbe(),
           context: FallbackContextProbe(primary: AccessibilityContextProbe(),
                                         fallback: BrowserAppleScriptProbe(),
                                         browserBundleIds: browserBundleIds),
           courier: DirectoryCourierProbe(dir: paths.courierDir))
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift run stalker-tests`
Expected: all Task 16 assertions `ok`, exit 0.

Run: `swift run stalker sample && swift run stalker report`
Expected: `sample` exits 0; `report` prints either a one-row report or `no data for that day`. This is the first end-to-end run of the whole pipeline.

- [ ] **Step 7: Commit**

```bash
git add Sources/StalkerCore/FallbackDecision.swift Sources/StalkerMac/BrowserAppleScriptProbe.swift Sources/stalker/main.swift Sources/stalker-tests/main.swift
git commit -m "feat: AppleScript browser fallback behind Accessibility"
```

---

## After the plan

Once every task is committed:

1. Run `scripts/install.sh`.
2. Grant Accessibility to `~/.local/bin/stalker` in System Settings.
3. Run `stalker doctor` — it must report all checks passed, and it prints the AX
   call latency, which closes spec open item 1.
4. Leave it running for a day, then `stalker report`.
5. The `unclear` section of that first report is the list of rules worth adding.

Deliberately not built: the CoreAudio per-process audio backup signal that spec
§5.4 offers "if assertions ever prove unreliable". Power assertions were verified
working against a real playing video, and the audio route needs bundle-id-prefix
mapping (`com.microsoft.edgemac.helper` to `com.microsoft.edgemac`) because
Chromium launches its audio service detached and the ppid walk fails. Add it only
if engagement detection actually proves unreliable in use.

Spec open items 2 and 3 (whether Accessibility exposes Slack's channel, and
whether it exposes more of Ghostty than AppleScript does) become answerable once
the permission is granted. Both are upside, not requirements; investigate only if
the first reports leave something you want.
