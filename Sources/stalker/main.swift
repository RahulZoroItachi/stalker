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
           context: FinderContextProbe(
               primary: FallbackContextProbe(primary: AccessibilityContextProbe(),
                                             fallback: BrowserAppleScriptProbe(),
                                             browserBundleIds: browserBundleIds),
               folder: FinderFolderProbe()),
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

func runReport(_ req: ReportRequest) -> Int32 {
    guard let rules = loadRules() else { return 1 }
    do {
        let store = try Store(path: paths.dbPath)
        try store.migrate()
        let tz = TimeZone.current
        let now = Int(Date().timeIntervalSince1970)
        // An explicit --width is clamped too: the layout cannot hold its columns below
        // 80, and honouring a nonsense value would only produce a broken table.
        let options = RenderOptions(width: clampWidth(req.width ?? detectedWidth()),
                                    color: req.color ?? stdoutIsTerminal(),
                                    home: home)

        let range: (from: Int, to: Int)
        let week: Bool
        switch req.span {
        case .day:
            range = dayRange(req.date, now: now, timeZone: tz)
            week = false
        case .week:
            // Clamped to the end of today, so a week in progress does not print four
            // empty rows for days that have not happened.
            let full = weekRange(req.date, now: now, timeZone: tz)
            range = (full.from, min(full.to, sinceRange(days: 1, now: now, timeZone: tz).to))
            week = true
        case .since(let days):
            range = sinceRange(days: days, now: now, timeZone: tz)
            week = true
        }

        let ivs = try store.intervals(from: range.from, to: range.to)
        let render = week ? renderWeek : renderDay
        print(render(ivs, bucketSeconds, rules, tz, range.from, range.to, options))
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

    // Automation to Finder is a separate grant from Accessibility, and the first
    // request for it prompts. Under launchd there is nobody to answer the prompt,
    // so it has to be triggered once from a terminal — which is what this does.
    // Finder showing only the desktop legitimately has no folder, so a nil here
    // is reported rather than failed.
    if let folder = FinderFolderProbe().folder() {
        print("  ok   Finder folder probe: \(folder)")
    } else {
        print("  ok   Finder folder probe returned nothing")
        print("       → expected if Finder has no window open; otherwise grant")
        print("         System Settings → Privacy & Security → Automation → Finder")
    }

    // An ad-hoc signature is why a granted Accessibility permission stops working
    // for no visible reason. Its designated requirement is the code hash, so TCC
    // pins the grant to one exact build; the next build is a different program to
    // it, while the entry in System Settings still reads as enabled. A certificate
    // makes the requirement "identifier + leaf cert", which survives rebuilds.
    if let exe = Bundle.main.executableURL?.path {
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["-d", "-r-", exe]
        let pipe = Pipe()
        // codesign writes the requirement to stdout and its banner to stderr.
        cs.standardOutput = pipe
        cs.standardError = FileHandle.nullDevice
        try? cs.run()
        let dr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8) ?? ""
        cs.waitUntilExit()
        check(!dr.contains("cdhash"), "signing identity survives a rebuild",
              "ad-hoc signed: every build invalidates the Accessibility grant while "
              + "System Settings still shows it enabled. See scripts/install.sh")
    }

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

let usage = """
stalker — local activity tracker

  stalker sample     take one observation (launchd calls this)
  stalker report     30-minute report, default today
  stalker doctor     verify permissions and setup

report options:
  --date YYYY-MM-DD  the day to report, or the week containing it
  --week             one row per day for the calendar week, Monday first
  --since N          one row per day for the last N days, today included
  --width N          lay out for N columns (80-160, default: the terminal's)
  --no-color         plain text, as when piping to a file

Time away from the machine is reported separately from activity, so the
percentages describe what you did rather than how long the day was.
"""

let status: Int32
switch parseArgs(Array(CommandLine.arguments.dropFirst())) {
case .sample:              status = runSample()
case .report(let r):       status = runReport(r)
case .doctor:              status = runDoctor()
case .help:
    print(usage)
    status = 0
case .usageError:
    // Usage goes to stderr and the status is non-zero, so a mistyped flag in a script
    // fails loudly instead of producing a plausible report for the wrong range.
    FileHandle.standardError.write((usage + "\n").data(using: .utf8)!)
    status = 2
}
exit(status)
