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

    public static func standard(home: String) -> Paths {
        let data = home + "/Library/Application Support/stalker"
        return Paths(dataDir: data,
                     dbPath: data + "/stalker.db",
                     courierDir: data + "/shell",
                     rulesPath: home + "/.config/stalker/rules.toml",
                     notesPath: home + "/.config/stalker/notes.txt")
    }
}
