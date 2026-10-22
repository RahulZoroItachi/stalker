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

    // A hook is a `source` line and nothing else. Matching the bare filename ate
    // the `if` of a guarded hook and left a dangling `fi`, which is a zsh parse
    // error, and a parse error stops zsh reading the rest of the file — so every
    // line below it silently stopped applying in every new shell.
    let guarded = """
    export A=1
    if [[ -f "/old/scripts/stalker.zsh" ]]; then
      source "/old/scripts/stalker.zsh"
    fi
    export B=2
    """
    let guardFixed = hookEdit(zshrc: guarded, hookPath: "/new/share/stalker.zsh")
    t.expect(guardFixed.contents.contains("if [[ -f"), "a guard around the hook is left alone")
    t.expect(guardFixed.contents.contains("fi"), "so its fi is never orphaned")
    t.expect(guardFixed.contents.contains("export B=2"), "and what follows still applies")
    t.expect(!guardFixed.contents.contains("source \"/old/"), "the old source line is gone")
    t.expect(guardFixed.contents.contains("source \"/new/share/stalker.zsh\""),
             "and ours is in")

    // A line that merely names the file is not a hook.
    let mentions = "alias edithook='vim ~/dotfiles/stalker.zsh'\n"
    t.expect(hookEdit(zshrc: mentions, hookPath: "/new/share/stalker.zsh").contents
               .contains("alias edithook="), "an unrelated line naming the file survives")
    t.expect(!hookRemoval(mentions).changed, "and removal does not touch it")

    // Anything naming the file that we chose not to edit is reported, so a guard
    // that now guards nothing is visible rather than silently inert.
    t.eq(foreignHookLines(guarded).count, 1, "the guard line is reported as foreign")
    t.eq(foreignHookLines(mentions).count, 1, "so is an unrelated mention")
    t.eq(foreignHookLines("source \"/x/stalker.zsh\"\n").count, 0,
         "a plain hook is ours, not foreign")

    // A Cellar path carries the version, and `brew cleanup` deletes old version
    // directories. An agent pointed there stops finding its binary, and a shell hook
    // sourced from there errors on every new terminal. Spec §10 names the stable
    // `opt` path as the one to use, so a Cellar path is rewritten to it.
    t.eq(canonicalBrewPath("/opt/homebrew/Cellar/stalker/0.1.0/bin/stalker"),
         "/opt/homebrew/opt/stalker/bin/stalker", "a Cellar path becomes the opt path")
    t.eq(canonicalBrewPath("/usr/local/Cellar/stalker/0.2.3/bin/stalker"),
         "/usr/local/opt/stalker/bin/stalker", "including on an Intel prefix")
    t.eq(canonicalBrewPath("/opt/homebrew/bin/stalker"), "/opt/homebrew/bin/stalker",
         "the brew bin symlink is already stable, so it is left alone")
    t.eq(canonicalBrewPath("/Users/me/.local/bin/stalker"), "/Users/me/.local/bin/stalker",
         "and a hand-installed path is untouched")
    t.eq(canonicalBrewPath("/repo/.build/debug/stalker"), "/repo/.build/debug/stalker",
         "as is a build artefact")
    t.eq(canonicalBrewPath("/opt/homebrew/Cellar"), "/opt/homebrew/Cellar",
         "a truncated Cellar path is not mangled")

    // The binary the agent runs lives at a path that never moves, because a TCC
    // grant is keyed to the resolved real path. Measured: a grant on
    // /opt/homebrew/bin/stalker died on `brew upgrade` even though the path and the
    // designated requirement were both unchanged, because the symlink's target moved
    // from Cellar/0.1.0 to Cellar/0.1.1. Spec §10.
    let ps = Paths.standard(home: "/Users/me")
    t.eq(ps.agentBinaryPath, "/Users/me/Library/Application Support/stalker/bin/stalker",
         "the agent's binary sits at a fixed path under the data directory")
    t.expect(ps.agentBinaryPath.hasPrefix(ps.dataDir),
             "inside the data directory, so uninstall already knows where it is")
    t.eq(parseArgs(["refresh"]), Command.refresh,
         "refresh re-installs that copy after an upgrade, without touching anything else")
    t.eq(parseArgs(["refresh", "--x"]), Command.usageError, "and takes no arguments")

    // A launchd label and an Automation grant are machine-global, not per-home. So a
    // run against an overridden home must not touch either: bootstrapping an agent
    // would hijack the real one. That is not hypothetical. It happened, pointing the
    // live agent at a plist in /tmp that was then deleted, and real sampling stopped
    // for five minutes.
    t.expect(shouldTouchMachineState(homeOverride: nil, executablePath: "/usr/local/bin/stalker"),
             "a normal install wires up the agent")
    t.expect(!shouldTouchMachineState(homeOverride: "/tmp/x",
                                      executablePath: "/usr/local/bin/stalker"),
             "an overridden home never touches machine-global state")
    t.expect(!shouldTouchMachineState(homeOverride: nil,
                                      executablePath: "/repo/.build/debug/stalker"),
             "and neither does a build artefact")
    t.expect(!shouldTouchMachineState(homeOverride: "/tmp/x",
                                      executablePath: "/repo/.build/debug/stalker"),
             "both reasons at once is still a no")

    // Canonicalising must never make setup fail. `opt/<formula>` is created by
    // Homebrew on install, but an unlinked formula has none, and refusing to run is
    // worse than using the version-pinned path we would otherwise have used anyway.
    t.eq(stableBinaryPath("/opt/homebrew/Cellar/stalker/0.1.0/bin/stalker",
                          exists: { $0 == "/opt/homebrew/opt/stalker/bin/stalker" }),
         "/opt/homebrew/opt/stalker/bin/stalker", "the stable path is used when it is there")
    t.eq(stableBinaryPath("/opt/homebrew/Cellar/stalker/0.1.0/bin/stalker",
                          exists: { _ in false }),
         "/opt/homebrew/Cellar/stalker/0.1.0/bin/stalker",
         "and the original stands when it is not")
    t.eq(stableBinaryPath("/Users/me/.local/bin/stalker", exists: { _ in true }),
         "/Users/me/.local/bin/stalker", "a non-brew path is returned unchanged")

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

    // Every path comes from one home, and nothing could override it, so the only way
    // to exercise a command with side effects was against the author's real data.
    // Setting HOME does not work: the code reads homeDirectoryForCurrentUser.
    t.eq(extractHomeOverride(["doctor"]).home, nil, "no flag means the real home")
    t.eq(extractHomeOverride(["doctor"]).args, ["doctor"], "and the args are untouched")
    t.eq(extractHomeOverride(["--home", "/tmp/x", "doctor"]).home, "/tmp/x",
         "a leading --home is picked up")
    t.eq(extractHomeOverride(["--home", "/tmp/x", "doctor"]).args, ["doctor"],
         "and removed, so the command parser never sees it")
    t.eq(extractHomeOverride(["note", "09:00-10:00", "sleep", "--home", "/tmp/x"]).args,
         ["note", "09:00-10:00", "sleep"], "it may come last too")
    t.eq(extractHomeOverride(["--home"]).args, ["--home"],
         "with no value it is left in place, so parsing refuses it")
    t.eq(parseArgs(extractHomeOverride(["--home"]).args), Command.usageError,
         "and refusing it is what happens")

    // doctor must audit the binary the AGENT runs, which is recorded in the plist,
    // not whichever copy happened to run doctor. With a Homebrew install beside an
    // older ~/.local/bin one, those are different files and only one is signed.
    let samplePlist = """
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/stalker</string>
        <string>sample</string>
    </array>
    """
    t.eq(agentProgramPath(plist: samplePlist), "/opt/homebrew/bin/stalker",
         "the agent's program is read from its plist")
    t.eq(agentProgramPath(plist: "<key>Label</key><string>x</string>"), nil,
         "a plist with no ProgramArguments yields nil")
    t.eq(agentProgramPath(plist: ""), nil, "and so does an empty one")

    // One agent today. serve adds the second without touching setup.
    t.eq(stalkerAgents.count, 1, "one agent is installed today")
    t.eq(stalkerAgents[0].label, "stalker.sample", "named for the tool, with no username in it")
    t.eq(stalkerAgents[0].templateName, "stalker.sample.plist", "and matches the shipped template")
}
