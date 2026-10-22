import Foundation
import StalkerCore
import StalkerMac

/// The signing identity that keeps TCC grants alive across rebuilds.
private let signIdentity = "stalker-dev"

/// Run a command, returning its status and its stdout.
///
/// stderr is passed through so a failing `security` or `codesign` explains itself in
/// place rather than being swallowed and reported as a bare non-zero.
@discardableResult
func sh(_ exe: String, _ args: [String], quietErrors: Bool = false) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    if quietErrors { p.standardError = FileHandle.nullDevice }
    do { try p.run() } catch { return (127, "") }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, out)
}

/// Whether `codesign` can already see the identity.
private func signingIdentityExists() -> Bool {
    sh("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], quietErrors: true)
        .out.contains(signIdentity)
}

/// Create the `stalker-dev` code signing certificate, or leave an existing one alone.
///
/// Why a certificate at all: SwiftPM's default is an ad-hoc signature, whose
/// designated requirement is the code hash. TCC therefore pins every Accessibility
/// and Automation grant to one exact build, and the next build is a different program
/// to it while System Settings still reads as enabled. Signing with a certificate
/// makes the requirement "identifier + leaf cert", which every later build satisfies.
/// This is what stands in for a Developer ID, and it costs nothing. Spec §2.
private func ensureSigningCertificate() -> Bool {
    if signingIdentityExists() {
        print("   '\(signIdentity)' already exists, leaving it alone")
        return true
    }

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("stalker-cert-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard (try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil
    else {
        print("   could not create a temporary directory for the certificate")
        return false
    }

    let cnf = tmp.appendingPathComponent("cert.cnf")
    let key = tmp.appendingPathComponent("key.pem")
    let crt = tmp.appendingPathComponent("cert.pem")
    let p12 = tmp.appendingPathComponent("\(signIdentity).p12")

    let config = """
    [req]
    distinguished_name = dn
    x509_extensions    = v3
    prompt             = no

    [dn]
    CN = \(signIdentity)

    [v3]
    basicConstraints     = critical,CA:false
    keyUsage             = critical,digitalSignature
    extendedKeyUsage     = critical,codeSigning
    subjectKeyIdentifier = hash
    """
    guard (try? config.write(to: cnf, atomically: true, encoding: .utf8)) != nil else {
        print("   could not write the certificate request")
        return false
    }

    // 20 years. This signs one local binary for one user, and an expiry landing
    // mid-use would silently invalidate the very TCC grants it exists to protect.
    print("   generating a self-signed code signing certificate")
    guard sh("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-sha256",
                                  "-days", "7300", "-nodes",
                                  "-keyout", key.path, "-out", crt.path,
                                  "-config", cnf.path], quietErrors: true).status == 0 else {
        print("   openssl could not generate the certificate")
        return false
    }
    guard sh("/usr/bin/openssl", ["pkcs12", "-export", "-out", p12.path,
                                  "-inkey", key.path, "-in", crt.path,
                                  "-name", signIdentity,
                                  "-passout", "pass:\(signIdentity)"], quietErrors: true).status == 0 else {
        print("   openssl could not package the certificate")
        return false
    }

    // -T scopes access to codesign alone, so signing does not prompt every time.
    // Deliberately not -A, which would allow any program to use the key.
    print("   importing it into your login keychain")
    let keychain = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Keychains/login.keychain-db").path
    sh("/usr/bin/security", ["import", p12.path, "-k", keychain, "-P", signIdentity,
                             "-f", "pkcs12", "-T", "/usr/bin/codesign"])

    if !signingIdentityExists() {
        // User trust domain only. Without -d this does not touch the system store.
        print("   marking it trusted for code signing (macOS will ask for your password)")
        sh("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
                                 "-k", keychain, crt.path])
    }

    guard signingIdentityExists() else {
        print("   FAILED: '\(signIdentity)' is still not a valid code signing identity")
        return false
    }
    return true
}

