# typed: strict
# frozen_string_literal: true

# Canonical copy. The tap repository (RahulZoroItachi/homebrew-stalker) holds this
# file at Formula/stalker.rb; it lives here so it is reviewed and tested alongside
# the code it installs.
#
# A formula rather than a cask, deliberately. Homebrew compiles this on the user's
# own machine, so the binary is never downloaded and Gatekeeper never evaluates it,
# which is what lets the whole thing work with no Apple Developer ID and nothing to
# pay. A cask would fetch a prebuilt binary, which arrives quarantined and needs
# notarizing. See docs/superpowers/specs/2026-10-21-distribution-design.md §2.
class Stalker < Formula
  desc "Local activity tracker that never leaves your machine"
  homepage "https://github.com/RahulZoroItachi/stalker"
  url "https://github.com/RahulZoroItachi/stalker/archive/refs/tags/v0.1.2.tar.gz"
  sha256 "2c47067836c01a6ebc5943b907dab8d222d742f1254a99bf6528e422f0ea8c02"
  license "MIT"
  head "https://github.com/RahulZoroItachi/stalker.git", branch: "main"

  # Matches platforms: [.macOS(.v14)] in Package.swift. Declared so an older Mac
  # fails at install with a reason, rather than part-way through a compile.
  depends_on macos: :sonoma

  # No `depends_on xcode:` on purpose. That requirement is satisfied only by Xcode
  # proper, so declaring it would push a friend into a multi-gigabyte download for a
  # toolchain they already have: Swift ships in the Command Line Tools, which
  # Homebrew itself already requires. Verified on a machine where `brew config`
  # reports "Xcode: N/A" and `swift build` works.

  # No `bottle do` block either. A bottle is a prebuilt binary, which reintroduces
  # the signing question the source build exists to avoid.

  def install
    # --disable-sandbox is required: Homebrew's build sandbox and SwiftPM's own
    # sandboxing conflict. The package has no dependencies, so the build needs no
    # network and gives up nothing by running unsandboxed.
    system "swift", "build", "--disable-sandbox", "-c", "release",
           "--scratch-path", buildpath/".build"
    bin.install ".build/release/stalker"

    # `stalker setup` reads these from here, which is how the ~/.zshrc hook stops
    # pointing into somebody's clone.
    pkgshare.install "scripts/rules.toml.default"
    pkgshare.install "scripts/stalker.zsh"
    pkgshare.install "scripts/stalker.sample.plist"
  end

  # Re-install the copy of the binary the agent runs, so an upgrade repairs itself.
  #
  # The agent deliberately runs its own copy at a fixed path under the user's data
  # directory, because a TCC Accessibility grant is keyed to the resolved real path
  # and Homebrew's moves on every upgrade. Measured: a grant on
  # /opt/homebrew/bin/stalker died on `brew upgrade` even though that path and the
  # code signature were unchanged, because the symlink started pointing at
  # Cellar/0.1.1 instead of Cellar/0.1.0.
  #
  # `refresh` only copies and re-signs that one file. It touches no launchd agent and
  # raises no prompt, because the agent's path has not changed and the signing
  # certificate already exists by the time an upgrade happens. So it is safe to run
  # unattended, and it is why a user grants Accessibility once rather than once per
  # upgrade. It exits zero even when there is nothing to do, so it cannot fail
  # somebody's `brew upgrade`.
  # must_succeed: false so this can never fail somebody's `brew upgrade`. `refresh`
  # already exits zero when there is nothing to do, and this is the belt to that
  # braces.
  post_install_steps do
    run "stalker", args: ["refresh"], base: :bin, must_succeed: false
  end

  def caveats
    <<~EOS
      One step left, and it is not something a formula is allowed to do:

        stalker setup

      That creates the local signing certificate, installs the default rules and
      the shell hook, and loads the background agent. It then tells you the one
      permission you have to grant by hand, and what this records before you do.

      Safe to re-run, and re-running it is the fix for almost everything.

      You only have to grant that permission once, ever. Upgrades refresh
      themselves, because the agent runs its own copy at a path that never moves.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/stalker --version")
  end
end
