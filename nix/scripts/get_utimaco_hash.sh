#!/usr/bin/env bash
# Helper script to compute the correct SHA256 hash for the Utimaco simulator
# Run this to update the hash in nix/utimaco.nix

set -euo pipefail

URL="https://package.cosmian.com/ci/hsm-utimaco-simulator.tar.xz"

echo "Computing SHA256 hash for Utimaco simulator..."
echo "URL: $URL"
echo ""

if command -v nix-prefetch-url >/dev/null 2>&1; then
  echo "Using nix-prefetch-url (recommended)..."
  # Note: fetchurl requires the hash of the compressed archive (no --unpack)
  HASH=$(nix-prefetch-url "$URL" 2>/dev/null)
  NIX_HASH=$(nix hash convert --hash-algo sha256 "$HASH" 2>/dev/null || nix hash to-sri --type sha256 "$HASH" 2>/dev/null || echo "sha256-$HASH")
  echo "Hash (base32): $HASH"
  echo "Hash (SRI):    $NIX_HASH"
  echo ""
  echo "Update nix/utimaco.nix with:"
  echo "  simulatorSha256 = \"$NIX_HASH\";"
else
  echo "nix-prefetch-url not found. Falling back to manual method..."
  TEMP_FILE=$(mktemp)
  trap 'rm -f $TEMP_FILE' EXIT

  if command -v curl >/dev/null 2>&1; then
    curl -L -o "$TEMP_FILE" "$URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$TEMP_FILE" "$URL"
  else
    echo "ERROR: Neither curl nor wget available" >&2
    exit 1
  fi

  SHA256=$(sha256sum "$TEMP_FILE" | awk '{print $1}')
  echo "Hash (hex):    $SHA256"
  echo ""
  echo "Convert to SRI format using:"
  echo "  nix hash convert --hash-algo sha256 $SHA256"
fi
