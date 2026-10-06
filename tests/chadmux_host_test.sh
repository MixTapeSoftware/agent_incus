#!/bin/bash
# Run the host Chadmux installer against a throwaway HOME with local Git
# repositories standing in for Chadmux and TPM. No network access needed.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export GIT_CONFIG_GLOBAL="$fixture/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME
git config --global user.name 'Test User'
git config --global user.email test@example.invalid
git config --global protocol.file.allow always

git init -q "$fixture/chadmux"
git -C "$fixture/chadmux" checkout -qb main
mkdir -p "$fixture/chadmux/scripts"
echo '# upstream config' > "$fixture/chadmux/tmux.conf"
printf '#!/bin/sh\nexit 0\n' > "$fixture/chadmux/scripts/incus-panes.sh"
chmod +x "$fixture/chadmux/scripts/incus-panes.sh"
git -C "$fixture/chadmux" add .
git -C "$fixture/chadmux" commit -qm initial
git config --global "url.file://$fixture/chadmux.insteadOf" "https://github.com/chadfennell/chadmux.git"

# TPM stand-in whose plugin installer leaves a marker.
git init -q "$fixture/tpm"
mkdir -p "$fixture/tpm/bin"
printf '#!/bin/sh\ntouch "$HOME/tpm-plugins-installed"\n' > "$fixture/tpm/bin/install_plugins"
chmod +x "$fixture/tpm/bin/install_plugins"
git -C "$fixture/tpm" add .
git -C "$fixture/tpm" commit -qm initial
git config --global "url.file://$fixture/tpm.insteadOf" "https://github.com/tmux-plugins/tpm"

# Status and install need tmux on PATH; use a stub so the test host needn't have it.
mkdir -p "$fixture/bin"
printf '#!/bin/sh\nexit 0\n' > "$fixture/bin/tmux"
chmod +x "$fixture/bin/tmux"
export PATH="$fixture/bin:$PATH"

export HOME="$fixture/home"
PASS=0
assert() {
  local label="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    echo "  ok  $label"
  else
    echo "  FAIL $label" >&2
    exit 1
  fi
}
refute() {
  local label="$1"
  shift
  if "$@"; then
    echo "  FAIL $label" >&2
    exit 1
  fi
  PASS=$((PASS + 1))
  echo "  ok  $label"
}
reset_home() {
  rm -rf "$HOME"
  mkdir -p "$HOME"
}
status() { "$REPO_ROOT/chadmux.host" status; }
install() { "$REPO_ROOT/chadmux.host" install > "$fixture/install.log" 2>&1; }
# Every file under HOME with its contents or link target, to prove nothing changed.
snapshot() {
  (cd "$HOME" && find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
    if [[ -L "$f" ]]; then echo "$f -> $(readlink "$f")"; else echo "$f: $(cksum < "$f")"; fi
  done)
}
untouched() {
  install && return 1
  test "$(snapshot)" = "$1"
}

reset_home
assert 'clean host is absent' test "$(status)" = absent
assert 'fresh install succeeds' install
assert 'fresh install is recognized' test "$(status)" = installed
assert 'legacy path links to Chadmux config' test -L "$HOME/.tmux.conf" -a "$HOME/.tmux.conf" -ef "$HOME/.config/tmux/tmux.conf"
assert 'TPM is cloned' test -x "$HOME/.tmux/plugins/tpm/bin/install_plugins"
assert 'TPM plugins are installed' test -f "$HOME/tpm-plugins-installed"
assert 'staging directory is removed' test "$(find "$HOME/.config" -name '.chadmux.*' | wc -l | tr -d ' ')" = 0
before="$(snapshot)"
assert 'reinstall succeeds' install
assert 'reinstall changes nothing' test "$(snapshot)" = "$before"

reset_home
echo 'my legacy config' > "$HOME/.tmux.conf"
assert 'legacy config is reported' test "$(status)" = "existing $HOME/.tmux.conf"
assert 'legacy config is left alone' untouched "$(snapshot)"
refute 'no Chadmux checkout beside a legacy config' test -e "$HOME/.config/tmux"

reset_home
mkdir -p "$HOME/.config/tmux"
echo 'my config' > "$HOME/.config/tmux/tmux.conf"
assert 'config directory is reported' test "$(status)" = "existing $HOME/.config/tmux"
assert 'config directory is left alone' untouched "$(snapshot)"
refute 'no legacy link beside a config directory' test -e "$HOME/.tmux.conf" -o -L "$HOME/.tmux.conf"