/// Put the binary the agent runs at its fixed path, and sign it there.
///
/// Copied rather than symlinked, and signed after copying. A symlink would defeat
/// the whole point: TCC resolves one and keys the grant to the target, which is what
/// broke when Homebrew's Cellar directory was renamed by an upgrade.
///
/// Copying onto itself is skipped rather than attempted, so this is safe to re-run.
private func installAgentBinary(from source: String) -> Bool {
    let fm = FileManager.default
    let dest = paths.agentBinaryPath

    if source != dest {
        try? fm.removeItem(atPath: dest)
        guard (try? fm.copyItem(atPath: source, toPath: dest)) != nil else {
            print("   could not copy \(source) to \(dest)")
            return false
        }
    }
    guard sh("/usr/bin/codesign", ["-f", "-s", signIdentity, "-i", "stalker", dest]).status == 0
    else {
        print("   could not sign \(dest)")
        return false
    }
    print("   installed and signed \(dest)")
    print("   this path never changes, which is what keeps the Accessibility grant alive")
    return true
}

/// Re-install the agent's binary after an upgrade, and nothing else.
///
/// What a `brew upgrade` needs. The agent's path does not change, so launchd needs
/// no attention, and the certificate already exists by then, so nothing prompts. That
/// is what lets the formula call this from `post_install` and leave the user with
/// nothing to do.
///
/// Forgiving on purpose: if `setup` has never run there is nothing to refresh, and a
/// non-zero exit here would fail somebody's `brew upgrade` over it.
func runRefresh() -> Int32 {
    let fm = FileManager.default
    let runningExe = stableBinaryPath(Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
                                      exists: { fm.fileExists(atPath: $0) })

    guard fm.fileExists(atPath: paths.dataDir) else {
        print("stalker: nothing to refresh, run `stalker setup` first")
        return 0
    }
    guard signingIdentityExists() else {
        print("stalker: no signing certificate yet, run `stalker setup` first")
        return 0
    }
    guard installAgentBinary(from: runningExe) else {
        print("stalker: could not refresh the agent's binary, run `stalker setup`")
        return 0
    }
    return 0
}

