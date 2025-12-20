#!/usr/bin/env bash
# Quick test of the Utimaco Nix package
set -euo pipefail

echo "==== Testing Utimaco Nix Package ===="

# Build the package
echo "Building Utimaco package..."
RESULT=$(NIXPKGS_ALLOW_UNFREE=1 nix-build -E 'with import <nixpkgs> { config.allowUnfree = true; }; callPackage ./nix/utimaco.nix {}' --no-out-link)
echo "Built: $RESULT"

# Test binary architecture
echo ""
echo "Checking binary..."
file "$RESULT/bin/bl_sim5"
readelf -l "$RESULT/bin/bl_sim5" | grep interpreter

# Test simulator start
echo ""
echo "Testing simulator..."
cd /tmp
rm -rf .utimaco-runtime
"$RESULT/bin/utimaco-simulator"
sleep 2

# Check if running
if pgrep -f bl_sim5 >/dev/null; then
  echo "✓ Simulator is running"
else
  echo "✗ Simulator is NOT running"
  exit 1
fi

# Test initialization
echo ""
echo "Testing initialization..."
"$RESULT/bin/utimaco-init"

# Cleanup
pkill -9 bl_sim5 || true
rm -rf /tmp/.utimaco-runtime

echo ""
echo "==== All tests passed! ===="
echo "Package location: $RESULT"
