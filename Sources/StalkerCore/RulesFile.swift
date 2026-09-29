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
        case .syntax(let l, let t):         return "rules.toml line \(l): cannot parse \"\(t)\""
        case .unknownKey(let l, let k):     return "rules.toml line \(l): unknown key \"\(k)\" (expected app, app_name, context, or category)"
        case .missingCategory(let l):       return "rules.toml line \(l): this [[rule]] has no category"
        case .keyOutsideRule(let l, let k): return "rules.toml line \(l): \"\(k)\" appears before any [[rule]] header"
        case .ruleMatchesEverything(let l): return "rules.toml line \(l): this [[rule]] has no app, app_name, or context, so it would match everything"
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
