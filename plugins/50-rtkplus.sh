PLUGIN_ID="rtkplus"
PLUGIN_NAME="rtk"
PLUGIN_DESC="AI coding agent toolkit"
PLUGIN_DEFAULT=0
PLUGIN_NEEDS_PROMPT=1

plugin_prompt() {
  echo ""
  log "Select an agent for rtk init"
  echo "  CLI command output compression for token efficiency"
  echo ""
  echo "  1) Claude Code / Copilot (default)"
  echo "  2) Gemini CLI"
  echo "  3) Codex (OpenAI)"
  echo "  4) Cursor"
  echo "  5) Windsurf"
  echo "  6) Cline / Roo Code"
  echo "  7) Skip (don't init)"
  read -rp "Choice [1]: " rtk_choice
  rtk_choice="${rtk_choice:-1}"
  case "$rtk_choice" in
    1) RTK_INIT_CMD="rtk init -g" ;;
    2) RTK_INIT_CMD="rtk init -g --gemini" ;;
    3) RTK_INIT_CMD="rtk init -g --codex" ;;
    4) RTK_INIT_CMD="rtk init -g --agent cursor" ;;
    5) RTK_INIT_CMD="rtk init --agent windsurf" ;;
    6) RTK_INIT_CMD="rtk init --agent cline" ;;
    7) RTK_INIT_CMD="" ;;
    *) RTK_INIT_CMD="rtk init -g" ;;
  esac
}

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/rtk"' &>/dev/null
}

plugin_install() {
  log "Installing rtk..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c "bash -s" <<EOF
    set -e
    curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
    export PATH="\$HOME/.local/bin:\$PATH"
    if [[ -d /workspace && -n "$RTK_INIT_CMD" ]]; then
      cd /workspace && $RTK_INIT_CMD --auto-patch
      if [[ -f /workspace/.gitignore ]] && ! grep -q '\.rtk' /workspace/.gitignore; then
        echo '.rtk/' >> /workspace/.gitignore
      fi
    fi
EOF
}
