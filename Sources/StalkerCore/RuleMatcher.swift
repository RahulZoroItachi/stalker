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
