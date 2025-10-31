
# Use this flake with `nix develop ./src`

{
  description = "Roc flake for the new compiler, written in Zig.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # to easily make configs for multiple architectures
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }@inputs:
    let
      supportedSystems =
        [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" "aarch64-linux" ];
    in flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };

        dependencies = (with pkgs; [
          zig
          zls
        ]);

        aliases = ''
          alias testcmd='zig build snapshot && zig build test'
          alias fmtcmd='zig build fmt'
          alias buildcmd='zig build roc'
        '';

      in {

        devShell = pkgs.mkShell {
          buildInputs = dependencies;

          shellHook = ''
            ${aliases}
            
            echo "Some convenient command aliases:"
            echo "${aliases}" | grep -E "alias .*" -o | sed 's/alias /  /' | sort
            echo ""

            unset NIX_CFLAGS_COMPILE
            unset NIX_LDFLAGS
          ''; # unset to fix: Unrecognized C flag from NIX_CFLAGS_COMPILE: -fmacro-prefix-map
        };
      });
}
