import Foundation
import StalkerCore

/// Tests for the decisions `stalker setup` makes, kept apart from the side effects
/// that carry them out. The `Process` calls that sign the binary and talk to launchd
/// live in the executable target, which no test can import, so everything decidable
/// is pulled in here.
@MainActor func setupTests(_ t: T) {
    // Review Focus 1: a friend's Mac may have no .zshrc at all.
    let fresh = hookEdit(zshrc: nil, hookPath: "/opt/share/stalker.zsh")
    t.expect(fresh.changed, "a missing .zshrc is created")
    t.expect(fresh.contents.contains("source \"/opt/share/stalker.zsh\""), "and sources the hook")

    // Review Focus 3: setup is idempotent.
    let again = hookEdit(zshrc: fresh.contents, hookPath: "/opt/share/stalker.zsh")
    t.expect(!again.changed, "an already-correct .zshrc is left alone")
    t.eq(again.contents, fresh.contents, "byte for byte")

    // Review Focus 2: an old line pointing into a clone is corrected, not duplicated.
    let stale = "# stalker courier hook\nsource \"/Users/someone/code/stalker/scripts/stalker.zsh\"\n"
    let fixed = hookEdit(zshrc: stale, hookPath: "/opt/share/stalker.zsh")
    t.expect(fixed.changed, "a hook pointing elsewhere is an edit")
    t.expect(fixed.contents.contains("/opt/share/stalker.zsh"), "the new path is in")
    t.expect(!fixed.contents.contains("/Users/someone"), "and the old one is gone")
    t.eq(fixed.contents.components(separatedBy: "stalker.zsh").count - 1, 1,
         "exactly one hook line, never two")

    // Unrelated .zshrc content survives both directions.
    let withOther = "export EDITOR=vim\n" + stale + "alias ll='ls -l'\n"
    t.expect(hookEdit(zshrc: withOther, hookPath: "/opt/share/stalker.zsh").contents
               .contains("export EDITOR=vim"), "other lines are untouched by an edit")
    let removed = hookRemoval(withOther)
    t.expect(removed.changed, "removal reports a change")
    t.expect(!removed.contents.contains("stalker.zsh"), "the hook line is gone")
    t.expect(!removed.contents.contains("# stalker courier hook"), "and its comment with it")
    t.expect(removed.contents.contains("alias ll='ls -l'"), "other lines survive removal")
    t.expect(!hookRemoval("export EDITOR=vim\n").changed, "removing an absent hook is no change")

    // The old installer matched the whole line, so a clone that moved made it append
    // a second hook rather than fix the first. Anyone migrating from that state has
    // two, and a stale one errors on every shell start.
    let twoHooks = """
    export EDITOR=vim
    # stalker courier hook
    source "/old/one/scripts/stalker.zsh"
    # stalker courier hook
    source "/old/two/scripts/stalker.zsh"
    alias ll='ls -l'
    """
    let collapsed = hookEdit(zshrc: twoHooks, hookPath: "/new/share/stalker.zsh")
    t.eq(collapsed.contents.components(separatedBy: "stalker.zsh").count - 1, 1,
         "two stale hooks collapse to one correct hook")
    t.expect(!collapsed.contents.contains("/old/"), "with no stale path left behind")
    let bothGone = hookRemoval(twoHooks)
    t.expect(!bothGone.contents.contains("stalker.zsh"), "and removal takes both out")
    t.expect(bothGone.contents.contains("alias ll='ls -l'"), "leaving everything else")

    // The plist template carries a placeholder the installer fills in.
    let plist = renderPlist(template: "<string>__BINARY__</string>", binaryPath: "/opt/bin/stalker")
    t.eq(plist, "<string>/opt/bin/stalker</string>", "the binary path is substituted")
    t.expect(!plist.contains("__BINARY__"), "no placeholder survives")

    // Support files are found next to the binary under brew, or in the repo from a clone.
    t.eq(resolveSupportDir(executablePath: "/x/bin/stalker", override: "/given", exists: { _ in true }),
         "/given", "an explicit override wins")
    t.eq(resolveSupportDir(executablePath: "/opt/homebrew/opt/stalker/bin/stalker", override: nil,
                           exists: { $0 == "/opt/homebrew/opt/stalker/share/stalker" }),
         "/opt/homebrew/opt/stalker/share/stalker", "the brew layout is found")
    t.eq(resolveSupportDir(executablePath: "/repo/.build/release/stalker", override: nil,
                           exists: { $0 == "/repo/scripts" }),
         "/repo/scripts", "a clone's scripts directory is found")
    // SwiftPM's real output directory carries the target triple, and `.build/debug`
    // is only a symlink to it, so a clone has to be found from either depth.
    t.eq(resolveSupportDir(executablePath: "/repo/.build/arm64-apple-macosx/debug/stalker",
                           override: nil, exists: { $0 == "/repo/scripts" }),
         "/repo/scripts", "and is found from the triple-qualified path too")
    // Review Focus 4: nothing found is nil, so the caller can fail loudly naming what it tried.
    t.eq(resolveSupportDir(executablePath: "/x/bin/stalker", override: nil, exists: { _ in false }),
         nil, "nothing found is nil, never a silent default")
    t.expect(supportDirCandidates(executablePath: "/x/bin/stalker").count >= 2,
             "more than one candidate is reported, for the error message")

    // A binary under .build is thrown away and relinked constantly, so pointing a
    // persistent launchd agent at one would silently degrade real tracking.
    t.expect(isTransientBuildPath("/repo/.build/arm64-apple-macosx/debug/stalker"),
             "a debug build is transient")
    t.expect(isTransientBuildPath("/repo/.build/release/stalker"),
             "so is a release build inside .build")
    t.expect(!isTransientBuildPath("/Users/me/.local/bin/stalker"),
             "an installed binary is not")
    t.expect(!isTransientBuildPath("/opt/homebrew/Cellar/stalker/0.1.0/bin/stalker"),
             "nor is a Homebrew one")

    // One agent today. serve adds the second without touching setup.
    t.eq(stalkerAgents.count, 1, "one agent is installed today")
    t.eq(stalkerAgents[0].label, "stalker.sample", "named for the tool, with no username in it")
    t.eq(stalkerAgents[0].templateName, "stalker.sample.plist", "and matches the shipped template")
}
