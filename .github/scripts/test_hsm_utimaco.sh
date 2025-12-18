#!/usr/bin/env bash
set -euo pipefail
set -x
trap 'echo "FAIL: test_hsm_utimaco.sh at line $LINENO" >&2' ERR

# Utimaco-only tests (Linux only)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/common.sh"

REPO_ROOT=$(get_repo_root "$SCRIPT_DIR")
init_build_env "$@"
setup_test_logging
setup_fips_openssl_env

echo "========================================="
echo "Running Utimaco HSM tests"
echo "========================================="

[ ! -f /etc/lsb-release ] && {
  echo "Error: HSM tests are only supported on Linux (Ubuntu/Debian)" >&2
  exit 1
}

export HSM_USER_PASSWORD="12345678"

# Ensure OpenSSL runtime is available for tests needing libcrypto
if [ -n "${NIX_OPENSSL_OUT:-}" ] && [ -d "${NIX_OPENSSL_OUT}/lib" ]; then
  export LD_LIBRARY_PATH="${NIX_OPENSSL_OUT}/lib:${LD_LIBRARY_PATH:-}"
fi
if [ -z "${DYN_OPENSSL_LIB:-}" ]; then
  # head -n1 may trigger SIGPIPE on upstream; guard with || true to avoid -o pipefail abort
  DYN_OPENSSL_LIB="$(find /nix/store -type f -path '*/lib/libcrypto.so.3' -print0 2>/dev/null | xargs -0 -r dirname | head -n1 || true)"
fi
if [ -n "${DYN_OPENSSL_LIB:-}" ] && [ -d "$DYN_OPENSSL_LIB" ]; then
  export LD_LIBRARY_PATH="$DYN_OPENSSL_LIB:${LD_LIBRARY_PATH:-}"
fi

# Setup Utimaco HSM simulator
echo "Starting Utimaco simulator setup..."
pushd "$REPO_ROOT" >/dev/null
__LDP_SAVE__="${LD_LIBRARY_PATH-}"
unset LD_LIBRARY_PATH || true
source "$REPO_ROOT/.github/reusable_scripts/prepare_utimaco.sh"
if [ "${__LDP_SAVE__+set}" = set ]; then
  export LD_LIBRARY_PATH="$__LDP_SAVE__"
  unset __LDP_SAVE__
fi
popd >/dev/null

: "${UTIMACO_PKCS11_LIB:?UTIMACO_PKCS11_LIB not set}"
: "${CS_PKCS11_R3_CFG:?CS_PKCS11_R3_CFG not set}"
UTIMACO_LIB_DIR="$(dirname "$UTIMACO_PKCS11_LIB")"

# Prefer system toolchain for linking test binaries to avoid nix glibc/gcc quirks
SYS_CC="/usr/bin/cc"
[ -x "$SYS_CC" ] || SYS_CC="$(command -v cc || true)"
SYS_AR="/usr/bin/ar"
[ -x "$SYS_AR" ] || SYS_AR="$(command -v ar || true)"
SYS_LD="/usr/bin/ld"
[ -x "$SYS_LD" ] || SYS_LD="$(command -v ld || true)"
SYS_RANLIB="/usr/bin/ranlib"
[ -x "$SYS_RANLIB" ] || SYS_RANLIB="$(command -v ranlib || true)"
SYS_NM="/usr/bin/nm"
[ -x "$SYS_NM" ] || SYS_NM="$(command -v nm || true)"
SYS_OBJCOPY="/usr/bin/objcopy"
[ -x "$SYS_OBJCOPY" ] || SYS_OBJCOPY="$(command -v objcopy || true)"
SYS_OBJDUMP="/usr/bin/objdump"
[ -x "$SYS_OBJDUMP" ] || SYS_OBJDUMP="$(command -v objdump || true)"
SYS_STRIP="/usr/bin/strip"
[ -x "$SYS_STRIP" ] || SYS_STRIP="$(command -v strip || true)"
SYS_READelf="/usr/bin/readelf"
[ -x "$SYS_READelf" ] || SYS_READelf="$(command -v readelf || true)"
SYS_GCC="/usr/bin/gcc"
[ -x "$SYS_GCC" ] || SYS_GCC="$(command -v gcc || true)"

