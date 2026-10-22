/// The released version, bumped by hand when a release is tagged.
///
/// A committed constant rather than something derived at build time. SwiftPM has
/// no version mechanism, and generating one would mean the Homebrew formula patching
/// a source file during `install` — more moving parts than a constant that is wrong
/// in exactly the same way a forgotten tag is. Spec §7.
public let stalkerVersion = "0.1.3"
