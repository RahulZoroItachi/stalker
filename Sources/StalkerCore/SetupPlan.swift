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
/// Any line mentioning this is the hook, wherever it currently points.
private let hookMarker = "stalker.zsh"

/// `~/.zshrc` with the courier hook sourcing `hookPath`.
///
/// An existing hook is recognised by the file it sources rather than by the exact
/// line, so a path that has moved — from a clone into Homebrew's share directory —
/// is corrected in place. Appending beside it would leave two hooks, and the stale
/// one would fail silently on every prompt. A nil `zshrc` means no file yet, which is
/// ordinary on a Mac that has never been customised.
public func hookEdit(zshrc: String?, hookPath: String) -> FileEdit {
    let wanted = "source \"\(hookPath)\""
    guard let zshrc, !zshrc.isEmpty else {
        return FileEdit(contents: "\n\(hookComment)\n\(wanted)\n", changed: true)
    }

    var lines = zshrc.components(separatedBy: "\n")
    guard let i = lines.firstIndex(where: { $0.contains(hookMarker) }) else {
        return FileEdit(contents: zshrc + "\n\(hookComment)\n\(wanted)\n", changed: true)
    }
    if lines[i] == wanted { return FileEdit(contents: zshrc, changed: false) }
    lines[i] = wanted
    return FileEdit(contents: lines.joined(separator: "\n"), changed: true)
}

/// `~/.zshrc` with the courier hook taken out, comment and all.
///
/// Leaving the comment behind would accumulate a dead marker on every install and
/// uninstall cycle, which is the kind of litter that makes people distrust an
/// uninstaller.
public func hookRemoval(_ zshrc: String) -> FileEdit {
    var lines = zshrc.components(separatedBy: "\n")
    guard let i = lines.firstIndex(where: { $0.contains(hookMarker) }) else {
        return FileEdit(contents: zshrc, changed: false)
    }
    var from = i
    if from > 0, lines[from - 1] == hookComment { from -= 1 }
    if from > 0, lines[from - 1].isEmpty { from -= 1 }
    lines.removeSubrange(from...i)
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
