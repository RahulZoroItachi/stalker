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

    if let rs0 = try? parseRules(goodToml, homeDirectory: "/Users/alex") {
        t.eq(rs0.defaultCategory, "unclear", "parses default category")
        t.eq(rs0.rules.count, 5, "parses five rules")
        t.expect(rs0.rules.contains { $0.app == "com.google.Chrome" && $0.category == "work" },
                 "parses Chrome rule")
        t.expect(rs0.rules.contains { $0.appName == "Google Meet" && $0.category == "work" },
                 "parses PWA rule by app_name")
        t.expect(rs0.rules.contains { $0.context == "*/Casey/Projects/*" && $0.category == "pet-project" },
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
    if let rsT = try? parseRules(tildeToml, homeDirectory: "/Users/alex") {
        t.eq(rsT.rules.first?.context, "/Users/alex/Work/*", "expands leading tilde in context glob")
        t.expect(globMatches(rsT.rules.first!.context!, "/Users/alex/Work/PM_Assistant"),
                 "expanded glob matches an absolute path")
    } else {
        t.expect(false, "tilde toml parses")
    }

    // Review Focus 5: malformed input must throw, never silently degrade.
    func parseThrows(_ str: String, _ name: String) {
        do {
            _ = try parseRules(str, homeDirectory: "/Users/alex")
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
    if let rsTier = try? parseRules(tierToml, homeDirectory: "/Users/alex") {
        t.eq(rsTier.rules.map(\.tier), [1, 2, 3], "rules are sorted by tier, most specific first")
    } else {
        t.expect(false, "tier toml parses")
    }

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

    return t.summary()
}

exit(run())
