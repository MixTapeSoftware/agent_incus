PLUGIN_ID="mermaid-ascii"
PLUGIN_NAME="mermaid-ascii"
PLUGIN_DESC="Render mermaid diagrams as ASCII art"
PLUGIN_DEFAULT=0

# Pinned release. Bump to re-pin. Asset naming verified 2026-07-18:
#   mermaid-ascii_Linux_x86_64.tar.gz / mermaid-ascii_Linux_arm64.tar.gz
MERMAID_ASCII_VERSION="1.4.0"

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/mermaid-ascii"' &>/dev/null
}

plugin_install() {
  log "Installing mermaid-ascii $MERMAID_ASCII_VERSION..."
  # Prebuilt release binary into ~/.local/bin (no sudo, no Go toolchain needed).
  # Version injected as a leading %q-quoted assignment ahead of a quoted heredoc
  # so no host values are spliced into the remote script body.
  {
    printf 'MERMAID_ASCII_VERSION=%q\n' "$MERMAID_ASCII_VERSION"
    cat <<'EOF'
    set -e
    case "$(uname -m)" in
      x86_64)  ARCH=x86_64 ;;
      aarch64) ARCH=arm64 ;;
      *) echo "mermaid-ascii: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
    esac
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    url="https://github.com/AlexanderGrooff/mermaid-ascii/releases/download/${MERMAID_ASCII_VERSION}/mermaid-ascii_Linux_${ARCH}.tar.gz"
    curl -fSL "$url" -o "$tmp/m.tar.gz"
    tar -C "$tmp" -xzf "$tmp/m.tar.gz" mermaid-ascii
    mkdir -p "$HOME/.local/bin"
    install -m755 "$tmp/mermaid-ascii" "$HOME/.local/bin/mermaid-ascii"
    "$HOME/.local/bin/mermaid-ascii" --help >/dev/null 2>&1 || true
EOF
  } | incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -s /bin/bash
}