/// The per-user half of installing stalker.
///
/// A Homebrew formula may not do any of this: it must not edit `~/.zshrc`, must not
/// bootstrap launchd agents, and must not prompt for a keychain password. So it lives
/// in the binary, where it ships with every install rather than with a clone. Safe to
/// re-run, and re-running it is the documented repair for almost everything. Spec §4.
func runSetup(supportDirOverride: String?) -> Int32 {
    let fm = FileManager.default
    // Canonicalised, so a Cellar invocation cannot pin the agent and the shell hook
    // to a version directory `brew cleanup` will delete, and with a fallback so that
    // an unlinked formula still installs. See `stableBinaryPath`.
    // The binary that is running. Used only to find the support files beside it.
    let runningExe = stableBinaryPath(Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
                                      exists: { fm.fileExists(atPath: $0) })
    // The binary the agent will run, and the one that gets the Accessibility grant.
    let exe = paths.agentBinaryPath

    print("stalker setup")

    print("1. directories")
    let configDir = URL(fileURLWithPath: paths.rulesPath).deletingLastPathComponent().path
    let binDir = URL(fileURLWithPath: paths.agentBinaryPath).deletingLastPathComponent().path
    for dir in [paths.dataDir, paths.courierDir, configDir, binDir,
                home + "/Library/LaunchAgents"] {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    guard fm.fileExists(atPath: paths.courierDir), fm.fileExists(atPath: binDir) else {
        print("   could not create the directories under \(paths.dataDir)")
        return 1
    }

    print("2. signing identity")
    guard ensureSigningCertificate() else { return 1 }

    print("3. the binary the agent runs")
    guard installAgentBinary(from: runningExe) else { return 1 }

    print("4. support files")
    guard let support = resolveSupportDir(executablePath: runningExe, override: supportDirOverride,
                                          exists: { fm.fileExists(atPath: $0) }) else {
        // Named paths rather than a silent default: skipping the rules file and the
        // shell hook would leave an install that looks finished and records little.
        print("   could not find the support files. Tried:")
        for c in supportDirCandidates(executablePath: runningExe) { print("     \(c)") }
        print("   pass --support-dir PATH to say where they are")
        return 1
    }
    print("   reading from \(support)")

    print("5. excluding the database from Time Machine")
    sh("/usr/bin/tmutil", ["addexclusion", paths.dataDir])

    print("6. rules")
    if fm.fileExists(atPath: paths.rulesPath) {
        print("   \(paths.rulesPath) already exists, leaving it alone")
    } else {
        let src = support + "/rules.toml.default"
        guard (try? fm.copyItem(atPath: src, toPath: paths.rulesPath)) != nil else {
            print("   could not copy \(src)")
            return 1
        }
        print("   installed default rules, edit \(paths.rulesPath) to match your directories")
    }

    print("7. shell hook")
    // Resolve symlinks first. An atomic write replaces a symlink with a regular
    // file, which would silently detach a stow/chezmoi/dotbot dotfile repo from the
    // shell that was reading it.
    let zshrcPath = URL(fileURLWithPath: home + "/.zshrc").resolvingSymlinksInPath().path
    let existing = try? String(contentsOfFile: zshrcPath, encoding: .utf8)
    let edit = hookEdit(zshrc: existing, hookPath: support + "/stalker.zsh")
    if edit.changed {
        // The only edit this makes to a file it does not own, so it is the only one
        // worth making reversible.
        if let existing {
            let backup = zshrcPath + ".stalker.bak"
            if !fm.fileExists(atPath: backup),
               (try? existing.write(toFile: backup, atomically: true, encoding: .utf8)) != nil {
                print("   backed up your previous .zshrc to \(backup)")
            }
        }
        guard (try? edit.contents.write(toFile: zshrcPath, atomically: true, encoding: .utf8)) != nil
        else {
            print("   could not write \(zshrcPath)")
            return 1
        }
        print("   added to \(zshrcPath), open a new terminal tab for it to take effect")
    } else {
        print("   already sourced from \(zshrcPath)")
    }
    for line in foreignHookLines(edit.contents) {
        print("   NOTE: left this line alone. It names the hook but does not source it,")
        print("         so it may now refer to something that is no longer there:")
        print("           \(line.trimmingCharacters(in: .whitespaces))")
    }

    print("8. launchd agents")
    let wiring = shouldTouchMachineState(homeOverride: homeOverride, executablePath: exe)
    if homeOverride != nil {
        print("   SKIPPED. --home was given. A launchd label is keyed per-user by the")
        print("   system, not per-home, so bootstrapping one from here would unregister")
        print("   and replace the real agent rather than a copy of it.")
    } else if isTransientBuildPath(exe) {
        // Deliberately not an error: everything above this point was useful, and a
        // developer running `swift run stalker setup` wants to exercise it. What they
        // do not want is their real agent repointed at a binary that relinks on the
        // next build and vanishes on the next clean.
        print("   SKIPPED. This binary lives under .build, so it is a build artefact:")
        print("     \(exe)")
        print("   Pointing the agent here would break your tracking the next time you")
        print("   rebuilt. Run ./scripts/install.sh instead, which installs the binary")
        print("   first and then wires the agent to the installed copy.")
    }
    let uid = getuid()
    for agent in stalkerAgents where wiring {
        let template = support + "/" + agent.templateName
        guard let text = try? String(contentsOfFile: template, encoding: .utf8) else {
            print("   could not read \(template)")
            return 1
        }
        let dest = "\(home)/Library/LaunchAgents/\(agent.label).plist"
        guard (try? renderPlist(template: text, binaryPath: exe)
                .write(toFile: dest, atomically: true, encoding: .utf8)) != nil else {
            print("   could not write \(dest)")
            return 1
        }
        guard sh("/usr/bin/plutil", ["-lint", dest], quietErrors: true).status == 0 else {
            print("   \(dest) is not a valid plist")
            return 1
        }
        // Boot out before bootstrapping. A label left registered keeps firing on its
        // own schedule, and two samplers would write to one database.
        sh("/bin/launchctl", ["bootout", "gui/\(uid)/\(agent.label)"], quietErrors: true)
        guard sh("/bin/launchctl", ["bootstrap", "gui/\(uid)", dest]).status == 0 else {
            print("   could not load \(agent.label)")
            return 1
        }
        print("   loaded \(agent.label) → \(exe)")
    }

    print("9. automation prompts")
    if wiring {
        // Each AppleScript target is a separate grant, and the first request for one
        // prompts. Under launchd there is nobody to answer, so they are raised once
        // from here, which is the same trick `doctor` already uses for Finder.
        _ = FinderFolderProbe().folder()
        let browser = BrowserAppleScriptProbe()
        for id in browserBundleIds.sorted() { _ = browser.url(bundleId: id) }
        print("   asked Finder and \(browserBundleIds.count) browsers once, so macOS prompts now")
        print("   rather than silently refusing a background agent later")
    } else {
        // Automation grants are per-user too, so a trial run must not spend them.
        print("   SKIPPED, for the same reason as the agent above.")
    }

    print("""

    10. ONE STEP LEFT, and only you can do it
       Grant Accessibility to this exact binary:
         \(exe)
       System Settings → Privacy & Security → Accessibility

       The "+" there opens a file picker on /Applications, and a command-line
       program is not shown in it. Press Cmd+Shift+G, paste the path above,
       press Return.

       Without it, browsers still work through the AppleScript fallback, but apps
       like Slack lose their context entirely.

    What this records, so the permission above is an informed choice:
       the frontmost app, plus a URL, working directory or window title, and
       whether input is idle. Sampled every 30 seconds.
    Where it goes:
       one SQLite file at \(paths.dbPath), on this machine.
    What never happens:
       no network calls, no telemetry, no account, no upload.

    Then:  stalker doctor
    Out:   stalker uninstall
    """)

    return 0
}

/// Undo what `setup` did.
///
/// A trial needs a visible way out, or people decline the trial. Spec §6.
///
/// Nothing here treats a missing file as an error: uninstall has to work on a
/// half-finished install, which is exactly the state someone is in when they have
/// decided to give up on it.
func runUninstall(purge: Bool) -> Int32 {
    let fm = FileManager.default
    let uid = getuid()

    print("stalker uninstall")

    print("1. launchd agents")
    for agent in stalkerAgents {
        sh("/bin/launchctl", ["bootout", "gui/\(uid)/\(agent.label)"], quietErrors: true)
        let plist = "\(home)/Library/LaunchAgents/\(agent.label).plist"
        try? fm.removeItem(atPath: plist)
        print("   removed \(agent.label)")
    }

    print("2. shell hook")
    let zshrcPath = URL(fileURLWithPath: home + "/.zshrc").resolvingSymlinksInPath().path
    if let existing = try? String(contentsOfFile: zshrcPath, encoding: .utf8) {
        let edit = hookRemoval(existing)
        // "nothing to remove" and "could not write" are different facts, and
        // collapsing them reported a failed write as a clean uninstall.
        if !edit.changed {
            print("   no hook in \(zshrcPath)")
        } else if (try? edit.contents.write(toFile: zshrcPath,
                                            atomically: true, encoding: .utf8)) != nil {
            print("   removed from \(zshrcPath), it stops on your next new terminal tab")
        } else {
            print("   COULD NOT write \(zshrcPath). The hook is still there, remove it by hand.")
        }
    } else {
        print("   no \(zshrcPath)")
    }

    print("3. binaries")
    // The agent's copy, and the one a clone's install.sh stages. A Homebrew-installed
    // binary is brew's to remove, which is why that command is printed at the end.
    for b in [paths.agentBinaryPath, home + "/.local/bin/stalker"] {
        if fm.fileExists(atPath: b) {
            try? fm.removeItem(atPath: b)
            print("   removed \(b)")
        }
    }
    // The directory too, since nothing of the user's lives in it.
    try? fm.removeItem(atPath: URL(fileURLWithPath: paths.agentBinaryPath)
                        .deletingLastPathComponent().path)

    print("4. your data")
    if purge {
        try? fm.removeItem(atPath: paths.dataDir)
        try? fm.removeItem(atPath: paths.rulesPath)
        try? fm.removeItem(atPath: paths.notesPath)
        print("   deleted, as --purge asked")
    } else {
        // Both are hand-earned: weeks of history, and a rules file someone tuned.
        // Neither is an installer's to throw away without being told to.
        print("   kept. Your history is at \(paths.dbPath)")
        print("   kept. Your rules are at \(paths.rulesPath)")
        print("   pass --purge to delete them too")
    }

    // The certificate stays. Removing it needs a keychain prompt to achieve nothing,
    // since it signs only this one binary for this one user.
    print("""

    TWO THINGS THIS CANNOT DO FOR YOU
      If you installed through Homebrew:
        brew uninstall stalker
      Nothing but a person can revoke a TCC grant, so to take the entry back out:
        System Settings → Privacy & Security → Accessibility
    """)

    return 0
}
