import Foundation

/// Config lives under `.config` and data under `Application Support`, so rules
/// stay hand-owned and version-controllable while the database stays
/// machine-owned and never hand-edited. Spec §6.1.
public struct Paths: Sendable {
    public let dataDir: String
    public let dbPath: String
    public let courierDir: String
    public let rulesPath: String
    /// Blocks logged by hand. Hand-owned like `rules.toml`, so it lives beside it
    /// rather than in Application Support with the machine-written database.
    public let notesPath: String
    /// The binary the launchd agent runs, and the one that holds the Accessibility
    /// grant. A fixed real path, deliberately not Homebrew's.
    ///
    /// TCC keys a grant to the resolved real path. Measured: a grant on
    /// `/opt/homebrew/bin/stalker` died on `brew upgrade` even though that path and
    /// the designated requirement were both unchanged, because the symlink's target
    /// moved from `Cellar/0.1.0` to `Cellar/0.1.1`. A certificate survives the
    /// binary's contents changing; nothing survives its path moving. So the agent
    /// runs a copy at somewhere that never moves, and the grant is given once to
    /// that. Spec §10.
    public let agentBinaryPath: String

    public static func standard(home: String) -> Paths {
        let data = home + "/Library/Application Support/stalker"
        return Paths(dataDir: data,
                     dbPath: data + "/stalker.db",
                     courierDir: data + "/shell",
                     rulesPath: home + "/.config/stalker/rules.toml",
                     notesPath: home + "/.config/stalker/notes.txt",
                     agentBinaryPath: data + "/bin/stalker")
    }
}
