import Foundation

/// One launchd agent `setup` installs.
public struct AgentSpec: Equatable, Sendable {
    public let label: String
    public let templateName: String

    public init(label: String, templateName: String) {
        self.label = label
        self.templateName = templateName
    }
}

/// Every agent `setup` installs.
///
/// A list rather than named labels, so the browser report's agent appends one entry
/// here and changes nothing else. Spec §9.
public let stalkerAgents: [AgentSpec] = [
    AgentSpec(label: "stalker.sample", templateName: "stalker.sample.plist"),
]

/// A file's wanted contents, and whether they differ from what was there.
///
/// `changed` is what keeps `setup` idempotent: a caller writes only when it is true,
/// so re-running the command neither rewrites nor duplicates anything.
public struct FileEdit: Equatable, Sendable {
    public let contents: String
    public let changed: Bool

    public init(contents: String, changed: Bool) {
        self.contents = contents
        self.changed = changed
    }
}

private let hookComment = "# stalker courier hook"
/// The file a hook sources, wherever it currently lives.
private let hookMarker = "stalker.zsh"

/// Is this line a hook, as opposed to a line that merely names the file?
///
/// Only a `source` (or `.`) line counts. Matching the bare filename was wrong twice
/// over: it ate the `if` of a `[[ -f … ]]`-guarded hook and left a dangling `fi`,
/// which is a zsh parse error that stops zsh reading the rest of the file, so every
/// line below it silently stopped applying. And it deleted innocent lines like
/// `alias edithook='vim ~/dotfiles/stalker.zsh'`.
private func isHookSourceLine(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.contains(hookMarker) else { return false }
    return t.hasPrefix("source ") || t.hasPrefix(". ")
}

/// Lines that name the hook file but are not hook `source` lines.
///
/// Reported rather than edited. A guard left wrapped around a hook we removed now
/// guards nothing, and a person should hear that from us instead of discovering it.
public func foreignHookLines(_ zshrc: String) -> [String] {
    zshrc.components(separatedBy: "\n")
        .filter { $0.contains(hookMarker) && !isHookSourceLine($0) }
}

/// `~/.zshrc` with the courier hook sourcing `hookPath`.
///
/// An existing hook is recognised by the file it sources rather than by the exact
/// line, so a path that has moved — from a clone into Homebrew's share directory —
/// is corrected in place. Appending beside it would leave two hooks, and the stale
/// one would fail silently on every prompt. A nil `zshrc` means no file yet, which is
/// ordinary on a Mac that has never been customised.
public func hookEdit(zshrc: String?, hookPath: String) -> FileEdit {
    let block = "\n\(hookComment)\n" + "source \"\(hookPath)\"" + "\n"
    guard let zshrc, !zshrc.isEmpty else {
        return FileEdit(contents: block, changed: true)
    }
    // Strip every hook first, then write exactly one. Fixing only the first would
    // leave a second behind on a file the old installer had already appended to,
    // and a hook pointing at a file that no longer exists makes zsh complain on
    // every new shell.
    let desired = hookRemoval(zshrc).contents + block
    return FileEdit(contents: desired, changed: desired != zshrc)
}

/// `~/.zshrc` with the courier hook taken out, comment and all.
///
/// Leaving the comment behind would accumulate a dead marker on every install and
/// uninstall cycle, which is the kind of litter that makes people distrust an
/// uninstaller.
public func hookRemoval(_ zshrc: String) -> FileEdit {
    var lines = zshrc.components(separatedBy: "\n")
    // Every hook, not just the first. The old installer matched on the whole line,
    // so a clone that moved made it append a second one rather than correct the
    // first, and anyone migrating from that state has two.
    var removedAny = false
    while let i = lines.firstIndex(where: isHookSourceLine) {
        var from = i
        if from > 0, lines[from - 1] == hookComment { from -= 1 }
        if from > 0, lines[from - 1].isEmpty { from -= 1 }
        lines.removeSubrange(from...i)
        removedAny = true
    }
    guard removedAny else { return FileEdit(contents: zshrc, changed: false) }
    return FileEdit(contents: lines.joined(separator: "\n"), changed: true)
}

/// A launchd plist with the binary's real path filled in.
public func renderPlist(template: String, binaryPath: String) -> String {
    template.replacingOccurrences(of: "__BINARY__", with: binaryPath)
}

/// Where the support files might be, in the order they are tried.
///
/// Two layouts: installed by Homebrew, where they sit in the formula's share
/// directory beside `bin`; and run from a clone, where they are in the repository's
/// `scripts`. The clone needs two depths, because SwiftPM's real output directory is
/// `.build/<target-triple>/release` and `.build/release` is only a symlink to it —
/// which path a running binary reports depends on how it was launched.
public func supportDirCandidates(executablePath: String) -> [String] {
    let execDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
    return [
        execDir.appendingPathComponent("../share/stalker").standardized.path,
        execDir.appendingPathComponent("../../scripts").standardized.path,
        execDir.appendingPathComponent("../../../scripts").standardized.path,
    ]
}

