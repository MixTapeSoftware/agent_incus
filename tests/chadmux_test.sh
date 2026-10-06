#!/bin/bash
# Run the plugin's guest script with real local Git repositories, without Incus
# or network access. Substitute a test directory for guest $HOME.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export TEST_HOME="$fixture/guest"
export GIT_CONFIG_GLOBAL="$fixture/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
upstream="https://github.com/chadfennell/chadmux.git"
git config --global user.name 'Test User'
git config --global user.email test@example.invalid
git config --global protocol.file.allow always
git init -q "$fixture/upstream"
git -C "$fixture/upstream" checkout -qb main
mkdir -p "$fixture/upstream/scripts"
echo '# upstream config' > "$fixture/upstream/tmux.conf"
printf '#!/bin/sh\nexit 0\n' > "$fixture/upstream/scripts/incus-panes.sh"
chmod +x "$fixture/upstream/scripts/incus-panes.sh"
git -C "$fixture/upstream" add .
git -C "$fixture/upstream" commit -qm initial
git config --global "url.file://$fixture/upstream.insteadOf" "$upstream"

CONTAINER_NAME=test HOST_USER=test
log() { :; }
warn() { echo "$*" >&2; }
incus() {
  # Only the first guest script and installation probe are under test. TPM's
  # unchanged network installation is represented by its expected directory.
  local command="${!#}"
  case "$command" in
    'bash -s') sed 's/\$HOME/\$TEST_HOME/g' | bash ;;
    *'test -d "$HOME/.config/tmux/.git"'*)
      command="${command//\$HOME/\$TEST_HOME}"
      bash -c "$command" ;;
    *) mkdir -p "$TEST_HOME/.tmux/plugins/tpm" ;;
  esac
}
source "$REPO_ROOT/plugins/50-chadmux.sh"
export CONTAINER_NAME HOST_USER
export -f log warn incus
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
reset_guest() {
  rm -rf "$TEST_HOME"
  mkdir -p "$TEST_HOME/.config"
}
install() {
  # Match the production hook: the plugin runs with errexit in its own shell.
  bash -ec 'source "$1"; plugin_install' bash "$REPO_ROOT/plugins/50-chadmux.sh" \
    > "$fixture/install.log" 2>&1
}

reset_guest
install
assert 'fresh installation is recognized' plugin_is_installed
assert 'legacy path points to upstream config' test "$TEST_HOME/.tmux.conf" -ef "$TEST_HOME/.config/tmux/tmux.conf"
echo '# updated config' >> "$fixture/upstream/tmux.conf"
git -C "$fixture/upstream" commit -qam update
install
assert 'existing upstream checkout fast-forwards' cmp "$fixture/upstream/tmux.conf" "$TEST_HOME/.config/tmux/tmux.conf"
assert 'reinstall does not create a backup' test "$(find "$TEST_HOME" -name '*.backup.*' | wc -l | tr -d ' ')" = 0

reset_guest
mkdir -p "$TEST_HOME/.config/tmux"
echo 'custom config' > "$TEST_HOME/.config/tmux/tmux.conf"
echo 'legacy config' > "$TEST_HOME/.tmux.conf"
install
assert 'existing config directory is preserved' test "$(cat "$TEST_HOME"/.config/tmux.backup.*/tmux/tmux.conf)" = 'custom config'
assert 'legacy config is preserved' test "$(cat "$TEST_HOME"/.tmux.conf.backup.*/.tmux.conf)" = 'legacy config'
assert 'replacement is installed' plugin_is_installed

reset_guest
git clone -q "$fixture/upstream" "$TEST_HOME/.config/tmux"
git -C "$TEST_HOME/.config/tmux" remote set-url origin "$fixture/unrelated-remote"
echo 'local edits' >> "$TEST_HOME/.config/tmux/tmux.conf"
mkdir -p "$TEST_HOME/.tmux/plugins/tpm"
ln -s "$TEST_HOME/.config/tmux/tmux.conf" "$TEST_HOME/.tmux.conf"
if plugin_is_installed; then
  echo 'FAIL: unrelated checkout counted as installed' >&2
  exit 1
fi
PASS=$((PASS + 1))
echo '  ok  unrelated checkout is not recognized as installed'
install
backup=("$TEST_HOME"/.config/tmux.backup.*/tmux)
assert 'unrelated repository keeps its remote' test "$(git -C "${backup[0]}" config --get remote.origin.url)" = "$fixture/unrelated-remote"
assert 'unrelated repository keeps local edits' test "$(tail -n 1 "${backup[0]}/tmux.conf")" = 'local edits'
assert 'unrelated repository is replaced with Chadmux' plugin_is_installed

reset_guest
mkdir -p "$fixture/user-config"
echo 'symlink target' > "$fixture/user-config/tmux.conf"
ln -s "$fixture/user-config" "$TEST_HOME/.config/tmux"
ln -s "$fixture/missing-config" "$TEST_HOME/.tmux.conf"
install
assert 'config symlink is preserved' test -L "$TEST_HOME"/.config/tmux.backup.*/tmux
assert 'symlink target is unchanged' test "$(cat "$fixture/user-config/tmux.conf")" = 'symlink target'
assert 'dangling legacy symlink is preserved' test -L "$TEST_HOME"/.tmux.conf.backup.*/.tmux.conf
assert 'symlink replacement is installed' plugin_is_installed

reset_guest
mkdir -p "$TEST_HOME/.config/tmux"
echo 'keep config' > "$TEST_HOME/.config/tmux/tmux.conf"
echo 'keep legacy' > "$TEST_HOME/.tmux.conf"
mv "$fixture/upstream" "$fixture/unavailable"
if install; then
  echo 'FAIL: failed clone reported success' >&2
  exit 1
fi
PASS=$((PASS + 1))
echo '  ok  failed clone stops installation'
assert 'failed clone preserves active config' test "$(cat "$TEST_HOME/.config/tmux/tmux.conf")" = 'keep config'
assert 'failed clone preserves legacy config' test "$(cat "$TEST_HOME/.tmux.conf")" = 'keep legacy'
assert 'failed clone cleans staging directory' test "$(find "$TEST_HOME/.config" -name '.chadmux.*' | wc -l | tr -d ' ')" = 0

echo "Passed: $PASS"
