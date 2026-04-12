COMPONENT_ID="chromium"
COMPONENT_NAME="Chromium/Playwright"
COMPONENT_DESC="Headless browser for testing"
COMPONENT_DEFAULT=0
COMPONENT_RUN_ON_LAUNCH=1

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'npx playwright --version' &>/dev/null
}

component_install() {
  # Ensure Chromium runtime deps are present -- templates preserve Playwright's
  # browser binaries but not always the shared libraries they need.
  _chromium_ensure_deps

  if ! component_is_installed; then
    log "Installing Playwright + Chromium browser..."
    incus exec "$CONTAINER_NAME" -- npm install -g playwright
    incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'npx -y playwright install --with-deps chromium'
  else
    log "Playwright already installed, skipping"
  fi

  _chromium_ensure_symlinks
}

# Deps and symlinks don't survive template launches.
component_on_launch() {
  _chromium_ensure_deps
  _chromium_ensure_symlinks
}

_chromium_ensure_deps() {
  incus exec "$CONTAINER_NAME" -- sh -s <<'CHROMIUM_DEPS_EOF'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq \
      libnss3 libnspr4 libatk1.0-0t64 libatk-bridge2.0-0t64 \
      libcups2t64 libdrm2 libxcomposite1 libxdamage1 libxfixes3 \
      libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2t64 \
      libatspi2.0-0t64 libxshmfence1 libxkbcommon0 fonts-liberation xdg-utils \
      > /dev/null
CHROMIUM_DEPS_EOF
}

_chromium_ensure_symlinks() {
  # Symlink Playwright's Chromium as google-chrome so Wallaby and other tools
  # can find it on PATH.
  if ! incus exec "$CONTAINER_NAME" -- test -x /usr/local/bin/google-chrome; then
    incus exec "$CONTAINER_NAME" -- sh -c "
      chrome_path=\$(find /home/$HOST_USER/.cache/ms-playwright -name chrome -path '*/chrome-linux64/chrome' -type f 2>/dev/null | head -1)
      if [ -n \"\$chrome_path\" ]; then
        ln -sf \"\$chrome_path\" /usr/local/bin/google-chrome
      fi
    "
  fi

  # Install chromedriver for tools like Wallaby that expect it on PATH.
  # Ubuntu's chromium-chromedriver is a snap transitional package that doesn't
  # work in containers, so we download from Chrome for Testing.
  if ! incus exec "$CONTAINER_NAME" -- test -x /usr/local/bin/chromedriver; then
    incus exec "$CONTAINER_NAME" -- sh -s <<'CHROMEDRIVER_EOF'
      set -e
      URL=$(curl -s https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print([x['url'] for x in d['channels']['Stable']['downloads']['chromedriver'] if x['platform']=='linux64'][0])")
      curl -sfL -o /tmp/chromedriver.zip "$URL"
      cd /tmp && unzip -o chromedriver.zip
      mv chromedriver-linux64/chromedriver /usr/local/bin/chromedriver
      chmod +x /usr/local/bin/chromedriver
      rm -rf /tmp/chromedriver.zip /tmp/chromedriver-linux64
CHROMEDRIVER_EOF
  fi
}
