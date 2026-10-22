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
  url "https://github.com/RahulZoroItachi/stalker/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "37c482bf220182dc9c48088370c0774d862878c8e1d259729e22f58bce1d85ec"
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

  def caveats
    <<~EOS
      One step left, and it is not something a formula is allowed to do:

        stalker setup

      That creates the local signing certificate, installs the default rules and
      the shell hook, and loads the background agent. It then tells you the one
      permission you have to grant by hand, and what this records before you do.

      Safe to re-run, and re-running it is the fix for almost everything. After a
      `brew upgrade`, run it again so the new binary gets signed.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/stalker --version")
  end
end
