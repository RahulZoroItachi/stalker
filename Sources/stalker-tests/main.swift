import Foundation
import StalkerCore
import StalkerMac

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

    // --- Task 9: report ---
    t.eq(bucketStart(1800, bucketSecs: 1800), 1800, "exact boundary is its own bucket")
    t.eq(bucketStart(1900, bucketSecs: 1800), 1800, "mid-bucket rounds down")
    t.eq(bucketStart(3599, bucketSecs: 1800), 1800, "last second of a bucket rounds down")

    func mkIv(_ start: Int, _ end: Int, bundle: String?, ctx: String?, kind: Kind = .app) -> Interval {
        Interval(id: nil, kind: kind, startedAt: start, endedAt: end,
                 bundleId: bundle, appName: bundle, contextKind: ctx == nil ? nil : .url,
                 context: ctx, title: nil, samples: 1, active: 1, engaged: 0)
    }

    t.eq(overlapSeconds(mkIv(0, 600, bundle: "x", ctx: nil), bucketStart: 0, bucketEnd: 1800), 600,
         "interval fully inside a bucket contributes its whole duration")
    t.eq(overlapSeconds(mkIv(1500, 2100, bundle: "x", ctx: nil), bucketStart: 0, bucketEnd: 1800), 300,
         "interval spanning a boundary contributes only its overlap")
    t.eq(overlapSeconds(mkIv(1500, 2100, bundle: "x", ctx: nil), bucketStart: 1800, bucketEnd: 3600), 300,
         "the remainder lands in the next bucket")
    t.eq(overlapSeconds(mkIv(5000, 6000, bundle: "x", ctx: nil), bucketStart: 0, bucketEnd: 1800), 0,
         "non-overlapping interval contributes nothing")

    // Review Focus 4: a clock correction can leave ended_at before started_at.
    // A negative duration would corrupt every total it lands in.
    t.eq(overlapSeconds(mkIv(1000, 400, bundle: "x", ctx: nil), bucketStart: 0, bucketEnd: 1800), 0,
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

    let spanning = [mkIv(1500, 2100, bundle: "com.google.Chrome", ctx: "docs.google.com/d")]
    let slices = slice(spanning, bucketSecs: 1800, rules: reportRules)
    t.eq(slices.count, 2, "an interval spanning a boundary produces two slices")
    t.eq(slices.reduce(0) { $0 + $1.seconds }, 600, "slices preserve the total duration")
    t.expect(slices.allSatisfy { $0.category == "work" }, "both slices carry the same category")

    let mixed = [
        mkIv(0, 900, bundle: "com.google.Chrome", ctx: "docs.google.com/d"),
        mkIv(900, 1800, bundle: "com.microsoft.edgemac", ctx: "youtube.com/watch"),
        mkIv(1800, 2400, bundle: "com.tinyspeck.slackmacgap", ctx: nil),
    ]
    let tot = totals(slice(mixed, bucketSecs: 1800, rules: reportRules))
    t.eq(tot.first { $0.category == "work" }?.seconds, 900, "work total")
    t.eq(tot.first { $0.category == "fun" }?.seconds, 900, "fun total")
    t.eq(tot.first { $0.category == "unclear" }?.seconds, 600, "unmatched time totals under unclear")
    t.expect(tot.first!.seconds >= tot.last!.seconds, "totals are sorted by seconds descending")

    // The per-category context breakdown is what makes habit drift visible:
    // youtube time sitting inside `work` should be listed, not hidden in a total.
    let drift = [
        mkIv(0, 600, bundle: "com.google.Chrome", ctx: "docs.google.com/d"),
        mkIv(600, 900, bundle: "com.google.Chrome", ctx: "youtube.com/watch"),
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
        let engagedFlag: Bool
        func isEngaged(pid: Int32) -> Bool { engagedFlag }
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
               engagement: FakeEngagement(engagedFlag: engaged), context: FakeContext(result: ctx),
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

    return t.summary()
}

exit(run())
