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
    /// Does time with no input still count as this category?
    ///
    /// Off by default, because no input normally means you walked away. A meeting is
    /// the exception: you listen without touching anything, and the engagement probe
    /// cannot see it. Chrome takes no named "Playing audio" assertion the way Edge
    /// does, and for a PWA the audio assertion is owned by `coreaudiod` with the real
    /// process buried in a nested field. So a Meet call is indistinguishable from an
    /// abandoned desk, and the rule file has to say which it is.
    public let idleCounts: Bool

    public init(app: String?, appName: String?, context: String?, category: String,
                idleCounts: Bool = false) {
        self.app = app; self.appName = appName; self.context = context; self.category = category
        self.idleCounts = idleCounts
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
    /// Activities logged by hand with `stalker note`, in declared order so an error
    /// message can list them the way they were written.
    public let activities: [String]
    /// Of those, the ones that are rest rather than something chosen. Kept out of the
    /// main list, because seven hours of sleep in the same denominator makes every
    /// other row look like a rounding error.
    public let rest: Set<String>

    public init(defaultCategory: String, rules: [Rule],
                activities: [String] = [], rest: Set<String> = []) {
        self.defaultCategory = defaultCategory
        self.rules = rules
        self.activities = activities
        self.rest = rest
    }
}

public enum RulesError: Error, Equatable, CustomStringConvertible {
    case syntax(line: Int, text: String)
    case unknownKey(line: Int, key: String)
    case missingCategory(line: Int)
    case keyOutsideRule(line: Int, key: String)
    case ruleMatchesEverything(line: Int)
    case notABoolean(line: Int, key: String)
    case activitySlash(line: Int, name: String)
    case emptyActivityName(line: Int)
    case duplicateActivity(line: Int, name: String)
    case restNotDeclared(line: Int, name: String)
    case emptyRuleSet

    public var description: String {
        switch self {
        case .syntax(let l, let t):         return "rules.toml line \(l): cannot parse \"\(t)\""
        case .unknownKey(let l, let k):     return "rules.toml line \(l): unknown key \"\(k)\" (expected app, app_name, context, category, or idle_counts)"
        case .missingCategory(let l):       return "rules.toml line \(l): this [[rule]] has no category"
        case .keyOutsideRule(let l, let k): return "rules.toml line \(l): \"\(k)\" appears before any [[rule]] header"
        case .ruleMatchesEverything(let l): return "rules.toml line \(l): this [[rule]] has no app, app_name, or context, so it would match everything"
        case .notABoolean(let l, let k):    return "rules.toml line \(l): \"\(k)\" expects true or false, unquoted"
        case .activitySlash(let l, let n):  return "rules.toml line \(l): activity \"\(n)\" cannot contain \"/\" — a slash reads as a subcategory, so it would split into two rows. Use a hyphen."
        case .emptyActivityName(let l):     return "rules.toml line \(l): empty activity name (a stray comma?)"
        case .duplicateActivity(let l, let n): return "rules.toml line \(l): activity \"\(n)\" is listed twice"
        case .restNotDeclared(let l, let n):   return "rules.toml line \(l): rest names \"\(n)\", which is not in activities"
        case .emptyRuleSet:                 return "rules.toml contains no [[rule]] blocks"
        }
    }
}

/// Parse the supported TOML subset. Any deviation throws rather than being
/// skipped: a silently ignored typo would void a day of reporting without
/// any visible symptom. Spec §9.
public func parseRules(_ text: String, homeDirectory: String) throws -> RuleSet {
    var defaultCategory = "unclear"
    var rules: [Rule] = []
    var activities: [String] = []
    var restNames: [String] = []
    var restLine = 0

    var app: String?, appName: String?, context: String?, category: String?
    var idleCounts = false
    var ruleStartLine = 0
    var inRule = false

    func flush() throws {
        guard inRule else { return }
        guard let cat = category else { throw RulesError.missingCategory(line: ruleStartLine) }
        guard app != nil || appName != nil || context != nil else {
            throw RulesError.ruleMatchesEverything(line: ruleStartLine)
        }
        rules.append(Rule(app: app, appName: appName, context: context, category: cat,
                          idleCounts: idleCounts))
        app = nil; appName = nil; context = nil; category = nil; idleCounts = false
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
        let raw = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

        // idle_counts is the one boolean key, and TOML booleans are bare words. It is
        // handled before the quoted-string check so that a quoted "true" is refused as
        // the wrong type rather than accepted as a string spelling a boolean.
        if key == "idle_counts" {
            guard inRule else { throw RulesError.keyOutsideRule(line: lineNo, key: key) }
            switch raw {
            case "true":  idleCounts = true
            case "false": idleCounts = false
            default:      throw RulesError.notABoolean(line: lineNo, key: key)
            }
            continue
        }

        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else {
            throw RulesError.syntax(line: lineNo, text: line)
        }
        let value = String(raw.dropFirst().dropLast())

        if !inRule {
            switch key {
            case "default":
                defaultCategory = value
            case "activities":
                activities = try activityNames(value, line: lineNo)
            case "rest":
                restNames = try activityNames(value, line: lineNo)
                restLine = lineNo
            default:
                throw RulesError.keyOutsideRule(line: lineNo, key: key)
            }
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

    // Checked after both lines are read, so the two keys may appear in either order.
    // A rest entry that names nothing is certainly a typo, and ignoring it would
    // quietly put sleep back among the percentages.
    for name in restNames where !activities.contains(name) {
        throw RulesError.restNotDeclared(line: restLine, name: name)
    }

    // Stable sort by tier: most specific first. A stable sort keeps file order
    // within a tier, so rules cannot be broken by being written in the wrong
    // order — the usual footgun of first-match-wins lists. Spec §7.2.
    let sorted = rules.enumerated()
        .sorted { ($0.element.tier, $0.offset) < ($1.element.tier, $1.offset) }
        .map(\.element)

    return RuleSet(defaultCategory: defaultCategory, rules: sorted,
                   activities: activities, rest: Set(restNames))
}

/// Split a comma-separated activity list, trimmed and lowercased.
///
/// Lowercasing means "Workout" in the config and "workout" in a note are the same
/// activity. Every mistake here throws: a silently dropped name would make the note
/// that used it fail to classify, days later and with no obvious cause.
func activityNames(_ value: String, line: Int) throws -> [String] {
    var out: [String] = []
    for raw in value.split(separator: ",", omittingEmptySubsequences: false) {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { throw RulesError.emptyActivityName(line: line) }
        // A slash would be read as a subcategory, the way work/Meeting puts Meeting
        // inside work, so one activity would become two rows.
        guard !name.contains("/") else { throw RulesError.activitySlash(line: line, name: name) }
        guard !out.contains(name) else { throw RulesError.duplicateActivity(line: line, name: name) }
        out.append(name)
    }
    return out
}

/// A rule written `~/Work/*` must match the absolute `/Users/alex/Work/...`
/// that the courier records, so the tilde is expanded at parse time.
func expandTilde(_ glob: String, home: String) -> String {
    if glob == "~" { return home }
    if glob.hasPrefix("~/") { return home + String(glob.dropFirst(1)) }
    return glob
}
