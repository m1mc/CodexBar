#!/usr/bin/env bash
# install-cli.sh - Automated installer for CodexBar CLI
# Supports macOS (arm64, x86_64) and Linux (x86_64)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/m1mc/CodexBar/main/scripts/install-cli.sh | bash
#
set -euo pipefail

REPO="m1mc/CodexBar"
INSTALL_DIR="${CODEXBAR_INSTALL_DIR:-$HOME/.local/bin}"

_log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
_err() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64|amd64)
    ARCH_SUFFIX="x86_64"
    ;;
  arm64|aarch64)
    ARCH_SUFFIX="arm64"
    ;;
  *)
    _err "Unsupported architecture: $ARCH"
    ;;
esac

case "$OS" in
  darwin)
    ASSET_NAME="CodexBarCLI-macos-${ARCH_SUFFIX}.tar.gz"
    ;;
  linux)
    ASSET_NAME="CodexBarCLI-linux-${ARCH_SUFFIX}.tar.gz"
    ;;
  *)
    _err "Unsupported operating system: $OS"
    ;;
esac

_log "Detecting latest release of $REPO..."
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)"

if [ -z "$RELEASE_JSON" ] || echo "$RELEASE_JSON" | grep -q '"message": "Not Found"'; then
  TAG="latest"
  DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$ASSET_NAME"
else
  TAG="$(echo "$RELEASE_JSON" | grep -m1 '"tag_name":' | cut -d '"' -f 4)"
  DOWNLOAD_URL="$(echo "$RELEASE_JSON" | grep "browser_download_url.*$ASSET_NAME" | cut -d '"' -f 4 || true)"
  if [ -z "$DOWNLOAD_URL" ]; then
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$ASSET_NAME"
  fi
fi

_log "Downloading $ASSET_NAME ($TAG)..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/$ASSET_NAME"; then
  _err "Failed to download $DOWNLOAD_URL"
fi

_log "Extracting binary..."
tar -xzf "$TMP_DIR/$ASSET_NAME" -C "$TMP_DIR"

mkdir -p "$INSTALL_DIR"
if [ -f "$TMP_DIR/CodexBarCLI" ]; then
  mv "$TMP_DIR/CodexBarCLI" "$INSTALL_DIR/codexbar"
elif [ -f "$TMP_DIR/codexbar" ]; then
  mv "$TMP_DIR/codexbar" "$INSTALL_DIR/codexbar"
else
  _err "Binary not found in archive."
fi

chmod +x "$INSTALL_DIR/codexbar"
_log "Successfully installed codexbar to $INSTALL_DIR/codexbar"

if ! echo ":$PATH:" | grep -q ":$INSTALL_DIR:"; then
  echo ""
  echo "Add the following to your shell profile (~/.zshrc or ~/.bashrc):"
  echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
  echo ""
fi

_log "Verification:"
"$INSTALL_DIR/codexbar" --version || true
