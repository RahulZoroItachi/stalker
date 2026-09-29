# stalker courier hook. Source this from ~/.zshrc.
#
# Writes one line — "<unix-seconds> <cwd>" — to a per-tty file, overwriting it.
# The file never grows; the whole directory stays around 16K. The sampler reads
# these files on its own 30-second tick and takes the newest as the focused
# shell's directory.
#
# Builtins only, no subprocess: measured at 0.0587 ms per command. The naive
# version that shells out to sqlite3 measured 4.91 ms, which is felt at the prompt.

zmodload zsh/datetime

STALKER_COURIER_DIR="${HOME}/Library/Application Support/stalker/shell"

_stalker_courier() {
  [[ -d "$STALKER_COURIER_DIR" ]] || return 0
  print -r -- "$EPOCHSECONDS $PWD" > "$STALKER_COURIER_DIR/${TTY:t}"
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _stalker_courier
add-zsh-hook chpwd   _stalker_courier
