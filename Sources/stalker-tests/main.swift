import ApplicationServices
import Cocoa
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

    let text = renderDay(mixed, bucketSecs: 1800, rules: reportRules,
                         timeZone: TimeZone(identifier: "UTC")!, from: 0, to: 86_400)
    t.expect(text.contains("work"), "rendered report names categories")
    t.expect(text.contains("TOTALS"), "rendered report has a totals section")
    t.expect(text.contains("unclear"), "rendered report surfaces unclear time")

    // The timeline row must pick the category with the most TOTAL time in the
    // bucket, not whichever single continuous fragment happens to be longest.
    // Two unclear visits (400s + 300s = 700s) outweigh one fun visit (500s),
    // even though that one fun fragment is longer than either unclear fragment alone.
    let dominance = [
        mkIv(0, 400, bundle: "com.tinyspeck.slackmacgap", ctx: nil),
        mkIv(400, 900, bundle: "com.microsoft.edgemac", ctx: nil),
        mkIv(900, 1200, bundle: "com.tinyspeck.slackmacgap", ctx: nil),
    ]
    let dominanceText = renderDay(dominance, bucketSecs: 1800, rules: reportRules,
                                  timeZone: TimeZone(identifier: "UTC")!, from: 0, to: 86_400)
    // The report opens with a date heading, so the first timeline row is the first
    // line carrying a time span rather than simply the first line.
    let timelineRow = dominanceText.components(separatedBy: "\n")
        .first { $0.contains("─") } ?? ""
    t.expect(timelineRow.contains("unclear"),
             "the category with more total time (unclear, 700s) wins the row, got: \(timelineRow)")
    t.expect(!timelineRow.contains("fun"),
             "a single longer fragment (fun, 500s) must not beat a category with more total time")

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
        func newest(now: Int, bundleId: String) -> CourierReading? { reading }
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
    t.eq(typing.engaged, false, "engagement records false when nothing is playing")
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
        let nowSecs = Int(Date().timeIntervalSince1970)
        let ghosttyDir = dir + "/com.mitchellh.ghostty"
        let itermDir = dir + "/com.googlecode.iterm2"
        try FileManager.default.createDirectory(atPath: ghosttyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: itermDir, withIntermediateDirectories: true)
        try "\(nowSecs) /Users/alex/Desktop/Casey/Work/PM_Assistant"
            .write(toFile: ghosttyDir + "/ttys000", atomically: true, encoding: .utf8)
        // Deliberately newer than the ghostty reading, to prove cross-app recency
        // never wins: only readings under the app actually asked for are
        // candidates, no matter how much staler they are than another app's.
        try "\(nowSecs + 60) /Users/alex/Desktop/Casey/Projects/stalker"
            .write(toFile: itermDir + "/ttys999", atomically: true, encoding: .utf8)

        let cp = DirectoryCourierProbe(dir: dir)
        t.eq(cp.newest(now: nowSecs, bundleId: "com.mitchellh.ghostty")?.cwd,
             "/Users/alex/Desktop/Casey/Work/PM_Assistant",
             "courier probe reads the newest file scoped to the requested app")
        t.eq(cp.newest(now: nowSecs, bundleId: "com.googlecode.iterm2")?.cwd,
             "/Users/alex/Desktop/Casey/Projects/stalker",
             "a different app's reading is scoped independently, even though it is newer")
        t.eq(cp.newest(now: nowSecs, bundleId: "com.apple.Terminal"), nil,
             "an app with no courier subdirectory yet returns nil, never another app's reading")
        try FileManager.default.removeItem(atPath: dir)
    } catch {
        t.expect(false, "courier probe test ran without throwing", "\(error)")
    }

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

    // Live smoke test: the call must succeed and return a Bool rather than crash.
    let livePid = SystemFocusProbe().frontmost()?.pid ?? 0
    let liveEngaged = PowerAssertionProbe().isEngaged(pid: livePid)
    t.expect(liveEngaged == true || liveEngaged == false,
             "power assertion probe runs against the live system (engaged=\(liveEngaged))")

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
    t.eq(classifyContextValue(axURL: nil, axDocument: "https://new-relic.atlassian.net/browse/NR-547597",
                              axTitle: "NR-547597"),
         ContextResult.value(.url, "new-relic.atlassian.net/browse/NR-547597", title: "NR-547597"),
         "a web URL surfaced via AXDocument (Chrome) classifies as url, not file")

    // Live probe. Accessibility is expected NOT to be granted before install
    // step 7, so this must report denied rather than crash or hang.
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

    // --- Task 14: paths and argument parsing ---
    let paths = Paths.standard(home: "/Users/alex")
    t.eq(paths.dataDir, "/Users/alex/Library/Application Support/stalker", "data dir path")
    t.eq(paths.dbPath, "/Users/alex/Library/Application Support/stalker/stalker.db", "db path")
    t.eq(paths.courierDir, "/Users/alex/Library/Application Support/stalker/shell", "courier dir path")
    t.eq(paths.rulesPath, "/Users/alex/.config/stalker/rules.toml", "rules path is under .config")

    t.eq(parseArgs(["sample"]), Command.sample, "parses sample")
    t.eq(parseArgs(["doctor"]), Command.doctor, "parses doctor")
    t.eq(parseArgs(["report"]), Command.report(ReportRequest()), "parses report with no date")
    t.eq(parseArgs(["report", "--date", "2026-09-30"]), Command.report(ReportRequest(date: "2026-09-30")),
         "parses report with a date")
    t.eq(parseArgs([]), Command.help, "no arguments yields help")
    // Malformed arguments are a usage error, not a help request, so the process exits
    // non-zero. See reportArgsTests for the full set.
    t.eq(parseArgs(["bogus"]), Command.usageError, "unknown command is a usage error")
    t.eq(parseArgs(["report", "--date"]), Command.usageError, "--date with no value is a usage error")

    let utc = TimeZone(identifier: "UTC")!
    let r = dayRange("2026-09-30", now: 0, timeZone: utc)
    t.eq(r.to - r.from, 86_400, "an explicit date spans exactly one day")
    let today = dayRange(nil, now: 1_790_000_000, timeZone: utc)
    t.expect(today.from <= 1_790_000_000 && 1_790_000_000 < today.to,
             "a nil date spans the day containing now")
    t.eq(today.from % 86_400, 0, "UTC day starts on a day boundary")

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
        // Assert on code, not prose: the hook's comments legitimately mention the
        // slower sqlite3 alternative and its measured cost.
        let hookCode = hook
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")

        t.expect(hook.contains("zmodload zsh/datetime"),
                 "hook loads zsh/datetime for builtin EPOCHSECONDS")
        t.expect(hookCode.contains("$EPOCHSECONDS"), "hook uses builtin EPOCHSECONDS")
        t.expect(!hookCode.contains("$(date"), "hook does not spawn date")
        t.expect(!hookCode.contains("sqlite3"), "hook does not touch the database")
        t.expect(hookCode.contains("add-zsh-hook preexec"), "hook registers preexec")
        t.expect(hookCode.contains("add-zsh-hook chpwd"), "hook registers chpwd")
    } else {
        t.expect(false, "shell hook is readable")
    }

    // The default rules must parse with the very parser that will read them.
    if let defaults = try? String(contentsOfFile: repo + "/scripts/rules.toml.default", encoding: .utf8) {
        do {
            let rsD = try parseRules(defaults, homeDirectory: "/Users/alex")
            t.expect(rsD.rules.count >= 4, "default rules contain at least four rules")
            t.eq(rsD.defaultCategory, "unclear", "default category is unclear")
        } catch {
            t.expect(false, "default rules parse", "\(error)")
        }
    } else {
        t.expect(false, "default rules are readable")
    }

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

    // A denied grant DOES fall back. The earlier rule refused to, so a revoked
    // Accessibility grant meant no browser URL was collected at all — for weeks,
    // while Automation sat granted and able to answer every request. `denied` is
    // still what gets recorded when AppleScript cannot answer either, so the
    // column keeps firing and now means "no source could supply a URL".
    t.eq(shouldFallBack(primary: .denied, bundleId: "com.google.Chrome", browserBundleIds: browsers),
         true, "a denied grant falls back to AppleScript rather than losing the URL")
    t.eq(shouldFallBack(primary: .denied, bundleId: "com.apple.Notes", browserBundleIds: browsers),
         false, "a denied non-browser still records denied, since nothing else can answer")
    t.eq(shouldFallBack(primary: .value(.url, "a.com/x", title: nil),
                        bundleId: "com.microsoft.edgemac", browserBundleIds: browsers),
         false, "a URL Accessibility already found is not re-fetched over AppleScript")

    // The composition: denied primary plus a working fallback yields the URL, and
    // denied survives only when the fallback cannot answer either.
    struct DeniedOnly: ContextProbe {
        func context(for focus: FocusInfo) -> ContextResult { .denied }
    }
    let edgeFocus = FocusInfo(bundleId: "com.microsoft.edgemac", appName: "Microsoft Edge", pid: 7)
    let deniedComposite = FallbackContextProbe(primary: DeniedOnly(),
                                               fallback: BrowserAppleScriptProbe(),
                                               browserBundleIds: browsers)
    let edgeResult = deniedComposite.context(for: edgeFocus)
    // Live: Edge may or may not be running with a front window. Either a URL or a
    // preserved `denied` is correct; anything else is not.
    switch edgeResult {
    case .denied:
        t.expect(true, "denied is preserved when AppleScript cannot answer either")
    case .value(let k, let v, _):
        t.expect(k == .url || k == .file, "fallback produced a URL for a denied browser (got \(v))")
    case .none:
        t.expect(false, "a denied browser must never degrade to no context at all")
    }

    t.eq(shouldFallBack(primary: .none, bundleId: nil, browserBundleIds: browsers),
         false, "a nil bundle id cannot be a known browser")

    // Live: Automation to Chrome is already granted, so if Chrome is running this
    // returns a real URL. If Chrome is not running, nil is the correct answer.
    let asProbe = BrowserAppleScriptProbe()
    let chromeRunning = NSWorkspace.shared.runningApplications
        .contains { $0.bundleIdentifier == "com.google.Chrome" }
    let liveURL = asProbe.url(bundleId: "com.google.Chrome")
    // Smoke only: whether Chrome has a front window, and what is in it, is live
    // state this suite must not depend on. Correctness lives in the unit tests.
    t.expect(liveURL == nil || !(liveURL!.isEmpty),
             "AppleScript probe returns nil or a non-empty value (running=\(chromeRunning), got \(liveURL ?? "nil"))")

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

    // --- Final review fixes ---
    // IMPORTANT 1: an interval must account for the time its ticks represent.
    // endedAt = last tick meant n samples spanned (n-1)*period, and a single-sample
    // interval spanned zero seconds and vanished from the report entirely.
    do {
        let store = try Store(path: ":memory:")
        try store.migrate()
        let r = Reconciler(store: store, samplePeriod: 30)
        try r.ingest(mkSample(at: 1000, bundle: "com.google.Chrome", ctx: "a.com/x"))
        try r.ingest(mkSample(at: 1030, bundle: "com.apple.Notes", ctx: nil))
        let rows = try store.intervals(from: 0, to: 99999)
        if let first = rows.first(where: { $0.bundleId == "com.google.Chrome" }) {
            t.eq(first.endedAt, 1030,
                 "a closed interval extends to the moment the change was observed")
            t.expect(first.endedAt > first.startedAt,
                     "a single-sample interval has non-zero duration")
            t.eq(overlapSeconds(first, bucketStart: 0, bucketEnd: 99999), 30,
                 "a single-sample interval contributes one period of time")
        } else {
            t.expect(false, "closed interval was persisted")
        }
    } catch {
        t.expect(false, "interval duration test ran without throwing", "\(error)")
    }

    // IMPORTANT 2: a dev server URL has no dot in its host and must still be kept.
    t.eq(normalizeURL("http://localhost:3000/app"), "localhost/app",
         "a localhost dev URL is kept, not dropped")
    t.eq(normalizeURL("http://127.0.0.1:8080/x"), "127.0.0.1/x", "a loopback IP is kept")
    t.eq(normalizeURL("http://localhost"), "localhost/", "bare localhost gains a trailing slash")
    t.eq(normalizeURL("not a url"), nil, "a scheme-less phrase is still rejected")
    t.eq(normalizeURL("notaurl"), nil, "a scheme-less dotless word is still rejected")

    // IMPORTANT 3: stderr must not be left on an unread pipe.
    t.expect(BrowserAppleScriptProbe.runOsascript("return 1", hardTimeout: 3) == "1",
             "osascript round-trip works")
    t.eq(BrowserAppleScriptProbe.runOsascript(
            "repeat with i from 1 to 4000\nlog \"noise padding to fill a pipe buffer\"\nend repeat\nreturn \"done\"",
            hardTimeout: 5),
         "done",
         "a script writing far more than a pipe buffer to stderr still completes")

    // --- Gap fixes before first real use ---
    // GAP 1: a report for one day must not count time that fell outside it.
    let crossMidnight = [mkIv(86_400 - 1200, 86_400 + 1200,
                              bundle: "com.google.Chrome", ctx: "docs.google.com/d")]
    let clamped = slice(crossMidnight, bucketSecs: 1800, rules: reportRules,
                        from: 86_400, to: 86_400 * 2)
    t.eq(clamped.reduce(0) { $0 + $1.seconds }, 1200,
         "slices are clamped to the requested range, not the interval's full span")
    t.expect(clamped.allSatisfy { $0.bucketStart >= 86_400 },
             "no bucket falls before the requested day")
    let unclamped = slice(crossMidnight, bucketSecs: 1800, rules: reportRules)
    t.eq(unclamped.reduce(0) { $0 + $1.seconds }, 2400,
         "with no range given the whole interval is still counted")

    // GAP 5: the shipped defaults must not file YouTube in Chrome as work.
    if let defaultsText = try? String(contentsOfFile: repo + "/scripts/rules.toml.default",
                                     encoding: .utf8),
       let rsDef = try? parseRules(defaultsText, homeDirectory: "/Users/alex") {
        t.eq(classify(mkInterval(bundle: "com.google.Chrome", name: "Google Chrome",
                                 ctx: "www.youtube.com/watch"), with: rsDef),
             "fun", "default rules file YouTube in Chrome as fun, not work")
        t.eq(classify(mkInterval(bundle: "com.google.Chrome", name: "Google Chrome",
                                 ctx: "docs.google.com/document/d/1/edit"), with: rsDef),
             "work", "default rules still file a Google Doc in Chrome as work")
    } else {
        t.expect(false, "default rules parse for the YouTube check")
    }

    // GAP 6: media playing is recorded even while the app is actively in use.
    // The check was gated behind the idle threshold to save cost; measured at
    // 0.117 ms per call, that gate bought nothing and hid passive watching.
    let watchingActive = makeSample(now: 1000, previous: nil, config: cfg,
                                    probes: probes(edge, idle: 5, engaged: true,
                                                   ctx: .value(.url, "www.youtube.com/watch", title: nil)))
    t.eq(watchingActive.kind, Kind.app, "active tick with media playing stays kind app")
    t.eq(watchingActive.engaged, true, "media playing is recorded even with recent input")
    t.eq(watchingActive.hadInput, true, "recent input is still recorded alongside it")

    // GAP 7: a browser showing a local file reports a file:// URL, whose host is
    // empty — so the web-URL guard discarded it and every local PDF, download or
    // HTML file recorded no context at all. The path is also exactly what the
    // path rules need to match.
    t.eq(normalizeURL("file:///Users/alex/Downloads/report.pdf"),
         "/Users/alex/Downloads/report.pdf", "a file URL becomes a plain path")
    t.eq(normalizeURL("file:///Users/alex/Downloads/FY27%20Cash%20Plan.pdf"),
         "/Users/alex/Downloads/FY27 Cash Plan.pdf", "percent-encoding is decoded")
    t.eq(normalizeURL("file://localhost/Users/alex/x.pdf"), "/Users/alex/x.pdf",
         "a localhost authority is dropped from a file URL")
    t.eq(normalizeURL("file://"), nil, "an empty file URL is still rejected")
    t.eq(isFileURL("file:///x"), true, "isFileURL detects a file URL")
    t.eq(isFileURL("https://example.com/x"), false, "isFileURL rejects a web URL")

    // The kind must say file, not url, and a work path must still classify.
    t.eq(classifyContextValue(axURL: "file:///Users/alex/Desktop/Casey/Work/spec.pdf",
                              axDocument: nil, axTitle: "spec.pdf"),
         ContextResult.value(.file, "/Users/alex/Desktop/Casey/Work/spec.pdf", title: "spec.pdf"),
         "a browser-hosted local file is context kind file, not url")
    t.eq(classify(mkInterval(bundle: "com.google.Chrome", name: "Google Chrome",
                             ctx: "/Users/alex/Desktop/Casey/Work/spec.pdf"), with: rs),
         "work", "a work-directory PDF open in a browser classifies as work")

    // --- Finder folder probe ---
    // Finder is the one app Accessibility cannot describe: no AXURL, no document,
    // so the AX chain yields the window title — the bare folder name, which no
    // path rule can match. AppleScript supplies the POSIX path instead.
    t.eq(normalizeFolderPath("/Users/alex/Desktop/Casey/Projects/"),
         "/Users/alex/Desktop/Casey/Projects",
         "Finder's trailing slash is stripped so a folder matches a cwd spelling")
    t.eq(normalizeFolderPath("/Users/alex/Desktop/Casey/Projects"),
         "/Users/alex/Desktop/Casey/Projects", "a path with no trailing slash is unchanged")
    t.eq(normalizeFolderPath("/Users/alex///"), "/Users/alex", "repeated trailing slashes are stripped")
    t.eq(normalizeFolderPath("/"), "/", "the root path survives stripping")
    t.eq(normalizeFolderPath("  /Users/alex/  "), "/Users/alex", "surrounding whitespace is trimmed")
    t.eq(normalizeFolderPath(""), nil, "an empty answer is not a path")
    t.eq(normalizeFolderPath("Projects"), nil, "a bare folder name is rejected, not accepted as a path")

    t.eq(shouldUseFolderProbe(bundleId: "com.apple.finder"), true, "Finder uses the folder probe")
    t.eq(shouldUseFolderProbe(bundleId: "com.google.Chrome"), false, "a browser does not")
    t.eq(shouldUseFolderProbe(bundleId: nil), false, "a nil bundle id does not")

    // The composition: Finder is served by the folder probe, everything else by
    // the ordinary chain, and a Finder window with no folder degrades to it too.
    struct FakeFolder: FolderProbe {
        let path: String?
        func folder() -> String? { path }
    }
    struct DeniedProbe: ContextProbe {
        func context(for focus: FocusInfo) -> ContextResult { .denied }
    }
    let finderFocus = FocusInfo(bundleId: "com.apple.finder", appName: "Finder", pid: 9)
    let otherFocus = FocusInfo(bundleId: "com.apple.Notes", appName: "Notes", pid: 10)

    let withFolder = FinderContextProbe(primary: DeniedProbe(),
                                        folder: FakeFolder(path: "/Users/alex/Desktop/Casey/Work"))
    t.eq(withFolder.context(for: finderFocus),
         ContextResult.value(.folder, "/Users/alex/Desktop/Casey/Work", title: nil),
         "Finder yields a folder context from the folder probe")
    t.eq(withFolder.context(for: otherFocus), ContextResult.denied,
         "a non-Finder app is passed straight through to the ordinary chain")

    // Deliberate: the folder probe runs even when Accessibility is denied, because
    // a granted AX reading for Finder carries no more information than a denied
    // one. That is the opposite of the browser fallback, which must never paper
    // over `denied`.
    let noFolder = FinderContextProbe(primary: DeniedProbe(), folder: FakeFolder(path: nil))
    t.eq(noFolder.context(for: finderFocus), ContextResult.denied,
         "Finder with no folder behind the window reports what the chain said")

    // The script must bound its own Apple Event wait and must not raise on a
    // window that has no folder, or a Trash window would kill the tick.
    let finderScript = FinderFolderProbe.script(timeoutSeconds: 2)
    t.expect(finderScript.contains("with timeout of 2 seconds"), "Finder script bounds its Apple Event wait")
    t.expect(finderScript.contains("on error"), "Finder script swallows errors rather than raising")
    t.expect(finderScript.contains("count of Finder windows"),
             "Finder script handles having no folder window open")
    // Regression: `front window` picked up Get Info panels and the Go to Folder
    // sheet, whose `target` raises -1700 — so a real folder window sitting behind
    // one of those was silently reported as no folder at all.
    t.expect(finderScript.contains("front Finder window"),
             "Finder script targets the folder-window class, not any front window")
    t.expect(!finderScript.contains("front window as alias"),
             "Finder script does not ask a non-folder window for its target")

    // Classification end to end, with the rule shapes a folder actually needs.
    let finderToml = """
    default = "unclear"

    [[rule]]
    app = "com.apple.finder"
    context = "*/Casey/Work"
    category = "work"

    [[rule]]
    app = "com.apple.finder"
    context = "*/Casey/Work/*"
    category = "work"

    [[rule]]
    app = "com.apple.finder"
    context = "*/Casey/Projects"
    category = "pet-project"

    [[rule]]
    app = "com.apple.finder"
    context = "*/Casey/Projects/*"
    category = "pet-project"

    [[rule]]
    app = "com.apple.finder"
    category = "Misc"
    """
    let rsF = try! parseRules(finderToml, homeDirectory: "/Users/alex")
    func finderIv(_ ctx: String?) -> Interval {
        mkInterval(bundle: "com.apple.finder", name: "Finder", ctx: ctx)
    }
    t.eq(classify(finderIv("/Users/alex/Desktop/Casey/Work"), with: rsF), "work",
         "the Work folder itself classifies as work")
    t.eq(classify(finderIv("/Users/alex/Desktop/Casey/Work/docs"), with: rsF), "work",
         "a folder inside Work classifies as work")
    t.eq(classify(finderIv("/Users/alex/Desktop/Casey/Projects"), with: rsF), "pet-project",
         "the Projects folder itself classifies as pet-project")
    t.eq(classify(finderIv("/Users/alex/Desktop/Casey/Projects/stalker"), with: rsF), "pet-project",
         "a folder inside Projects classifies as pet-project")
    t.eq(classify(finderIv("/Users/alex/Desktop/Casey/Workspace"), with: rsF), "Misc",
         "a sibling of Work is not swept into work by the glob")
    t.eq(classify(finderIv("/Users/alex/Downloads"), with: rsF), "Misc",
         "any other folder falls to the tier-3 Finder rule")
    t.eq(classify(finderIv(nil), with: rsF), "Misc",
         "Finder with no folder captured still classifies, never unclear")

    // Live smoke: whether Finder has a window, and which, is state this suite must
    // not depend on. Only the shape of the answer is asserted.
    let liveFolder = FinderFolderProbe().folder()
    t.expect(liveFolder == nil || liveFolder!.hasPrefix("/"),
             "live Finder probe returns nil or an absolute path (got \(liveFolder ?? "nil"))")
    t.expect(liveFolder == nil || !liveFolder!.hasSuffix("/") || liveFolder! == "/",
             "live Finder probe never returns a trailing slash")

    // --- Subcategories: "parent/child" categories roll up ---
    // A category can be specific and countable at once. YouTube in Edge deserves
    // its own name, but the day's `fun` figure is a lie if that time sits in a
    // separate bucket beside it rather than inside it.
    t.eq(categoryParent("fun/Youtube"), "fun", "the parent is the half before the slash")
    t.eq(categoryLeaf("fun/Youtube"), "Youtube", "the child is the half after it")
    t.eq(categoryParent("fun"), "fun", "a plain category is its own parent")
    t.eq(categoryLeaf("fun"), nil, "a plain category has no child")
    t.eq(categoryLeaf("fun/"), nil, "a trailing slash names no child")
    t.eq(categoryParent("fun/"), "fun", "a trailing slash still yields the parent")
    // A leading slash would otherwise produce an empty parent that swallows every
    // such category into one nameless bucket.
    t.eq(categoryParent("/Youtube"), "/Youtube", "an empty parent is refused; the name stands whole")
    t.eq(categoryLeaf("/Youtube"), nil, "an empty parent means there is no child either")

    let subToml = """
    default = "unclear"

    [[rule]]
    app = "com.microsoft.edgemac"
    context = "*youtube.com/*"
    category = "fun/Youtube"

    [[rule]]
    app = "com.microsoft.edgemac"
    category = "fun"
    """
    let subRules = try! parseRules(subToml, homeDirectory: "/Users/alex")
    let subIvs = [
        mkIv(0, 600, bundle: "com.microsoft.edgemac", ctx: "www.youtube.com/watch"),
        mkIv(600, 900, bundle: "com.microsoft.edgemac", ctx: "news.bbc.co.uk/"),
    ]
    let subTot = totals(slice(subIvs, bucketSecs: 1800, rules: subRules))
    t.eq(subTot.count, 1, "a subcategory does not create a second top-level category")
    t.eq(subTot.first?.category, "fun", "the total is filed under the parent")
    t.eq(subTot.first?.seconds, 900, "the parent total includes its subcategory's time")
    t.eq(subTot.first?.subcategories.count, 1, "the subcategory is carried on the parent")
    t.eq(subTot.first?.subcategories.first?.name, "Youtube", "the subcategory keeps its own name")
    t.eq(subTot.first?.subcategories.first?.seconds, 600, "the subcategory keeps its own total")
    t.eq(subTot.first?.subcategories.first?.byContext.first?.label, "www.youtube.com/watch",
         "the subcategory carries its own context breakdown")
    // The parent's own context list must not repeat the child's, or the breakdown
    // would double-count what the eye reads as a sum.
    t.eq(subTot.first?.byContext.count, 1, "the parent lists only time filed directly against it")
    t.eq(subTot.first?.byContext.first?.label, "news.bbc.co.uk/", "and that one is the non-YouTube context")

    let subText = renderDay(subIvs, bucketSecs: 1800, rules: subRules,
                            timeZone: TimeZone(identifier: "UTC")!, from: 0, to: 86_400)
    t.expect(subText.contains("\n  fun"), "the rendered parent appears at top level")
    t.expect(subText.contains("\n    Youtube"), "the subcategory is indented under it")
    // A lone context under a subcategory restates the subtotal above it, so it is
    // dropped rather than printed twice.
    // Scoped to the indented totals line: the bucket timeline above legitimately
    // names the same context, so a bare substring check would always fail.
    t.expect(!subText.contains("\n      www.youtube.com/watch"),
             "a subcategory's only context is not printed, being a restatement of its total")
    // But the parent's lone direct context IS kept here: with a subcategory present
    // it accounts for part of the total, not all of it, so dropping it would leave
    // the arithmetic unexplained.
    t.expect(subText.contains("news.bbc.co.uk/"),
             "a parent with subcategories still lists its own single context")

    // Two contexts under a subcategory do earn their lines.
    let twoSubIvs = [
        mkIv(0, 600, bundle: "com.microsoft.edgemac", ctx: "www.youtube.com/watch"),
        mkIv(600, 900, bundle: "com.microsoft.edgemac", ctx: "www.youtube.com/playlist"),
    ]
    let twoSubText = renderDay(twoSubIvs, bucketSecs: 1800, rules: subRules,
                               timeZone: TimeZone(identifier: "UTC")!, from: 0, to: 86_400)
    t.expect(twoSubText.contains("\n      www.youtube.com/watch")
             && twoSubText.contains("\n      www.youtube.com/playlist"),
             "a subcategory with two contexts lists both")

    // A plain category whose single context is the whole of it drops that line too.
    let loneIvs = [mkIv(0, 600, bundle: nil, ctx: nil, kind: .locked)]
    let loneText = renderDay(loneIvs, bucketSecs: 1800, rules: subRules,
                             timeZone: TimeZone(identifier: "UTC")!, from: 0, to: 86_400)
    t.expect(loneText.contains("locked"), "the category itself is still reported")
    t.expect(!loneText.contains("(unknown)"),
             "a category's only context is not printed under it")
    t.expect(!subText.contains("\n  Youtube"),
             "the subcategory never appears as a top-level category of its own")

    formatTests(t)
    engagementShareTests(t)
    dayRenderTests(t)
    dayLayoutTests(t)
    weekRangeTests(t)
    weekRenderTests(t)
    widthAndColorTests(t)
    reportArgsTests(t)
    idleCountsTests(t)
    spanTests(t)
    activityConfigTests(t)
    notesFileTests(t)
    resolutionTests(t)
    overlapAttributionTests(t)
    dayViewWithNotesTests(t)
    weekViewWithNotesTests(t)

    return t.summary()
}

exit(run())
