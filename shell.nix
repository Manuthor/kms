{
  pkgs ?
    let
      rustOverlay = import (
        builtins.fetchTarball {
          url = "https://github.com/oxalica/rust-overlay/archive/refs/heads/stable.tar.gz";
        }
      );
      pinned =
        import
          (builtins.fetchTarball {
            url = "https://github.com/NixOS/nixpkgs/archive/24.05.tar.gz";
            sha256 = "1lr1h35prqkd1mkmzriwlpvxcb34kmhc9dnr48gkm8hh089hifmx";
          })
          {
            overlays = [ rustOverlay ];
            config = if (builtins.getEnv "WITH_HSM") == "1" then { allowUnfree = true; } else { };
          };
    in
    pinned,
}:

let
  withHsm = (builtins.getEnv "WITH_HSM") == "1";
  utimacoDrv = import ./nix/utimaco.nix {
    inherit pkgs;
    inherit (pkgs) lib;
  };
in
pkgs.mkShell {
  buildInputs = [
    pkgs.openssl
    pkgs.pkg-config
    pkgs.gcc
    pkgs.rust-bin.stable.latest.default
  ]
  ++ (
    if withHsm then
      [
        pkgs.softhsm
        pkgs.psmisc
        pkgs.wget
        utimacoDrv
      ]
    else
      [ ]
  );

  shellHook = ''
    set -eo pipefail
    export SERVER_SKIP_OPENSSL_BUILD=1
    export OPENSSL_NO_VENDOR=1
    export OPENSSL_CONF="$PWD/target/openssl-nonfips-legacy.cnf"
    export RUST_TEST_THREADS=1

    # Ensure libstdc++ and other runtime libs are discoverable for dlopen
    export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.gcc.cc.lib}/lib:${pkgs.openssl.out}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    if [ -f "${pkgs.openssl.out}/lib/libcrypto.so.3" ]; then
      echo "openssl libcrypto.so.3 found in Nix store"
    else
      echo "openssl libcrypto.so.3 NOT found in ${pkgs.openssl.out}/lib"
    fi

    if [ "''${WITH_HSM:-}" = "1" ]; then
      DLShimDir="/tmp/kms-dlshim"
      mkdir -p "$DLShimDir"
      printf '%s\n' '#define _GNU_SOURCE' '#include <dlfcn.h>' 'int dlclose(void *handle) { (void)handle; return 0; }' > "$DLShimDir/dlclose_shim.c"
      cc -shared -fPIC -o "$DLShimDir/libdlclose_shim.so" "$DLShimDir/dlclose_shim.c" || true
      if [ -f "$DLShimDir/libdlclose_shim.so" ]; then
        export LD_PRELOAD="$DLShimDir/libdlclose_shim.so''${LD_PRELOAD:+:$LD_PRELOAD}"
      fi
      # Use system default lib path unless overridden externally
      : # SOFTHSM2_PKCS11_LIB can be set externally if needed
    fi
  '';
}
