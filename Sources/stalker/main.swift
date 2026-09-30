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
           context: FallbackContextProbe(primary: AccessibilityContextProbe(),
                                         fallback: BrowserAppleScriptProbe(),
                                         browserBundleIds: browserBundleIds),
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
        print(render(ivs, bucketSecs: bucketSeconds, rules: rules, timeZone: tz,
                     from: range.from, to: range.to))
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