# Utimaco integration test (KMS)
SYS_LD_PATHS=""

env \
  PATH="/usr/bin:/bin:$PATH" \
  LD_LIBRARY_PATH="${UTIMACO_LIB_DIR}:${DYN_OPENSSL_LIB:+$DYN_OPENSSL_LIB:}${NIX_OPENSSL_OUT:+$NIX_OPENSSL_OUT/lib:}${LD_LIBRARY_PATH:-}" \
  CC="$SYS_CC" \
  AR="$SYS_AR" \
  LD="$SYS_LD" \
  RANLIB="$SYS_RANLIB" \
  NM="$SYS_NM" \
  OBJCOPY="$SYS_OBJCOPY" \
  OBJDUMP="$SYS_OBJDUMP" \
  STRIP="$SYS_STRIP" \
  READELF="$SYS_READelf" \
  CFLAGS="-fno-lto" \
  CXXFLAGS="-fno-lto" \
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="$SYS_CC" \
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_AR="$SYS_AR" \
  CC_x86_64_unknown_linux_gnu="$SYS_CC" \
  AR_x86_64_unknown_linux_gnu="$SYS_AR" \
  HSM_MODEL="utimaco" \
  HSM_USER_PASSWORD="$HSM_USER_PASSWORD" \
  HSM_SLOT_ID="0" \
  UTIMACO_PKCS11_LIB="$UTIMACO_PKCS11_LIB" \
  CS_PKCS11_R3_CFG="$CS_PKCS11_R3_CFG" \
  cargo test \
  -p cosmian_kms_server \
  ${FEATURES_FLAG[@]+"${FEATURES_FLAG[@]}"} \
  "$RELEASE_FLAG" \
  -- tests::hsm::test_hsm_all --ignored --exact

# Utimaco loader test (no system lib dirs, scoped runtime)
SYS_LD_PATHS=""

env \
  PATH="/usr/bin:/bin:$PATH" \
  LD_LIBRARY_PATH="${UTIMACO_LIB_DIR}:${DYN_OPENSSL_LIB:+$DYN_OPENSSL_LIB:}${NIX_OPENSSL_OUT:+$NIX_OPENSSL_OUT/lib:}${LD_LIBRARY_PATH:-}" \
  CC="$SYS_CC" \
  AR="$SYS_AR" \
  LD="$SYS_LD" \
  RANLIB="$SYS_RANLIB" \
  NM="$SYS_NM" \
  OBJCOPY="$SYS_OBJCOPY" \
  OBJDUMP="$SYS_OBJDUMP" \
  STRIP="$SYS_STRIP" \
  READELF="$SYS_READelf" \
  CFLAGS="-fno-lto" \
  CXXFLAGS="-fno-lto" \
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="$SYS_CC" \
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_AR="$SYS_AR" \
  CC_x86_64_unknown_linux_gnu="$SYS_CC" \
  AR_x86_64_unknown_linux_gnu="$SYS_AR" \
  HSM_MODEL="utimaco" \
  HSM_USER_PASSWORD="$HSM_USER_PASSWORD" \
  HSM_SLOT_ID="0" \
  UTIMACO_PKCS11_LIB="$UTIMACO_PKCS11_LIB" \
  CS_PKCS11_R3_CFG="$CS_PKCS11_R3_CFG" \
  cargo test \
  -p utimaco_pkcs11_loader \
  ${RELEASE_FLAG:+$RELEASE_FLAG} \
  --features utimaco \
  -- tests::test_hsm_utimaco_all --ignored

