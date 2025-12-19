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
  # Do not mutate global LD_LIBRARY_PATH here to avoid glibc conflicts in CI.
  # Per-invocation LD_LIBRARY_PATH is constructed for cargo test calls below.
  :
fi
# Prefer pinned OpenSSL from Nix (NIX_OPENSSL_OUT) and avoid scanning for
# other libcrypto.so.3 versions which may require newer glibc (e.g., 3.6.0).
# DYN_OPENSSL_LIB discovery is disabled to prevent GLIBC version mismatches.

# Setup Utimaco HSM simulator and derive PKCS#11 lib directory
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
# Compute directory of the PKCS#11 library without invoking external tools
UTIMACO_LIB_DIR="${UTIMACO_PKCS11_LIB%/*}"

# Derive OpenSSL lib directory from pinned Nix output, if available
OPENSSL_LIB_DIR=""
if [ -n "${NIX_OPENSSL_OUT:-}" ] && [ -d "${NIX_OPENSSL_OUT}/lib" ]; then
  OPENSSL_LIB_DIR="${NIX_OPENSSL_OUT}/lib"
fi

# Prefer system toolchain for linking to avoid nix glibc/gcc quirks
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

# Prefer nix-provided cargo to avoid snap/rustup glibc mismatch
# shellcheck disable=SC2012
NIX_CARGO="$(ls -1 /nix/store/*-cargo-*/bin/cargo 2>/dev/null | head -n1 || true)"
if [ -x "$NIX_CARGO" ]; then
  CARGO_CMD="$NIX_CARGO"
else
  CARGO_CMD="cargo"
fi

env \
  PATH="/usr/bin:/bin:$PATH" \
  LD_LIBRARY_PATH="${UTIMACO_LIB_DIR}:${LD_LIBRARY_PATH:-}" \
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
  "$CARGO_CMD" test \
  -p cosmian_kms_server \
  ${FEATURES_FLAG[@]+"${FEATURES_FLAG[@]}"} \
  "$RELEASE_FLAG" \
  -- tests::hsm::test_hsm_all --ignored --exact

# Utimaco loader test (no system lib dirs, scoped runtime)

env \
  PATH="/usr/bin:/bin:$PATH" \
  LD_LIBRARY_PATH="${UTIMACO_LIB_DIR}:${LD_LIBRARY_PATH:-}" \
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
  "$CARGO_CMD" test \
  -p utimaco_pkcs11_loader \
  ${RELEASE_FLAG:+$RELEASE_FLAG} \
  --features utimaco \
  -- tests::test_hsm_utimaco_all --ignored

MISSING_GOOGLE_ENV=false
# for var in TEST_GOOGLE_OAUTH_CLIENT_ID TEST_GOOGLE_OAUTH_CLIENT_SECRET TEST_GOOGLE_OAUTH_REFRESH_TOKEN GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY; do
#   if [ -z "${!var:-}" ]; then
#     MISSING_GOOGLE_ENV=true
#     break
#   fi
# done

if [ "$MISSING_GOOGLE_ENV" = true ]; then
  echo "Skipping Google CSE CLI tests: required env vars are not set."
  echo "Set TEST_GOOGLE_OAUTH_CLIENT_ID, TEST_GOOGLE_OAUTH_CLIENT_SECRET, TEST_GOOGLE_OAUTH_REFRESH_TOKEN, GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY to enable."
  exit 1
else
  # Ensure C++ runtime is available (libstdc++.so.6), which Utimaco PKCS#11 depends on
  # In Nix env, prefer Nix-provided libstdc++ to match glibc; otherwise prefer system.
  SYS_LIB_DIR=""
  if [ -d "/usr/lib/x86_64-linux-gnu" ] &&
    [ -f "/usr/lib/x86_64-linux-gnu/libstdc++.so.6" ] &&
    [ -f "/usr/lib/x86_64-linux-gnu/libgcc_s.so.1" ]; then
    SYS_LIB_DIR="/usr/lib/x86_64-linux-gnu"
  fi

  # Build CLI runtime path with priority:
  # 1) Utimaco PKCS#11 dir
  # 2) Existing LD_LIBRARY_PATH (contains pinned Nix OpenSSL lib path)
  # 3) System lib dir for libstdc++/libgcc
  CLI_LDPATH="${UTIMACO_LIB_DIR}"
  if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    CLI_LDPATH="${CLI_LDPATH}:${LD_LIBRARY_PATH}"
  fi
  if [ -n "$SYS_LIB_DIR" ]; then
    CLI_LDPATH="${CLI_LDPATH}:${SYS_LIB_DIR}"
  fi

  # Cargo should avoid system GLib to satisfy libsecret's GLib symbols.
  # Use only Utimaco + pinned Nix OpenSSL libs for Cargo invocation.
  CLI_CARGO_LDPATH="${UTIMACO_LIB_DIR}"
  if [ -n "${OPENSSL_LIB_DIR}" ]; then
    CLI_CARGO_LDPATH="${CLI_CARGO_LDPATH}:${OPENSSL_LIB_DIR}"
  fi

  # Run CLI tests via cargo (mandatory)
  env -u OPENSSL_CONF -u OPENSSL_MODULES \
    PATH="/usr/bin:/bin:$PATH" \
    LD_LIBRARY_PATH="${CLI_CARGO_LDPATH}" \
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
    "$CARGO_CMD" test -p cosmian_kms_cli \
    ${FEATURES_FLAG[@]+"${FEATURES_FLAG[@]}"} \
    ${RELEASE_FLAG:+$RELEASE_FLAG} \
    -- kmip_2_1_xml_pkcs11_m_1_21 --ignored

  # Run CLI tests via cargo (mandatory)
  env -u OPENSSL_CONF -u OPENSSL_MODULES \
    PATH="/usr/bin:/bin:$PATH" \
    LD_LIBRARY_PATH="${CLI_CARGO_LDPATH}" \
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
    "$CARGO_CMD" test -p cosmian_kms_cli \
    ${FEATURES_FLAG[@]+"${FEATURES_FLAG[@]}"} \
    ${RELEASE_FLAG:+$RELEASE_FLAG} \
    -- hsm_google_cse --ignored

fi
echo "Utimaco HSM tests completed successfully."
