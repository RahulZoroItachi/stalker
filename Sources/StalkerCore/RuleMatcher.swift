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

/// The rule that applies to this interval, if any. First match in tier order wins.
///
/// Exposed separately from `classify` because a caller sometimes needs the rule
/// itself rather than only its category — `idle_counts` is a property of the rule,
/// and the category alone cannot carry it.
public func matchingRule(_ iv: Interval, with rs: RuleSet) -> Rule? {
    rs.rules.first { matches($0, iv) }
}

/// Category for an interval. First match in tier order wins.
///
/// Classification happens here, at read time, never at collection time — which
/// is why a rule added in March re-classifies January. Spec §7.
public func classify(_ iv: Interval, with rs: RuleSet) -> String {
    matchingRule(iv, with: rs)?.category ?? rs.defaultCategory
}