/// The support directory, or nil when none of the candidates is there.
///
/// Nil rather than a best guess, so the caller can fail naming every path it tried.
/// Silently skipping the rules file and the shell hook would leave an install that
/// looks finished and records nothing useful.
public func resolveSupportDir(executablePath: String, override: String?,
                              exists: (String) -> Bool) -> String? {
    if let override { return override }
    return supportDirCandidates(executablePath: executablePath).first(where: exists)
}

/// Whether this binary is a build artefact rather than an installed program.
///
/// SwiftPM rebuilds and relinks anything under `.build` constantly, and a relink
/// drops the code signature that TCC grants depend on. `swift package clean` deletes
/// it outright. So a launchd agent pointed at such a path degrades silently: the
/// agent keeps being registered, and either stops finding its binary or finds one
/// whose signature no longer satisfies the grant.
public func isTransientBuildPath(_ path: String) -> Bool {
    path.components(separatedBy: "/").contains(".build")
}

/// The binary a launchd plist actually runs, read from `ProgramArguments[0]`.
///
/// `doctor` has to audit this rather than its own `Bundle.main`. Once a Homebrew
/// install sits beside an older `~/.local/bin/stalker`, those are different files:
/// whichever PATH resolves first is the one running `doctor`, while the plist may
/// point at the other. Auditing the wrong one reports `ok` for drift it never looked
/// at. Textual rather than `PropertyListSerialization`, matching how the rest of this
/// package reads the formats it owns.
public func agentProgramPath(plist: String) -> String? {
    guard let keyEnd = plist.range(of: "<key>ProgramArguments</key>")?.upperBound,
          let open = plist.range(of: "<string>", range: keyEnd..<plist.endIndex)?.upperBound,
          let close = plist.range(of: "</string>", range: open..<plist.endIndex)?.lowerBound
    else { return nil }
    let path = plist[open..<close].trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
}

/// Pull a global `--home PATH` out of the argument list.
///
/// Every path this program touches derives from one home directory, read from
/// `homeDirectoryForCurrentUser`, which ignores the `HOME` environment variable. So
/// before this there was no way to run `setup`, `uninstall` or `note` against
/// anything but the real one, and the only way to verify them was to let them write
/// to real data. That is not hypothetical: it put three junk entries in a real notes
/// file during development.
///
/// Returned with the flag stripped, so the command parsers never see it. A `--home`
/// with no value is left in place on purpose, so `parseArgs` refuses it rather than
/// silently ignoring a typo.
public func extractHomeOverride(_ args: [String]) -> (args: [String], home: String?) {
    guard let i = args.firstIndex(of: "--home"), i + 1 < args.count else {
        return (args, nil)
    }
    var rest = args
    let value = rest[i + 1]
    rest.removeSubrange(i...(i + 1))
    return (rest, value)
}

/// Rewrite a Homebrew Cellar path to the stable `opt` path that points at it.
///
/// `…/Cellar/stalker/0.1.0/bin/stalker` carries the version, and `brew cleanup`
/// deletes old version directories. A launchd agent pointed there stops finding its
/// binary, and a `~/.zshrc` hook sourced from alongside it errors on every new
/// terminal. `…/opt/stalker/bin/stalker` is a symlink Homebrew re-points on every
/// upgrade, so it survives both.
///
/// This is the path spec §10 names as the primary specification, and reaching it by
/// decision rather than by luck is also what makes §10's eventual experiment answer
/// the question it actually poses. `Bundle.main.executableURL` does not resolve
/// symlinks — verified — so an invocation through a Cellar path arrives here as one.
public func canonicalBrewPath(_ path: String, formula: String = "stalker") -> String {
    var parts = path.components(separatedBy: "/")
    guard let i = parts.firstIndex(of: "Cellar"), i + 2 < parts.count else { return path }
    // Replace "Cellar/<formula>/<version>" with "opt/<formula>", keeping the rest.
    parts.replaceSubrange(i...(i + 2), with: ["opt", parts[i + 1]])
    return parts.joined(separator: "/")
}

/// The path to sign and to point the agent at: canonical when it is reachable, the
/// original when it is not.
///
/// `canonicalBrewPath` rewrites a Cellar path to the `opt` symlink beside it, which
/// Homebrew creates on install. An unlinked formula has no such symlink, and in that
/// state signing the canonical path fails and `setup` would refuse to run at all.
/// Falling back costs only the version-pinning the rewrite exists to avoid, which is
/// exactly where we would have been without it.
public func stableBinaryPath(_ path: String, exists: (String) -> Bool) -> String {
    let canonical = canonicalBrewPath(path)
    guard canonical != path else { return path }
    return exists(canonical) ? canonical : path
}