reset_home
mkdir -p "$HOME/.config" "$fixture/dotfiles"
echo 'dotfiles config' > "$fixture/dotfiles/tmux.conf"
ln -s "$fixture/dotfiles" "$HOME/.config/tmux"
assert 'config directory symlink is left alone' untouched "$(snapshot)"
assert 'symlinked config is unchanged' test "$(cat "$fixture/dotfiles/tmux.conf")" = 'dotfiles config'

reset_home
ln -s "$fixture/missing" "$HOME/.tmux.conf"
assert 'dangling legacy symlink is reported' test "$(status)" = "existing $HOME/.tmux.conf"
assert 'dangling legacy symlink is left alone' untouched "$(snapshot)"

reset_home
mkdir -p "$HOME/xdg/tmux"
echo 'xdg config' > "$HOME/xdg/tmux/tmux.conf"
assert 'XDG config is reported' test "$(XDG_CONFIG_HOME="$HOME/xdg" status)" = "existing $HOME/xdg/tmux"
XDG_CONFIG_HOME="$HOME/xdg" assert 'XDG config is left alone' untouched "$(snapshot)"

reset_home
mkdir -p "$fixture/notmux"
ln -s "$(command -v git)" "$fixture/notmux/git"
assert 'missing tmux is reported' test "$(PATH="$fixture/notmux" status)" = 'missing tmux'
refute 'missing tmux stops installation' env PATH="$fixture/notmux" "$REPO_ROOT/chadmux.host" install 2>/dev/null
assert 'missing tmux writes nothing' test -z "$(ls -A "$HOME")"

reset_home
mv "$fixture/chadmux" "$fixture/unavailable"
refute 'failed clone stops installation' install
assert 'failed clone exposes Git diagnostics' grep -q 'fatal:' "$fixture/install.log"
refute 'failed clone leaves no config' test -e "$HOME/.config/tmux" -o -e "$HOME/.tmux.conf"
assert 'failed clone cleans staging directory' test "$(find "$HOME/.config" -name '.chadmux.*' | wc -l | tr -d ' ')" = 0
mv "$fixture/unavailable" "$fixture/chadmux"

# install_shortcuts: Chadmux is opt-in and never touches an existing config.
shortcuts() { "$REPO_ROOT/install_shortcuts" "$@" > "$fixture/shortcuts.log" 2>&1; }

reset_home
assert 'install_shortcuts without a terminal succeeds' shortcuts < /dev/null
assert 'no terminal means no Chadmux' test "$(status)" = absent
refute 'no terminal means no question' grep -q 'Install Chadmux' "$fixture/shortcuts.log"

reset_home
assert 'install_shortcuts --no-chadmux succeeds' shortcuts --no-chadmux < /dev/null
assert '--no-chadmux skips Chadmux' test "$(status)" = absent

reset_home
assert 'install_shortcuts --chadmux succeeds' shortcuts --chadmux < /dev/null
assert '--chadmux installs Chadmux' test "$(status)" = installed

reset_home
echo 'my legacy config' > "$HOME/.tmux.conf"
assert 'install_shortcuts --chadmux with a config succeeds' shortcuts --chadmux < /dev/null
assert '--chadmux keeps an existing config' test "$(cat "$HOME/.tmux.conf")" = 'my legacy config'
assert '--chadmux explains the skip' grep -q 'Keeping your tmux config' "$fixture/shortcuts.log"

# The interactive question needs a terminal; util-linux script provides one.
if script --version 2>/dev/null | grep -q util-linux; then
  reset_home
  printf '\n' | script -qec "$REPO_ROOT/install_shortcuts" /dev/null > "$fixture/shortcuts.log" 2>&1
  assert 'question is asked in a terminal' grep -q 'Install Chadmux' "$fixture/shortcuts.log"
  assert 'Enter defaults to no' test "$(status)" = absent

  reset_home
  printf 'y\n' | script -qec "$REPO_ROOT/install_shortcuts" /dev/null > "$fixture/shortcuts.log" 2>&1
  assert 'answering y installs Chadmux' test "$(status)" = installed
else
  echo '  skip interactive question (needs util-linux script)'
fi

echo "Passed: $PASS"
