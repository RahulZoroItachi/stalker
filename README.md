# stalker

A local activity tracker for macOS. It watches what you actually do on your own
machine, and tells you where your time went.

Everything stays on your laptop. There is no account, no server, and no upload.

## Read this before you install it

This asks for a permission that lets it read the contents of every window you have
open. You should know exactly what it does with that before you grant it.

**What it records.** Every 30 seconds it notes the frontmost app, and one piece of
context: a browser URL, a terminal's working directory, or a window title. It also
notes whether you have touched the keyboard recently, so time you spent away from
the machine is reported separately from time you spent working.

**Where it goes.** One SQLite file, at
`~/Library/Application Support/stalker/stalker.db`, on your machine. You can open it
with `sqlite3` and read every row.

**What never happens.** No network calls. No telemetry. No crash reporting. No
account. Nothing is uploaded, and nothing phones home. The tool has no code that
talks to a network, which you can check: there is no HTTP client anywhere in
`Sources/`.

**Why Accessibility.** macOS exposes a window's title and a browser's current tab
through its Accessibility API, and that one grant covers every app at once. If you
refuse it, browsers still work through a slower AppleScript fallback, but apps like
Slack expose no usable AppleScript and lose their context entirely. You would still
get a record of which apps you used, just not what you were doing in them.

You can take the grant back at any time, in System Settings, and `stalker uninstall`
removes everything else.

## Install

Requires macOS 14 (Sonoma) or newer.

```
brew install RahulZoroItachi/stalker/stalker
stalker setup
```

The first install compiles from source on your machine, which takes a few minutes.
That is deliberate: it means you are running a binary your own compiler produced,
rather than one you downloaded and have to trust.

`stalker setup` does the rest and tells you the one permission to grant by hand. It
is safe to re-run, and re-running it is the fix for almost everything. Run it again
after a `brew upgrade`.

## Then edit the rules

This is the first thing to do, and skipping it is the most likely reason a first
report looks useless.

`~/.config/stalker/rules.toml` decides what counts as work, what counts as fun, and
what is something else. The path rules that ship with it are a guess:

```toml
[[rule]]
context = "*/Work/*"
category = "work"
```

Point those at the directories you actually work in. Rules are applied when a report
is generated, not when data is collected, so fixing the file re-classifies your whole
history. You can get a week of data, then decide how to categorise it.

## Use it

```
stalker report              today, in 30-minute blocks
stalker report --week       one row per day, Monday first
stalker report --since 14   the last fortnight
stalker note 09:00-11:00 workout   log time the laptop could not see
stalker doctor              check permissions and setup
```

`stalker doctor` is the thing to run when something looks wrong. It tells you which
permission is missing and what to do about it.

## Uninstall

```
stalker uninstall
brew uninstall stalker
```

`stalker uninstall` keeps your database and your rules file, and prints where it left
them. Pass `--purge` if you want those gone too. It will also remind you to remove
the Accessibility entry in System Settings, because nothing but a person can revoke
that.

## Building from a clone

```
git clone https://github.com/RahulZoroItachi/stalker
cd stalker
./scripts/install.sh
```

That builds, installs to `~/.local/bin/stalker`, and hands over to the same
`stalker setup`. Tests are `swift run stalker-tests`.
