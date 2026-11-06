#!/bin/sh
# egress/build-smokescreen.sh
# Runs as root inside an egress container. Builds smokescreen from a pinned
# commit with a pinned, checksummed Go toolchain, installs the binary, and
# removes the toolchain and source. smokescreen vendors its dependencies, so
# the build fetches nothing else.
#
# Usage: sh build-smokescreen.sh <main.go>
# The binary is bxn's entry point (egress/boxen-smokescreen/main.go), built as
# its own package in smokescreen's tree, so it can use only the standard
# library and what smokescreen vendors. smokescreen itself is unchanged.
set -eu
MAIN_GO="${1:?usage: build-smokescreen.sh <main.go>}"
[ -s "$MAIN_GO" ] || { echo "build-smokescreen: no $MAIN_GO" >&2; exit 1; }

SMOKESCREEN_REPO="https://github.com/stripe/smokescreen.git"
SMOKESCREEN_COMMIT="609eb8931420453daf5893509be0b25b21bd9edb"   # v0.1.0
GO_VERSION="1.26.10"
GO_SHA256_AMD64="ccfe7ae822d2c2f41f4fe7c956199967a4dac22d0ee0d2b2bfdb440aab3b20c5"
GO_SHA256_ARM64="3f4227ce7b206a513e794f1393adb473a07b46e94d18bd15d1c684bbb7319797"
OUT="/usr/local/libexec/boxen/smokescreen"

case "$(dpkg --print-architecture)" in
  amd64) arch=amd64; sum="$GO_SHA256_AMD64" ;;
  arm64) arch=arm64; sum="$GO_SHA256_ARM64" ;;
  *) echo "build-smokescreen: unsupported architecture $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/go.tgz" "https://go.dev/dl/go$GO_VERSION.linux-$arch.tar.gz"
echo "$sum  $work/go.tgz" | sha256sum -c - >/dev/null
tar -C "$work" -xzf "$work/go.tgz"

git init -q "$work/src"
git -C "$work/src" fetch -q --depth 1 "$SMOKESCREEN_REPO" "$SMOKESCREEN_COMMIT"
git -C "$work/src" checkout -q FETCH_HEAD
[ "$(git -C "$work/src" rev-parse HEAD)" = "$SMOKESCREEN_COMMIT" ] || {
  echo "build-smokescreen: fetched the wrong commit" >&2; exit 1; }

install -d -m 755 "$work/src/cmd/boxen-smokescreen" "$(dirname "$OUT")"
cp "$MAIN_GO" "$work/src/cmd/boxen-smokescreen/main.go"
(cd "$work/src" &&
  HOME="$work" GOPATH="$work/gopath" GOCACHE="$work/cache" GOTOOLCHAIN=local \
  GOFLAGS=-mod=vendor CGO_ENABLED=0 GOPROXY=off \
  "$work/go/bin/go" build -trimpath -o "$OUT.new" ./cmd/boxen-smokescreen)
# What was built: smokescreen's commit, and a hash of bxn's main.go, which
# changes whenever that file does.
build="smokescreen $SMOKESCREEN_COMMIT boxen-smokescreen $(sha256sum "$MAIN_GO" | cut -d' ' -f1)"
mv "$OUT.new" "$OUT"
echo "$SMOKESCREEN_COMMIT" > "$OUT.commit"
echo "$build" > "$OUT.build"
