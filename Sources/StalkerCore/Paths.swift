import Foundation

/// Config lives under `.config` and data under `Application Support`, so rules
/// stay hand-owned and version-controllable while the database stays
/// machine-owned and never hand-edited. Spec §6.1.
public struct Paths: Sendable {
    public let dataDir: String
    public let dbPath: String
    public let courierDir: String
    public let rulesPath: String

    public static func standard(home: String) -> Paths {
        let data = home + "/Library/Application Support/stalker"
        return Paths(dataDir: data,
                     dbPath: data + "/stalker.db",
                     courierDir: data + "/shell",
                     rulesPath: home + "/.config/stalker/rules.toml")
    }
}
