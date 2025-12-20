#!/usr/bin/env bash
set -euo pipefail
set -x

echo "========================================="
echo "Running SoftHSM2 HSM tests"
echo "========================================="

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/common.sh"
init_build_env "$@"

# Prepare cargo flag arrays (avoid passing empty args)
CARGO_PROFILE_ARGS=(${RELEASE_FLAG:+$RELEASE_FLAG})
CARGO_FEATURES_ARGS=(${FEATURES_FLAG[@]+"${FEATURES_FLAG[@]}"})

# Ensure SoftHSM2 token is initialized (keep minimal; no inline env prefixes)
if command -v softhsm2-util >/dev/null 2>&1; then
  mkdir -p /tmp/softhsm2/tokens
  SOFTHSM2_CONF_FILE=/tmp/softhsm2/softhsm2.conf
  if [ ! -f "$SOFTHSM2_CONF_FILE" ]; then
    cat >"$SOFTHSM2_CONF_FILE" <<'EOF'
directories.tokendir = /tmp/softhsm2/tokens
objectstore.backend = file
EOF
  fi
  export SOFTHSM2_CONF="$SOFTHSM2_CONF_FILE"
  # Initialize a token if none is initialized yet
  if ! softhsm2-util --show-slots 2>/dev/null | grep -q "Initialized: *yes"; then
    softhsm2-util --init-token --slot 0 --label kms --so-pin 5678 --pin 1234 >/dev/null 2>&1 || true
  fi
  # Resolve initialized slot id
  HSM_SLOT_ID=$(softhsm2-util --show-slots 2>/dev/null | awk '/^Slot [0-9]+/{sid=$2} /Initialized: *yes/{print sid}' | head -n1)
  if [ -n "${HSM_SLOT_ID:-}" ]; then
    export HSM_MODEL=softhsm2
    export HSM_SLOT_ID
    export HSM_USER_PASSWORD=1234
  fi
fi

cargo test \
  "${CARGO_PROFILE_ARGS[@]}" \
  -p cosmian_kms_server \
  "${CARGO_FEATURES_ARGS[@]}" \
  -- tests::hsm::test_hsm_all --ignored

cargo test \
  "${CARGO_PROFILE_ARGS[@]}" \
  -p softhsm2_pkcs11_loader \
  --features softhsm2 \
  -- tests::test_hsm_softhsm2_all --ignored

echo "SoftHSM2 HSM tests completed successfully."