MISSING_GOOGLE_ENV=false
for var in TEST_GOOGLE_OAUTH_CLIENT_ID TEST_GOOGLE_OAUTH_CLIENT_SECRET TEST_GOOGLE_OAUTH_REFRESH_TOKEN GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY; do
  if [ -z "${!var:-}" ]; then
    MISSING_GOOGLE_ENV=true
    break
  fi
done

if [ "$MISSING_GOOGLE_ENV" = true ]; then
  echo "Skipping Google CSE CLI tests: required env vars are not set."
  echo "Set TEST_GOOGLE_OAUTH_CLIENT_ID, TEST_GOOGLE_OAUTH_CLIENT_SECRET, TEST_GOOGLE_OAUTH_REFRESH_TOKEN, GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY to enable."
else
  # shellcheck disable=SC2086
  sudo -E env "PATH=/usr/bin:/bin:$PATH" \
    LD_LIBRARY_PATH="${UTIMACO_LIB_DIR}:${DYN_OPENSSL_LIB:+$DYN_OPENSSL_LIB:}${NIX_OPENSSL_OUT:+$NIX_OPENSSL_OUT/lib:}${LD_LIBRARY_PATH:-}" \
    HSM_MODEL="utimaco" \
    HSM_USER_PASSWORD="$HSM_USER_PASSWORD" \
    HSM_SLOT_ID="0" \
    UTIMACO_PKCS11_LIB="$UTIMACO_PKCS11_LIB" \
    CS_PKCS11_R3_CFG="$CS_PKCS11_R3_CFG" \
    TEST_GOOGLE_OAUTH_CLIENT_ID="$TEST_GOOGLE_OAUTH_CLIENT_ID" \
    TEST_GOOGLE_OAUTH_CLIENT_SECRET="$TEST_GOOGLE_OAUTH_CLIENT_SECRET" \
    TEST_GOOGLE_OAUTH_REFRESH_TOKEN="$TEST_GOOGLE_OAUTH_REFRESH_TOKEN" \
    GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY="$GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY" \
    cargo test -p cosmian_kms_cli \
    ${RELEASE_FLAG:+$RELEASE_FLAG} \
    ${FEATURES_FLAG[@]+"${FEATURES_FLAG[@]}"} \
    -- --nocapture kmip_2_1_xml_pkcs11_m_1_21 --ignored

  # shellcheck disable=SC2086
  sudo -E env "PATH=/usr/bin:/bin:$PATH" \
    LD_LIBRARY_PATH="${UTIMACO_LIB_DIR}:${DYN_OPENSSL_LIB:+$DYN_OPENSSL_LIB:}${NIX_OPENSSL_OUT:+$NIX_OPENSSL_OUT/lib:}${LD_LIBRARY_PATH:-}" \
    HSM_MODEL="utimaco" \
    HSM_USER_PASSWORD="$HSM_USER_PASSWORD" \
    HSM_SLOT_ID="0" \
    UTIMACO_PKCS11_LIB="$UTIMACO_PKCS11_LIB" \
    CS_PKCS11_R3_CFG="$CS_PKCS11_R3_CFG" \
    TEST_GOOGLE_OAUTH_CLIENT_ID="$TEST_GOOGLE_OAUTH_CLIENT_ID" \
    TEST_GOOGLE_OAUTH_CLIENT_SECRET="$TEST_GOOGLE_OAUTH_CLIENT_SECRET" \
    TEST_GOOGLE_OAUTH_REFRESH_TOKEN="$TEST_GOOGLE_OAUTH_REFRESH_TOKEN" \
    GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY="$GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY" \
    cargo test -p cosmian_kms_cli \
    ${RELEASE_FLAG:+$RELEASE_FLAG} \
    ${FEATURES_FLAG[@]+"${FEATURES_FLAG[@]}"} \
    -- --nocapture hsm_google_cse --ignored
fi

echo "Utimaco HSM tests completed successfully."
