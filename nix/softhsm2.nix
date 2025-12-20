_:

let
  softhsmNixpkgsUrl =
    let
      u = builtins.getEnv "NIXPKGS_SOFTHSM_URL";
    in
    if u != "" then u else "https://github.com/NixOS/nixpkgs/archive/24.05.tar.gz";

  softhsmPkgs = import (builtins.fetchTarball { url = softhsmNixpkgsUrl; }) { };

  inherit (softhsmPkgs) lib;
  botanPkg =
    if lib.hasAttr "botan2" softhsmPkgs then
      softhsmPkgs.botan2
    else if lib.hasAttr "botan3" softhsmPkgs then
      softhsmPkgs.botan3
    else
      softhsmPkgs.botan;
in

# Build SoftHSM2 with its own nixpkgs/glibc and force the Botan backend
softhsmPkgs.softhsm.overrideAttrs (old: {
  configureFlags = (old.configureFlags or [ ]) ++ [ "--with-crypto-backend=botan" ];
  buildInputs = (old.buildInputs or [ ]) ++ [ botanPkg ];
})
