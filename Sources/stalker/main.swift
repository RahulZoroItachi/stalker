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

        // Notes are re-read on every report, which is what makes a correction to the
        // file correct the history. A missing file is simply no notes.
        let notes = try parseNotes(try readNotes(path: paths.notesPath),
                                   activities: Set(rules.activities), timeZone: tz)

        let ivs = try store.intervals(from: range.from, to: range.to)
        let table = week
            ? renderWeek(ivs, notes: notes, bucketSecs: bucketSeconds, rules: rules,
                        timeZone: tz, from: range.from, to: range.to, options: options)
            : renderDay(ivs, notes: notes, bucketSecs: bucketSeconds, rules: rules,
                       timeZone: tz, from: range.from, to: range.to, options: options)

        // The grid is a second view of the same slices rather than a section of either
        // table, so it is composed here instead of inside the renderers. Both tables stay
        // exactly as they were, and the grid keeps the one rule they do not share: with
        // colour off it has nothing to say, so it says that instead of drawing 144
        // identical characters. Its width is fixed at 144 blocks, so the terminal clamp
        // that governs the tables does not apply to it.
        let grid = renderGrid(ivs, notes: notes, rules: rules, timeZone: tz,
                              from: range.from, to: range.to, options: options)
        let report = grid.isEmpty ? table : table + "\n\n" + grid

        // Banded as one block rather than inside each renderer, so a run reads as a
        // single highlighted card: the one edge nothing printed between two shell
        // prompts can draw for itself.
        print(band(report, width: options.width, enabled: options.color))
        return 0
    } catch {
        FileHandle.standardError.write("report failed: \(error)\n".data(using: .utf8)!)
        return 1
    }
}

func runNote(_ action: NoteAction) -> Int32 {
    guard let rules = loadRules() else { return 1 }
    let tz = TimeZone.current
    let now = Int(Date().timeIntervalSince1970)

    func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        return 2
    }

    do {
        switch action {
        case .list(let date):
            let text = try readNotes(path: paths.notesPath)
            let notes = try parseNotes(text, activities: Set(rules.activities), timeZone: tz)
            let wanted = date ?? todayString(now: now, timeZone: tz)
            guard let window = startOfDay(wanted, timeZone: tz) else {
                return fail("\"\(wanted)\" is not a date in YYYY-MM-DD form")
            }
            // A block is listed for the day it starts on, which is the day it was typed
            // against, so a night's sleep appears under the evening it began.
            let from = Int(window.timeIntervalSince1970)
            let shown = notes.filter { $0.span.start >= from && $0.span.start < from + 86_400 }
            if shown.isEmpty {
                print("no blocks logged for \(wanted)")
                return 0
            }
            for note in shown {
                print("\(wanted)  \(clockTime(note.span.start, tz))-\(clockTime(note.span.end, tz))"
                      + "  \(note.activity)   (\(formatDuration(note.span.seconds)))")
            }
            return 0

        case .add(let range, let activity, let date):
            guard !rules.activities.isEmpty else {
                return fail("no activities are declared. Add a line to \(paths.rulesPath):\n"
                            + "  activities = \"sleep, travel, workout\"")
            }
            let day = date ?? todayString(now: now, timeZone: tz)
            let halves = range.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard halves.count == 2 else {
                return fail("\"\(range)\" is not a range. Expected HH:MM-HH:MM, as in 01:30-08:30.")
            }
            let line = noteLine(date: day, from: halves[0], to: halves[1],
                                activity: activity.lowercased())

            // Validated by the same parser the report uses, so the command can never
            // append a line the next report would refuse to read.
            let parsed: [Note]
            do {
                parsed = try parseNotes(line, activities: Set(rules.activities), timeZone: tz)
            } catch {
                return fail("\(error)")
            }
            guard let note = parsed.first else { return fail("nothing to log") }

            try appendNote(line, path: paths.notesPath)
            let crosses = note.span.end - note.span.start > 0
                && clockTime(note.span.start, tz) >= clockTime(note.span.end, tz)
            print("noted: \(note.activity)  \(day)  \(range)"
                  + "  (\(formatDuration(note.span.seconds))\(crosses ? ", crosses midnight" : ""))")
            return 0
        }
    } catch {
        FileHandle.standardError.write("note failed: \(error)\n".data(using: .utf8)!)
        return 1
    }
}

func runDoctor() -> Int32 {
    var problems = 0
    func stamp(_ unix: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
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

    // Accessibility, judged by what the agent recorded rather than by a live call.
    // A live call answers for whatever launched this process, so typing
    // `stalker doctor` in a terminal asks about the terminal. Spec §5.
    let nowSecs = Int(Date().timeIntervalSince1970)
    let recent = (try? Store(path: paths.dbPath).intervals(from: nowSecs - 86_400, to: nowSecs)) ?? []
    switch accessibilityVerdict(recent, now: nowSecs) {
    case .granted(let at):
        check(true, "Accessibility granted (agent recorded context at \(stamp(at)))")
    case .denied(let at):
        check(false, "Accessibility granted",
              "the agent recorded a refusal at \(stamp(at)). "
              + "System Settings → Privacy & Security → Accessibility, add this binary")
    case .notObserved:
        // Not a problem. A fresh install has simply not sampled anything yet, and a
        // FAIL here would read as broken to someone who just granted the permission.
        print("  ok   Accessibility not yet observed")
        print("       → nothing recorded in the last 24h either way; re-run after the")
        print("         agent has sampled a window with in-app context")
    }

    // Reported, never counted. This is the reading that confuses people, so it is
    // printed with its explanation instead of left to be rediscovered.
    let trusted = AXIsProcessTrusted()
    print("  ok   Accessibility for this process: \(trusted ? "trusted" : "not trusted")")
    if !trusted {
        print("       → expected when launched from a shell: the answer describes the")
        print("         launching process, not this binary. The check above is the real one.")
    }

    // The AX latency the spec leaves open as item 1.
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
  stalker note       log a block of time the laptop could not see
  stalker doctor     verify permissions and setup
  stalker --version  print the version

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
case .note(let a):         status = runNote(a)
case .doctor:              status = runDoctor()
case .version:
    print("stalker \(stalkerVersion)")
    status = 0
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
